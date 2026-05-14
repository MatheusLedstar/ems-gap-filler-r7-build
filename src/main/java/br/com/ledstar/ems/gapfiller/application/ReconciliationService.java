package br.com.ledstar.ems.gapfiller.application;

import br.com.ledstar.ems.gapfiller.application.TelemetryWriteRepository.InsertResult;
import br.com.ledstar.ems.gapfiller.domain.Anomaly;
import br.com.ledstar.ems.gapfiller.domain.BackfillRequest;
import br.com.ledstar.ems.gapfiller.domain.SensorMeter;
import br.com.ledstar.ems.gapfiller.domain.SensorReading;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;
import java.util.UUID;
import java.util.stream.Collectors;

/**
 * Reconcilia leituras do banco com leituras do CSV do gateway, aplicando regras
 * de validacao em ambas fontes antes de substituir.
 *
 * Fluxo:
 *   1) Busca leituras do banco na janela
 *   2) Detecta anomalias no banco (regras por valuetype)
 *   3) Busca leituras do CSV do gateway na mesma janela
 *   4) Detecta anomalias no CSV
 *   5) Para cada leitura banco anomala:
 *      - Se CSV tem leitura nao-anomala no mesmo timestamp -> replace atomico (soft-delete + INSERT do CSV)
 *      - Se CSV anomalo tambem -> soft-delete e marca pra revisao manual
 *   6) Para cada leitura CSV nao existente no banco e nao-anomala -> INSERT
 *   7) Refresh CAG na janela afetada
 *   8) Grava uma linha em ems.gap_log por sensor processado (rastro do que o ciclo fez)
 */
@Service
public class ReconciliationService {

    private static final Logger log = LoggerFactory.getLogger(ReconciliationService.class);

    private final SensorMeterRepository sensorMeterRepository;
    private final TelemetryQueryRepository queryRepository;
    private final TelemetryWriteRepository writeRepository;
    private final AnomalyDetector anomalyDetector;
    private final GapLogRepository gapLogRepository;
    private final CompressionGuard compressionGuard;
    private final List<MeterDataSource> dataSources;

    public ReconciliationService(SensorMeterRepository sensorMeterRepository,
                                 TelemetryQueryRepository queryRepository,
                                 TelemetryWriteRepository writeRepository,
                                 AnomalyDetector anomalyDetector,
                                 GapLogRepository gapLogRepository,
                                 CompressionGuard compressionGuard,
                                 List<MeterDataSource> dataSources) {
        this.sensorMeterRepository = sensorMeterRepository;
        this.queryRepository = queryRepository;
        this.writeRepository = writeRepository;
        this.anomalyDetector = anomalyDetector;
        this.gapLogRepository = gapLogRepository;
        this.compressionGuard = compressionGuard;
        this.dataSources = dataSources;
    }

    /** Atalho para o modo RECENT (sem ems.backfill_request associado). */
    public ReconciliationSummary reconcile(BackfillRequest.Mode mode,
                                           List<Long> sensorIds,
                                           LocalDateTime windowStart,
                                           LocalDateTime windowEnd) {
        return reconcile(mode, sensorIds, windowStart, windowEnd, null);
    }

    /**
     * Ponto de entrada. No modo HISTORICAL a janela pode tocar chunks comprimidos
     * (compression policy comprime tudo > 7 dias) - ai a reconciliacao roda dentro
     * de {@code compressionGuard.runWithDecompressed(...)} (pausa a policy, descomprime
     * os chunks afetados, recomprime no fim). No modo RECENT (ultimas 24h) os chunks
     * sao recentes e nao comprimidos - vai direto.
     *
     * @param requestId id do ems.backfill_request quando HISTORICAL; {@code null} no RECENT (vai pro gap_log).
     */
    public ReconciliationSummary reconcile(BackfillRequest.Mode mode,
                                           List<Long> sensorIds,
                                           LocalDateTime windowStart,
                                           LocalDateTime windowEnd,
                                           UUID requestId) {
        if (mode == BackfillRequest.Mode.HISTORICAL
                && !compressionGuard.findCompressedChunksFor(windowStart, windowEnd).isEmpty()) {
            log.info("HISTORICAL: janela {} -> {} contem chunk(s) comprimido(s) - via CompressionGuard",
                     windowStart, windowEnd);
            return compressionGuard.runWithDecompressed(windowStart, windowEnd,
                () -> reconcileAll(mode, sensorIds, windowStart, windowEnd, requestId));
        }
        return reconcileAll(mode, sensorIds, windowStart, windowEnd, requestId);
    }

