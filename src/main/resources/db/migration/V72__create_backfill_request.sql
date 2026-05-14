-- Pedidos de backfill HISTORICAL (queue).
CREATE TABLE IF NOT EXISTS ems.backfill_request (
    bfr_id              uuid          PRIMARY KEY DEFAULT gen_random_uuid(),
    bfr_mode            varchar(15)   NOT NULL CHECK (bfr_mode IN ('RECENT','HISTORICAL')),
    bfr_sensor_ids      bigint[],                                 -- NULL = todos os ativos
    bfr_window_start    timestamp     NOT NULL,
    bfr_window_end      timestamp     NOT NULL,
    bfr_status          varchar(20)   NOT NULL DEFAULT 'QUEUED'
                                      CHECK (bfr_status IN ('QUEUED','RUNNING','COMPLETED','FAILED','CANCELLED')),
    bfr_created_at      timestamp     NOT NULL DEFAULT now(),
    bfr_started_at      timestamp,
    bfr_finished_at     timestamp,
    bfr_inserted        bigint        NOT NULL DEFAULT 0,
    bfr_skipped         bigint        NOT NULL DEFAULT 0,
    bfr_error           text,
    bfr_requested_by    varchar(100)  NOT NULL,

    CHECK (bfr_window_end > bfr_window_start)
);

CREATE INDEX IF NOT EXISTS idx_backfill_request_status_created
    ON ems.backfill_request (bfr_status, bfr_created_at)
    WHERE bfr_status IN ('QUEUED','RUNNING');

COMMENT ON TABLE ems.backfill_request IS 'Fila de pedidos manuais de backfill historico.';
