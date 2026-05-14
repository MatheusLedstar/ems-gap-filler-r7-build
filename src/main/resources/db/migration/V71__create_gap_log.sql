-- Registro de gaps detectados e resultados de backfill.
-- Append-only, sem UPDATE.
CREATE TABLE IF NOT EXISTS ems.gap_log (
    gpl_id              bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    gpl_creation        timestamp     NOT NULL DEFAULT now(),

    gpl_sensor          bigint        NOT NULL,
    gpl_window_start    timestamp     NOT NULL,
    gpl_window_end      timestamp     NOT NULL,
    gpl_duration_sec    integer       GENERATED ALWAYS AS
                                      (EXTRACT(EPOCH FROM (gpl_window_end - gpl_window_start))::int) STORED,

    gpl_mode            varchar(15)   NOT NULL CHECK (gpl_mode IN ('RECENT','HISTORICAL')),
    gpl_inserted        bigint        NOT NULL DEFAULT 0,
    gpl_skipped         bigint        NOT NULL DEFAULT 0,
    gpl_status          varchar(50)   NOT NULL,                 -- 'ok' | 'no_data_in_meter' | 'error: ...'
    gpl_request_id      uuid                                       -- ref a backfill_request quando HISTORICAL
);

CREATE INDEX IF NOT EXISTS idx_gap_log_sensor_creation ON ems.gap_log (gpl_sensor, gpl_creation DESC);
CREATE INDEX IF NOT EXISTS idx_gap_log_window          ON ems.gap_log (gpl_window_start DESC);
CREATE INDEX IF NOT EXISTS idx_gap_log_request         ON ems.gap_log (gpl_request_id) WHERE gpl_request_id IS NOT NULL;

COMMENT ON TABLE ems.gap_log IS 'Append-only log de gaps detectados pelo ems-gap-filler.';