    private ReconciliationSummary reconcileAll(BackfillRequest.Mode mode,
                                               List<Long> sensorIds,
                                               LocalDateTime windowStart,
                                               LocalDateTime windowEnd,
                                               UUID requestId) {
        long anomaliesFound = 0;
        long softDeleted = 0;
        long inserted = 0;
        long skipped = 0;
        long flaggedForReview = 0;
        long sensorsFailed = 0;
        String firstError = null;

        List<SensorMeter> targets = sensorIds == null || sensorIds.isEmpty()
            ? sensorMeterRepository.findActive()
            : sensorIds.stream()
                .map(sensorMeterRepository::findBySensorId)
                .filter(Optional::isPresent)
                .map(Optional::get)
                .toList();

        log.info("reconcile mode={} sensors={} window={} -> {}",
                 mode, targets.size(), windowStart, windowEnd);

        for (SensorMeter meter : targets) {
            try {
                ReconciliationStats stats = reconcileSensor(meter, mode, requestId, windowStart, windowEnd);
                anomaliesFound  += stats.anomaliesFound;
                softDeleted     += stats.softDeleted;
                inserted        += stats.inserted;
                skipped         += stats.skipped;
                flaggedForReview += stats.flaggedForReview;
            } catch (Exception ex) {
                // Erro por-sensor nao aborta o lote (um sensor ruim nao mata o sweep). O modo RECENT
                // (cron) so loga e segue. O modo HISTORICAL repassa isso pro GapFillerScheduler via
                // ReconciliationSummary.sensorsFailed -> a request fica FAILED com a 1a mensagem, em
                // vez de virar COMPLETED 0/0 silenciosamente.
                sensorsFailed++;
                String reason = rootMessage(ex);
                if (firstError == null) firstError = "sensor " + meter.senId() + ": " + reason;
                log.error("sensor {} falhou na reconciliacao", meter.senId(), ex);
                writeGapLog(meter.senId(), windowStart, windowEnd, mode, 0, 0, "error: " + reason, requestId);
            }
        }

        if (softDeleted > 0 || inserted > 0) {
            log.info("refresh CAG hourly window={} -> {}", windowStart, windowEnd);
            writeRepository.refreshContinuousAggregates(windowStart, windowEnd);
        }

        return new ReconciliationSummary(targets.size(), anomaliesFound, softDeleted,
                                         inserted, skipped, flaggedForReview, sensorsFailed, firstError);
    }

