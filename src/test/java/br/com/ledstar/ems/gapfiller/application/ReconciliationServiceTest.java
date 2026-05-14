package br.com.ledstar.ems.gapfiller.application;

import br.com.ledstar.ems.gapfiller.application.ReconciliationService.ReconciliationSummary;
import br.com.ledstar.ems.gapfiller.application.TelemetryWriteRepository.InsertResult;
import br.com.ledstar.ems.gapfiller.domain.BackfillRequest;
import br.com.ledstar.ems.gapfiller.domain.SensorMeter;
import br.com.ledstar.ems.gapfiller.domain.SensorReading;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.mockito.junit.jupiter.MockitoSettings;
import org.mockito.quality.Strictness;

import java.time.Duration;
import java.time.LocalDateTime;
import java.util.List;

import java.util.function.Supplier;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Testes unitarios da logica de reconciliacao (sem banco).
 * Usa o AnomalyDetector real e mocks dos repositorios; o MeterDataSource e um fake.
 */
@ExtendWith(MockitoExtension.class)
@MockitoSettings(strictness = Strictness.LENIENT)
class ReconciliationServiceTest {

    private static final long SENSOR = 30L;
    private static final LocalDateTime T0 = LocalDateTime.of(2026, 5, 7, 10, 0);
    private static final LocalDateTime T1 = LocalDateTime.of(2026, 5, 7, 10, 5);
    private static final LocalDateTime T2 = LocalDateTime.of(2026, 5, 7, 10, 10);
    private static final LocalDateTime T3 = LocalDateTime.of(2026, 5, 7, 10, 15);
    private static final LocalDateTime WIN_START = LocalDateTime.of(2026, 5, 7, 0, 0);
    private static final LocalDateTime WIN_END   = LocalDateTime.of(2026, 5, 8, 0, 0);

    private static final SensorMeter METER = new SensorMeter(
            1L, SENSOR, "10.193.217.11", SensorMeter.Protocol.FTP,
            "Administrator", "Gateway", 1, "/logging/data/MV-F3-M_1.csv",
            Duration.ofMinutes(5), true);

    @Mock SensorMeterRepository sensorMeterRepository;
    @Mock TelemetryQueryRepository queryRepository;
    @Mock TelemetryWriteRepository writeRepository;
    @Mock GapLogRepository gapLogRepository;
    @Mock CompressionGuard compressionGuard;

    private FakeMeterDataSource csv;
    private ReconciliationService service;

    @BeforeEach
    void setup() {
        csv = new FakeMeterDataSource();
        service = new ReconciliationService(
                sensorMeterRepository, queryRepository, writeRepository,
                new AnomalyDetector(), gapLogRepository, compressionGuard, List.of(csv));
        when(sensorMeterRepository.findActive()).thenReturn(List.of(METER));
        when(writeRepository.softDelete(any())).thenReturn(1);
        when(writeRepository.insertBatch(any())).thenAnswer(inv -> {
            List<?> batch = inv.getArgument(0);
            return new InsertResult(batch.size(), 0);
        });
        // por padrao, sem chunks comprimidos na janela (modo RECENT nem chega a consultar)
        when(compressionGuard.findCompressedChunksFor(any(), any())).thenReturn(List.of());
        // se runWithDecompressed for chamado, ele apenas executa o supplier
        when(compressionGuard.runWithDecompressed(any(), any(), any()))
                .thenAnswer(inv -> ((Supplier<?>) inv.getArgument(2)).get());
    }

    private static SensorReading kwh(LocalDateTime ts, double value) {
        return new SensorReading(SENSOR, ts, "KWH", value, "kWh", null);
    }

    private ReconciliationSummary runRecent() {
        return service.reconcile(BackfillRequest.Mode.RECENT, null, WIN_START, WIN_END);
    }

