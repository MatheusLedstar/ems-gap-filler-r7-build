package br.com.ledstar.ems.gapfiller.infra.scheduler;

import br.com.ledstar.ems.gapfiller.application.BackfillRequestRepository;
import br.com.ledstar.ems.gapfiller.application.ReconciliationService;
import br.com.ledstar.ems.gapfiller.application.ReconciliationService.ReconciliationSummary;
import br.com.ledstar.ems.gapfiller.domain.BackfillRequest;
import net.javacrumbs.shedlock.spring.annotation.SchedulerLock;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.scheduling.annotation.Scheduled;
import org.springframework.stereotype.Component;

import java.time.Duration;
import java.time.LocalDateTime;
import java.util.Optional;

/**
 * Schedulers do worker:
 *   - {@link #recentSweep()}: loop de reconciliacao RECENT de 15 em 15 min (corrige gaps E valores
 *     que o backend do app gravou errado, re-varrendo a janela das ultimas N horas).
 *   - {@link #drainHistoricalQueue()}: drena a fila de backfill HISTORICAL submetida via API.
 * Ambos delegam pra ReconciliationService - servico unificado de deteccao de anomalias + soft-delete
 * + INSERT corrigido + refresh dos CAGs.
 *
 * Desativado sob o profile "test" (os testes de integracao nao querem o cron
 * disparando reconciliacao real durante a suite).
 *
 * Dois kill-switches independentes (default ON; relaxed-binding p/ env vars):
 *   - {@code gapfiller.recent.enabled}     (GAPFILLER_RECENT_ENABLED)     - o sweep RECENT horario
 *   - {@code gapfiller.historical.enabled} (GAPFILLER_HISTORICAL_ENABLED) - o drain da fila de backfill
 * Com os dois OFF, o worker sobe, aplica Flyway e expõe a API mas NAO toca em telemetria
 * (usado pelo deploy em HOM / pelo modo de validacao seca).
 */
@Component
@Profile("!test")
public class GapFillerScheduler {

    private static final Logger log = LoggerFactory.getLogger(GapFillerScheduler.class);

    private final ReconciliationService reconciliationService;
    private final BackfillRequestRepository requestRepository;
    private final Duration recentWindow;
    private final boolean recentEnabled;
    private final boolean historicalEnabled;

    public GapFillerScheduler(ReconciliationService reconciliationService,
                              BackfillRequestRepository requestRepository,
                              @Value("${gapfiller.recent.window-hours:24}") int recentWindowHours,
                              @Value("${gapfiller.recent.cron:0 5/15 * * * *}") String recentCron,
                              @Value("${gapfiller.recent.enabled:true}") boolean recentEnabled,
                              @Value("${gapfiller.historical.enabled:true}") boolean historicalEnabled) {
        this.reconciliationService = reconciliationService;
        this.requestRepository = requestRepository;
        this.recentWindow = Duration.ofHours(recentWindowHours);
        this.recentEnabled = recentEnabled;
        this.historicalEnabled = historicalEnabled;
        log.info("GapFillerScheduler ativo. recentSweep(cron='{}', janela={}h)={}, drainHistoricalQueue(60s)={}",
                 recentCron, recentWindowHours,
                 recentEnabled ? "HABILITADO" : "DESLIGADO (gapfiller.recent.enabled=false)",
                 historicalEnabled ? "HABILITADO" : "DESLIGADO (gapfiller.historical.enabled=false)");
    }

    /**
     * Loop de reconciliacao RECENT - de 15 em 15 minutos (default {@code 0 5/15 * * * *} => :05, :20, :35, :50),
     * 5 min apos cada refresh do CAG hourly (:00, :15, :30, :45). Re-varre a janela das ultimas N horas
     * (default 24) corrigindo gaps E valores anomalos que o backend do app gravou errado. Idempotente.
     */
    // lockAtMostFor (PT20M) > intervalo do cron (15 min) de proposito: 24h x sensores x download FTP
    // pode passar de 15 min; nesse caso o ciclo seguinte e PULADO em vez de rodar concorrente
    // (sweep idempotente, mas dois ao mesmo tempo dobrariam a carga de FTP a toa). So um nó por vez.
    @Scheduled(cron = "${gapfiller.recent.cron:0 5/15 * * * *}")
    @SchedulerLock(name = "gapfiller-recent-sweep", lockAtMostFor = "PT20M", lockAtLeastFor = "PT30S")
    public void recentSweep() {
        if (!recentEnabled) return;
        LocalDateTime end = LocalDateTime.now().minusMinutes(10);
        LocalDateTime start = end.minus(recentWindow);
        try {
            ReconciliationSummary s = reconciliationService.reconcile(
                BackfillRequest.Mode.RECENT, null, start, end);
            log.info("RECENT done: sensors={}, anomalies={}, soft_deleted={}, inserted={}, " +
                     "skipped={}, flagged_for_review={}, sensors_failed={}",
                     s.sensorsProcessed(), s.anomaliesFound(), s.softDeleted(),
                     s.inserted(), s.skipped(), s.flaggedForReview(), s.sensorsFailed());
        } catch (Exception ex) {
            log.error("RECENT sweep falhou", ex);
        }
    }

    /**
     * Drena fila HISTORICAL um por vez (lock garante unicidade).
     */
    @Scheduled(fixedDelay = 60_000)
    @SchedulerLock(name = "gapfiller-historical-queue", lockAtMostFor = "PT12H", lockAtLeastFor = "PT10S")
    public void drainHistoricalQueue() {
        if (!historicalEnabled) return;
        Optional<BackfillRequest> next = requestRepository.findNextQueued();
        if (next.isEmpty()) return;

        BackfillRequest req = next.get();
        log.info("HISTORICAL processando {} window {} -> {}",
                 req.id(), req.windowStart(), req.windowEnd());
        requestRepository.updateStatus(req.id(), BackfillRequest.Status.RUNNING, null);

        try {
            ReconciliationSummary s = reconciliationService.reconcile(
                BackfillRequest.Mode.HISTORICAL,
                req.sensorIds(),
                req.windowStart(),
                req.windowEnd(),
                req.id());
            requestRepository.updateCounters(req.id(), s.inserted(), s.skipped());
            if (s.sensorsFailed() > 0) {
                // backfill targeted: se algum sensor pedido falhou, a request fica FAILED com a 1a
                // mensagem (em vez de COMPLETED 0/0 silencioso) - o usuario que submeteu precisa saber.
                String msg = s.sensorsFailed() + "/" + s.sensorsProcessed()
                           + " sensor(es) falharam na reconciliacao. 1o erro: " + s.firstError();
                log.warn("HISTORICAL {} -> FAILED: {}", req.id(), msg);
                requestRepository.updateStatus(req.id(), BackfillRequest.Status.FAILED, msg);
            } else {
                requestRepository.updateStatus(req.id(), BackfillRequest.Status.COMPLETED, null);
                log.info("HISTORICAL {} done: anomalies={}, soft_deleted={}, inserted={}",
                         req.id(), s.anomaliesFound(), s.softDeleted(), s.inserted());
            }
        } catch (Exception ex) {
            log.error("HISTORICAL {} falhou", req.id(), ex);
            requestRepository.updateStatus(req.id(), BackfillRequest.Status.FAILED, ex.getMessage());
        }
    }
}
