-- Catalogo de medidores fisicos (FTP/HTTPS source).
-- Mapeia ems.sensor.sen_id -> medidor fisico + credenciais + path do CSV.
--
-- A FK fts_sensor -> ems.sensor(sen_id) NAO e declarada inline aqui: e adicionada
-- condicionalmente em V76 (so se ems.sensor existir). Isso permite o worker subir
-- contra um HOM vazio (que ainda nao tem o schema do EMS app); contra o PRD (onde
-- ems.sensor existe) a FK e criada normalmente.
CREATE TABLE IF NOT EXISTS ems.ftp_source (
    fts_id              bigint        GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    fts_active          boolean       NOT NULL DEFAULT true,
    fts_creation        timestamp     NOT NULL DEFAULT now(),
    fts_last_updated    timestamp     NOT NULL DEFAULT now(),

    fts_sensor          bigint        NOT NULL,                      -- FK em V76 (condicional)
    fts_meter_ip        varchar(45)   NOT NULL,
    fts_protocol        varchar(10)   NOT NULL CHECK (fts_protocol IN ('FTP','HTTPS')),
    fts_username        varchar(100),
    fts_password_enc    text,                                    -- pgp_sym_encrypt
    fts_modbus_slave_id integer,                                  -- so EGX300
    fts_csv_path        varchar(500),                              -- /logging/data/<arquivo>.csv
    fts_expected_freq   interval      NOT NULL DEFAULT '00:05:00',-- ex 5min, derivado de ems.sensor.sen_time

    UNIQUE (fts_sensor, fts_meter_ip, fts_csv_path)
);

CREATE INDEX IF NOT EXISTS idx_ftp_source_active        ON ems.ftp_source (fts_active) WHERE fts_active = true;
CREATE INDEX IF NOT EXISTS idx_ftp_source_sensor        ON ems.ftp_source (fts_sensor);

COMMENT ON TABLE  ems.ftp_source IS 'Catalogo de medidores fisicos com mapeamento sensor <-> CSV no FTP. Usado pelo ems-gap-filler.';
COMMENT ON COLUMN ems.ftp_source.fts_password_enc IS 'Senha cifrada via pgp_sym_encrypt(secret, KEY).';