    @Test
    void substituiLeituraAnomalaQuandoCsvTemSubstitutoValido() {
        // banco: 100, 200, 50(!), 300  -> 50 e NON_MONOTONIC
        when(queryRepository.findActiveReadings(eq(SENSOR), any(), any()))
                .thenReturn(List.of(kwh(T0, 100.0), kwh(T1, 200.0), kwh(T2, 50.0), kwh(T3, 300.0)));
        // csv: 100, 200, 250, 300 (correto)
        csv.readings = List.of(kwh(T0, 100.0), kwh(T1, 200.0), kwh(T2, 250.0), kwh(T3, 300.0));

        ReconciliationSummary s = runRecent();

        // soft-delete + insert agora vem juntos no replaceReading (atomico)
        verify(writeRepository).replaceReading(
                eq(new SensorReading.DedupKey(SENSOR, T2, "KWH")),
                argThat(r -> r.creation().equals(T2) && r.value() == 250.0));
        verify(writeRepository, never()).insertBatch(any());   // o gap-fill nao roda (csv == banco fora a anomalia)
        verify(writeRepository).refreshContinuousAggregates(any(), any());
        verify(gapLogRepository).record(eq(SENSOR), any(), any(),
                eq(BackfillRequest.Mode.RECENT), eq(1L), eq(0L), eq("ok"), isNull());
        assertThat(s.sensorsProcessed()).isEqualTo(1);
        assertThat(s.anomaliesFound()).isEqualTo(1);
        assertThat(s.softDeleted()).isEqualTo(1);
        assertThat(s.inserted()).isEqualTo(1);
        assertThat(s.flaggedForReview()).isZero();
    }

    @Test
    void marcaParaRevisaoQuandoCsvNaoTemSubstituto() {
        when(queryRepository.findActiveReadings(eq(SENSOR), any(), any()))
                .thenReturn(List.of(kwh(T0, 100.0), kwh(T1, 200.0), kwh(T2, 50.0), kwh(T3, 300.0)));
        csv.readings = List.of(kwh(T0, 100.0), kwh(T1, 200.0), kwh(T3, 300.0));  // sem T2

        ReconciliationSummary s = runRecent();

        verify(writeRepository).softDelete(new SensorReading.DedupKey(SENSOR, T2, "KWH"));
        verify(writeRepository, never()).insertBatch(any());
        verify(writeRepository, never()).replaceReading(any(), any());
        verify(writeRepository).refreshContinuousAggregates(any(), any());
        verify(gapLogRepository).record(eq(SENSOR), any(), any(),
                eq(BackfillRequest.Mode.RECENT), eq(0L), eq(0L), eq("ok"), isNull());
        assertThat(s.softDeleted()).isEqualTo(1);
        assertThat(s.inserted()).isZero();
        assertThat(s.flaggedForReview()).isEqualTo(1);
    }

    @Test
    void inserePreenchendoGapQuandoCsvTemLeiturasAusentesDoBanco() {
        // banco: so 100 e 300 (faltam T1, T2)
        when(queryRepository.findActiveReadings(eq(SENSOR), any(), any()))
                .thenReturn(List.of(kwh(T0, 100.0), kwh(T3, 300.0)));
        // csv: 100, 200, 250, 300
        csv.readings = List.of(kwh(T0, 100.0), kwh(T1, 200.0), kwh(T2, 250.0), kwh(T3, 300.0));

        ReconciliationSummary s = runRecent();

        verify(writeRepository, never()).softDelete(any());
        verify(writeRepository).insertBatch(argThat(batch -> batch.size() == 2));
        verify(writeRepository).refreshContinuousAggregates(any(), any());
        assertThat(s.anomaliesFound()).isZero();
        assertThat(s.softDeleted()).isZero();
        assertThat(s.inserted()).isEqualTo(2);
    }

    @Test
    void naoFazNadaQuandoCsvVazio() {
        when(queryRepository.findActiveReadings(eq(SENSOR), any(), any()))
                .thenReturn(List.of(kwh(T0, 100.0), kwh(T1, 200.0), kwh(T2, 300.0)));
        csv.readings = List.of();   // gateway nao retornou dados

        ReconciliationSummary s = runRecent();

        verify(writeRepository, never()).softDelete(any());
        verify(writeRepository, never()).insertBatch(any());
        verify(writeRepository, never()).refreshContinuousAggregates(any(), any());
        verify(gapLogRepository).record(eq(SENSOR), any(), any(),
                eq(BackfillRequest.Mode.RECENT), eq(0L), eq(0L), eq("no_data_in_meter"), isNull());
        assertThat(s.anomaliesFound()).isZero();
        assertThat(s.softDeleted()).isZero();
        assertThat(s.inserted()).isZero();
    }

