-- Regras de validacao configuraveis por sensor + valuetype.
--
-- Substitui ValueTypeRule hardcoded. Permite:
--   - Range fisico especifico do circuito (ex: medidor 69kV vs 13.8kV)
--   - Override de monotonicidade (medidor reset por overflow nao eh anomalia)
--   - Tolerancia de salto entre leituras (transitorio aceitavel)
--   - Exclusao temporaria de regra (sensor em manutencao)
--
-- Tabela vazia = AnomalyDetector aplica defaults hardcoded.
-- Tabela populada = override.
CREATE TABLE IF NOT EXISTS ems.sensor_validation_rule (
    svr_id              bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    svr_active          boolean       NOT NULL DEFAULT true,
    svr_creation        timestamp     NOT NULL DEFAULT now(),
    svr_last_updated    timestamp     NOT NULL DEFAULT now(),

    svr_sensor          bigint,                    -- NULL = aplica a todos sensores deste valuetype
    svr_valuetype       varchar(50)   NOT NULL,    -- ex: KWH, V_L1_N, A_SYS, HZ
    svr_min_value       double precision,
    svr_max_value       double precision,
    svr_monotonic       boolean       NOT NULL DEFAULT false,
    svr_reset_tolerance double precision,           -- diferenca aceita por reset (NULL = qualquer reset eh anomalia)
    svr_freq_outlier_factor double precision DEFAULT 100.0,

    UNIQUE (svr_sensor, svr_valuetype),
    CHECK (svr_max_value IS NULL OR svr_min_value IS NULL OR svr_max_value >= svr_min_value)
);

CREATE INDEX IF NOT EXISTS idx_svr_sensor_vt ON ems.sensor_validation_rule (svr_sensor, svr_valuetype) WHERE svr_active;
CREATE INDEX IF NOT EXISTS idx_svr_vt        ON ems.sensor_validation_rule (svr_valuetype) WHERE svr_active AND svr_sensor IS NULL;

-- Tabela de eventos de medidor - reset/troca/calibracao - pra anomaly detector ignorar
CREATE TABLE IF NOT EXISTS ems.sensor_event (
    sve_id              bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sve_creation        timestamp     NOT NULL DEFAULT now(),

    sve_sensor          bigint        NOT NULL,
    sve_event_time      timestamp     NOT NULL,                  -- quando o evento ocorreu
    sve_event_type      varchar(30)   NOT NULL CHECK (sve_event_type IN
                                       ('METER_RESET', 'METER_REPLACED', 'CALIBRATION', 'MAINTENANCE', 'NETWORK_OUTAGE')),
    sve_description     text,
    sve_created_by      varchar(100)
);

CREATE INDEX IF NOT EXISTS idx_sve_sensor_time ON ems.sensor_event (sve_sensor, sve_event_time DESC);

COMMENT ON TABLE ems.sensor_validation_rule IS
    'Regras de validacao por sensor+valuetype. Vazio = AnomalyDetector usa defaults hardcoded em ValueTypeRule.';
COMMENT ON TABLE ems.sensor_event IS
    'Eventos operacionais (reset, troca, calibracao). AnomalyDetector ignora violacoes em janela apos evento.';
