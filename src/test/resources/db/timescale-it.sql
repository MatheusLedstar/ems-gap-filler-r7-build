-- =============================================================================
-- Bootstrap do banco de testes de integracao (Testcontainers + timescale/timescaledb).
-- Roda ANTES do Flyway (via PostgreSQLContainer.withInitScript).
--
-- Recria o minimo do schema de PRODUCAO que o ems-gap-filler depende:
--   - extensoes timescaledb + pgcrypto (pgp_sym_decrypt e referenciado no SQL)
--   - schema mqtt + ems
--   - ems.sensor (alvo da FK de ems.ftp_source) + os 10 sen_id da planilha
--   - mqtt.sensordatarecord como hypertable + idx_sensordatarecord_sensor_type_creation
--   - mqtt.last_sensor_value (cache da ultima leitura)
--
-- O Flyway roda V70..V75 por cima disto (cria ems.ftp_source, gap_log, etc).
--
-- NAO recria os CAGs (mqtt.sdr_hourly/daily/monthly) nem a procedure
-- mqtt.sdr_hourly_refresh - nenhum IT exercita reconcile() completo (o teste do
-- ReconciliationService e unitario, com writeRepository mockado). Se um IT futuro
-- testar reconcile() de ponta a ponta, criar aqui o CAG hourly + a procedure
-- (atencao: refresh_continuous_aggregate nao roda dentro de transacao).
-- =============================================================================

CREATE EXTENSION IF NOT EXISTS timescaledb;
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE SCHEMA IF NOT EXISTS mqtt;
CREATE SCHEMA IF NOT EXISTS ems;

-- ---- ems.sensor (so o que a FK de ems.ftp_source precisa) --------------------
CREATE TABLE ems.sensor (
    sen_id    bigint PRIMARY KEY,
    sen_name  varchar(200),
    sen_time  integer DEFAULT 300
);

INSERT INTO ems.sensor (sen_id, sen_name) VALUES
    (   30, '(BM) MV-F3-M'),
    (   21, '(BM) LV-F3-1M'),
    (10109, 'BM_MV-F3-L1'),
    (10154, 'BM_MV-F3-L4'),
    (10112, 'UT_MV_F3_L1'),
    (10110, 'UT_MV_F3_L2'),
    (10111, 'UT_MV_F3_L3 (Compressor)'),
    (10105, 'UT_MV_F3_L4'),
    (   12, 'F1 (69kV Factory 01)'),
    (   13, 'F2 (69kV Factory 02)');

-- ---- mqtt.sensordatarecord (hypertable principal) ---------------------------
CREATE TABLE mqtt.sensordatarecord (
    sdr_id               bigint GENERATED ALWAYS AS IDENTITY,
    sdr_active           boolean,
    sdr_creation         timestamp WITHOUT TIME ZONE NOT NULL,
    sdr_last_updated     timestamp WITHOUT TIME ZONE,
    sdr_sensor           bigint NOT NULL,
    sdr_valuetype        varchar(50),
    sdr_unit_measurement varchar(50),
    sdr_json             jsonb,
    sdr_enable           boolean,
    sdr_creation_date    date DEFAULT CURRENT_DATE,
    sdr_value            double precision,
    PRIMARY KEY (sdr_id, sdr_creation, sdr_sensor)
);

SELECT create_hypertable('mqtt.sensordatarecord', 'sdr_creation',
                         chunk_time_interval => INTERVAL '1 day');

CREATE INDEX idx_sensordatarecord_sensor_type_creation
    ON mqtt.sensordatarecord (sdr_sensor, sdr_valuetype, sdr_creation DESC);

-- ---- mqtt.last_sensor_value (cache) -----------------------------------------
CREATE TABLE mqtt.last_sensor_value (
    sdr_id               bigint,
    sdr_active           boolean,
    sdr_creation         timestamp WITHOUT TIME ZONE,
    sdr_sensor           bigint,
    sdr_valuetype        varchar(50),
    sdr_unit_measurement varchar(50),
    sdr_value            double precision
);