    @Test
    void pulaSensorSemDataSourceCompativel() {
        when(queryRepository.findActiveReadings(eq(SENSOR), any(), any()))
                .thenReturn(List.of(kwh(T0, 100.0), kwh(T1, 200.0), kwh(T2, 300.0)));
        csv.supportsAll = false;    // nenhum datasource suporta este medidor

        ReconciliationSummary s = runRecent();

        verify(writeRepository, never()).softDelete(any());
        verify(writeRepository, never()).insertBatch(any());
        verify(writeRepository, never()).refreshContinuousAggregates(any(), any());
        verify(gapLogRepository).record(eq(SENSOR), any(), any(),
                eq(BackfillRequest.Mode.RECENT), eq(0L), eq(0L), eq("no_datasource"), isNull());
        assertThat(s.sensorsProcessed()).isEqualTo(1);
        assertThat(s.inserted()).isZero();
    }

    @Test
    void marcaSensorComoFalhoQuandoReconcileEstoura() {
        // ex: banco sem mqtt.sensordatarecord (HOM vazio) -> findActiveReadings estoura.
        // O lote nao aborta (loga e segue), mas a ReconciliationSummary carrega sensorsFailed/firstError.
        when(queryRepository.findActiveReadings(eq(SENSOR), any(), any()))
                .thenThrow(new RuntimeException("relation \"mqtt.sensordatarecord\" does not exist"));

        ReconciliationSummary s = runRecent();

        assertThat(s.sensorsProcessed()).isEqualTo(1);
        assertThat(s.sensorsFailed()).isEqualTo(1);
        assertThat(s.firstError()).contains("sensor " + SENSOR).contains("does not exist");
        verify(writeRepository, never()).refreshContinuousAggregates(any(), any());
        verify(gapLogRepository).record(eq(SENSOR), any(), any(),
                eq(BackfillRequest.Mode.RECENT), eq(0L), eq(0L),
                argThat(st -> st.startsWith("error:") && st.contains("does not exist")), isNull());
    }

    @Test
    void historicalComChunkComprimidoRodaDentroDoCompressionGuard() {
        when(compressionGuard.findCompressedChunksFor(any(), any()))
                .thenReturn(List.of("mqtt._hyper_5_42_chunk"));
        when(queryRepository.findActiveReadings(eq(SENSOR), any(), any()))
                .thenReturn(List.of(kwh(T0, 100.0), kwh(T1, 200.0), kwh(T2, 50.0), kwh(T3, 300.0)));
        csv.readings = List.of(kwh(T0, 100.0), kwh(T1, 200.0), kwh(T2, 250.0), kwh(T3, 300.0));

        ReconciliationSummary s = service.reconcile(
                BackfillRequest.Mode.HISTORICAL, null,
                LocalDateTime.of(2024, 1, 1, 0, 0), LocalDateTime.of(2024, 1, 8, 0, 0));

        verify(compressionGuard).runWithDecompressed(any(), any(), any());
        verify(writeRepository).replaceReading(eq(new SensorReading.DedupKey(SENSOR, T2, "KWH")), any());
        assertThat(s.softDeleted()).isEqualTo(1);
        assertThat(s.inserted()).isEqualTo(1);
    }

    @Test
    void historicalSemChunkComprimidoNaoUsaCompressionGuard() {
        // findCompressedChunksFor ja retorna [] no setup
        when(queryRepository.findActiveReadings(eq(SENSOR), any(), any()))
                .thenReturn(List.of(kwh(T0, 100.0), kwh(T1, 200.0), kwh(T2, 300.0)));
        csv.readings = List.of(kwh(T0, 100.0), kwh(T1, 200.0), kwh(T2, 300.0));

        service.reconcile(BackfillRequest.Mode.HISTORICAL, null,
                LocalDateTime.of(2026, 5, 1, 0, 0), LocalDateTime.of(2026, 5, 8, 0, 0));

        verify(compressionGuard, never()).runWithDecompressed(any(), any(), any());
    }

    /** MeterDataSource controlavel pelos testes. */
    private static final class FakeMeterDataSource implements MeterDataSource {
        boolean supportsAll = true;
        List<SensorReading> readings = List.of();

        @Override public boolean supports(SensorMeter meter) { return supportsAll; }

        @Override public List<SensorReading> fetchReadings(SensorMeter meter,
                                                           LocalDateTime windowStart,
                                                           LocalDateTime windowEnd) {
            return readings;
        }
    }
}
