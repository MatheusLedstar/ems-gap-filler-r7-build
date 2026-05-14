package br.com.ledstar.ems.gapfiller.domain;

import java.time.LocalDateTime;
import java.util.List;
import java.util.UUID;

/**
 * Pedido manual de backfill historico (modo HISTORICAL).
 * Persistido em ems.backfill_request.
 */
public record BackfillRequest(
    UUID id,
    Mode mode,
    List<Long> sensorIds,         // null = todos os sensores ativos
    LocalDateTime windowStart,
    LocalDateTime windowEnd,
    Status status,
    LocalDateTime createdAt,
    LocalDateTime startedAt,
    LocalDateTime finishedAt,
    Long readingsInserted,
    Long readingsSkipped,
    String errorMessage,
    String requestedBy
) {
    public enum Mode {
        RECENT,        // automatic, ultimas N horas
        HISTORICAL     // manual via API, janela arbitraria
    }

    public enum Status {
        QUEUED,
        RUNNING,
        COMPLETED,
        FAILED,
        CANCELLED
    }
}
