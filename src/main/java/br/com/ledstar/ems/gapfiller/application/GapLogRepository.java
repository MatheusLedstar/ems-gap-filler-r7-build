package br.com.ledstar.ems.gapfiller.application;

import br.com.ledstar.ems.gapfiller.domain.BackfillRequest;

import java.time.LocalDateTime;
import java.util.UUID;

/**
 * Log append-only ({@code ems.gap_log}) do que cada ciclo de reconciliacao fez por sensor.
 * Uma linha por (sensor, janela, ciclo) - eh o rastro persistente do loop RECENT de 15 min
 * (que, ao contrario do HISTORICAL, nao tem ems.backfill_request) e o que o /api/v1/report le.
 */
public interface GapLogRepository {

    /**
     * @param requestId id do ems.backfill_request quando {@code mode == HISTORICAL}; {@code null} no RECENT.
     * @param status    "ok" | "no_data_in_meter" | "no_datasource" | "error: <msg>"
     */
    void record(long sensorId, LocalDateTime windowStart, LocalDateTime windowEnd,
                BackfillRequest.Mode mode, long inserted, long skipped, String status, UUID requestId);
}