    private ReconciliationStats reconcileSensor(SensorMeter meter,
                                                BackfillRequest.Mode mode,
                                                UUID requestId,
                                                LocalDateTime windowStart,
                                                LocalDateTime windowEnd) {
        long anomaliesFound = 0, softDeleted = 0, inserted = 0, skipped = 0, flaggedForReview = 0;

        List<SensorReading> bankReadings = queryRepository
            .findActiveReadings(meter.senId(), windowStart, windowEnd);

        List<Anomaly> bankAnomalies = anomalyDetector.detect(bankReadings, Anomaly.Source.BANCO);
        anomaliesFound += bankAnomalies.size();

        if (bankAnomalies.isEmpty()) {
            log.debug("sensor {} sem anomalias no banco entre {} e {}",
                      meter.senId(), windowStart, windowEnd);
        } else {
            log.info("sensor {} detectou {} anomalia(s) no banco",
                     meter.senId(), bankAnomalies.size());
        }

        MeterDataSource source = pickDataSource(meter);
        if (source == null) {
            log.warn("sensor {} sem MeterDataSource pra protocolo {}", meter.senId(), meter.protocol());
            writeGapLog(meter.senId(), windowStart, windowEnd, mode, 0, 0, "no_datasource", requestId);
            return new ReconciliationStats(anomaliesFound, 0, 0, 0, 0);
        }

        List<SensorReading> csvReadings = source.fetchReadings(meter, windowStart, windowEnd);
        if (csvReadings.isEmpty()) {
            log.info("sensor {} CSV nao retornou dados na janela", meter.senId());
            writeGapLog(meter.senId(), windowStart, windowEnd, mode, 0, 0, "no_data_in_meter", requestId);
            return new ReconciliationStats(anomaliesFound, 0, 0, 0, 0);
        }

        List<Anomaly> csvAnomalies = anomalyDetector.detect(csvReadings, Anomaly.Source.CSV);
        if (!csvAnomalies.isEmpty()) {
            log.warn("sensor {} CSV tem {} anomalia(s) - filtrando antes de usar",
                     meter.senId(), csvAnomalies.size());
        }

        var csvAnomalyKeys = csvAnomalies.stream()
            .map(a -> new SensorReading.DedupKey(a.sensorId(), a.creation(), a.valueType()))
            .collect(Collectors.toSet());

        List<SensorReading> validCsv = csvReadings.stream()
            .filter(r -> !csvAnomalyKeys.contains(r.dedupKey()))
            .toList();

        var csvByKey = validCsv.stream()
            .collect(Collectors.toMap(SensorReading::dedupKey, r -> r, (a, b) -> a));

        for (Anomaly bad : bankAnomalies) {
            var key = new SensorReading.DedupKey(bad.sensorId(), bad.creation(), bad.valueType());
            SensorReading replacement = csvByKey.get(key);

            if (replacement != null) {
                writeRepository.replaceReading(key, replacement);
                softDeleted++;
                inserted++;
                log.info("sensor {} substituido em {}: {} -> {} ({})",
                         bad.sensorId(), bad.creation(), bad.value(), replacement.value(), bad.reason());
            } else {
                writeRepository.softDelete(key);
                softDeleted++;
                flaggedForReview++;
                log.warn("sensor {} soft-delete em {}: SEM substituto valido no CSV (reason={})",
                         bad.sensorId(), bad.creation(), bad.reason());
            }
        }

        var bankKeys = bankReadings.stream()
            .map(SensorReading::dedupKey)
            .collect(Collectors.toSet());
        List<SensorReading> toInsert = new ArrayList<>();
        for (SensorReading r : validCsv) {
            if (!bankKeys.contains(r.dedupKey())) toInsert.add(r);
        }
        if (!toInsert.isEmpty()) {
            InsertResult ir = writeRepository.insertBatch(toInsert);
            inserted += ir.inserted();
            skipped  += ir.skipped();
            log.info("sensor {} inseriu {} leituras novas (CSV preencheu gap)",
                     meter.senId(), ir.inserted());
        }

        writeGapLog(meter.senId(), windowStart, windowEnd, mode, inserted, skipped, "ok", requestId);
        return new ReconciliationStats(anomaliesFound, softDeleted, inserted, skipped, flaggedForReview);
    }

    /**
     * Mensagem curta da causa-raiz - {@code ex.getMessage()} de um BadSqlGrammarException etc. carrega
     * o SQL inteiro embutido e estoura facil o varchar(200) do gpl_status (e polui bfr_error). Aqui
     * pega a Throwable mais funda e devolve "ClasseSimples: msg" truncado.
     */
    static String rootMessage(Throwable ex) {
        Throwable t = ex;
        while (t.getCause() != null && t.getCause() != t) t = t.getCause();
        String m = t.getClass().getSimpleName() + ": " + t.getMessage();
        m = m.replaceAll("\\s+", " ").trim();
        return m.length() > 180 ? m.substring(0, 177) + "..." : m;
    }

    /** Grava o rastro do ciclo em ems.gap_log; uma falha aqui nao derruba a reconciliacao. */
    private void writeGapLog(long sensorId, LocalDateTime windowStart, LocalDateTime windowEnd,
                             BackfillRequest.Mode mode, long inserted, long skipped, String status, UUID requestId) {
        try {
            gapLogRepository.record(sensorId, windowStart, windowEnd, mode, inserted, skipped, status, requestId);
        } catch (Exception ex) {
            log.warn("nao consegui gravar gap_log do sensor {}: {}", sensorId, ex.getMessage());
        }
    }

    private MeterDataSource pickDataSource(SensorMeter meter) {
        for (MeterDataSource ds : dataSources) {
            if (ds.supports(meter)) return ds;
        }
        return null;
    }

    private record ReconciliationStats(long anomaliesFound, long softDeleted, long inserted,
                                       long skipped, long flaggedForReview) {}

    public record ReconciliationSummary(int sensorsProcessed, long anomaliesFound,
                                         long softDeleted, long inserted, long skipped,
                                         long flaggedForReview, long sensorsFailed, String firstError) {}
}
