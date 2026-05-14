package br.com.ledstar.ems.gapfiller.infra.scheduler;

import br.com.ledstar.ems.gapfiller.application.BackfillRequestRepository;
import br.com.ledstar.ems.gapfiller.application.ReconciliationService;
import br.com.ledstar.ems.gapfiller.application.ReconciliationService.ReconciliationSummary;
import br.com.ledstar.ems.gapfiller.domain.BackfillRequest;
import org.junit.jupiter.api.Test;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

class GapFillerSchedulerTest {

    private final ReconciliationService reconciliation = mock(ReconciliationService.class);
    private final BackfillRequestRepository requests = mock(BackfillRequestRepository.class);

    private GapFillerScheduler scheduler(boolean recentEnabled, boolean historicalEnabled) {
        return new GapFillerScheduler(reconciliation, requests, 24, "0 5/15 * * * *", recentEnabled, historicalEnabled);
    }

    private static ReconciliationSummary summary(long inserted, long skipped, long sensorsFailed, String firstError) {
        return new ReconciliationSummary(1, 0, 0, inserted, skipped, 0, sensorsFailed, firstError);
    }

    @Test
    void recentSweepRodaQuandoHabilitado() {
        when(reconciliation.reconcile(eq(BackfillRequest.Mode.RECENT), isNull(), any(), any()))
                .thenReturn(summary(0, 0, 0, null));

        scheduler(true, true).recentSweep();

        verify(reconciliation).reconcile(eq(BackfillRequest.Mode.RECENT), isNull(), any(), any());
    }

    @Test
    void recentSweepNaoFazNadaQuandoDesligado() {
        scheduler(false, true).recentSweep();
        verifyNoInteractions(reconciliation);
    }

    @Test
    void drainHistoricalNaoTocaNaFilaQuandoDesligado() {
        scheduler(true, false).drainHistoricalQueue();
        verifyNoInteractions(requests);
        verifyNoInteractions(reconciliation);
    }

    @Test
    void drainHistoricalConsultaAFilaQuandoHabilitadoMasNaoHaPendente() {
        when(requests.findNextQueued()).thenReturn(Optional.empty());
        scheduler(true, true).drainHistoricalQueue();
        verify(requests).findNextQueued();
        verify(requests, never()).updateStatus(any(), any(), any());
        verifyNoInteractions(reconciliation);
    }

    @Test
    void drainHistoricalProcessaPendenteEMarcaCompleted() {
        UUID id = UUID.randomUUID();
        when(requests.findNextQueued()).thenReturn(Optional.of(queued(id)));
        when(reconciliation.reconcile(eq(BackfillRequest.Mode.HISTORICAL), eq(List.of(30L)), any(), any(), eq(id)))
                .thenReturn(summary(2, 0, 0, null));

        scheduler(true, true).drainHistoricalQueue();

        verify(requests).updateStatus(id, BackfillRequest.Status.RUNNING, null);
        verify(requests).updateCounters(id, 2L, 0L);
        verify(requests).updateStatus(id, BackfillRequest.Status.COMPLETED, null);
    }

    @Test
    void drainHistoricalMarcaFailedQuandoAlgumSensorFalhou() {
        UUID id = UUID.randomUUID();
        when(requests.findNextQueued()).thenReturn(Optional.of(queued(id)));
        when(reconciliation.reconcile(eq(BackfillRequest.Mode.HISTORICAL), eq(List.of(30L)), any(), any(), eq(id)))
                .thenReturn(summary(0, 0, 1, "sensor 30: relation \"mqtt.sensordatarecord\" does not exist"));

        scheduler(true, true).drainHistoricalQueue();

        verify(requests).updateStatus(id, BackfillRequest.Status.RUNNING, null);
        verify(requests).updateCounters(id, 0L, 0L);
        verify(requests).updateStatus(eq(id), eq(BackfillRequest.Status.FAILED), contains("1/1"));
        verify(requests, never()).updateStatus(id, BackfillRequest.Status.COMPLETED, null);
    }

    private static BackfillRequest queued(UUID id) {
        return new BackfillRequest(
                id, BackfillRequest.Mode.HISTORICAL, List.of(30L),
                LocalDateTime.of(2026, 5, 1, 0, 0), LocalDateTime.of(2026, 5, 1, 1, 0),
                BackfillRequest.Status.QUEUED, LocalDateTime.now(), null, null, 0L, 0L, null, "tester");
    }
}
