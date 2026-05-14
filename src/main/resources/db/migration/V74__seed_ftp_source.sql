-- Seed do ems.ftp_source baseado na planilha "Lista de Endereços e Mapeamento EMS".
-- 10 medidores: 4 no EGX300 BM, 4 no EGX300 UT, 2 no Carlo Gavazzi 69kV.
--
-- Senha NAO esta cifrada aqui. O JdbcSensorMeterRepository tenta decifrar com
-- pgp_sym_decrypt SE gapfiller.crypto.pgp-key estiver setado. Se vazio, le bruto.
-- Em prod, rotacionar pra valor cifrado:
--   UPDATE ems.ftp_source SET fts_password_enc = pgp_sym_encrypt(fts_password_enc, 'KEY');
-- (requer extensao pgcrypto - verificar)

INSERT INTO ems.ftp_source (
    fts_sensor, fts_meter_ip, fts_protocol, fts_username, fts_password_enc,
    fts_modbus_slave_id, fts_csv_path, fts_expected_freq, fts_active
)
SELECT * FROM (VALUES
    -- EGX300 BM (10.193.217.11)
    (   30::bigint, '10.193.217.11', 'FTP', 'Administrator', 'Gateway',
        1, '/logging/data/MV-F3-M_1.csv',  '00:05:00'::interval, true),
    (   21::bigint, '10.193.217.11', 'FTP', 'Administrator', 'Gateway',
        6, '/logging/data/LV-F3-1M_6.csv', '00:05:00'::interval, true),
    (10109::bigint, '10.193.217.11', 'FTP', 'Administrator', 'Gateway',
        2, '/logging/data/MV-F3-1_2.csv',  '00:05:00'::interval, true),
    (10154::bigint, '10.193.217.11', 'FTP', 'Administrator', 'Gateway',
        5, '/logging/data/MV-F3-4_5.csv',  '00:05:00'::interval, true),

    -- EGX300 UT (10.194.124.49) - linhas L1..L4 (slaves 2..5). UT_MV_F3_L3 e Compressor.
    (10112::bigint, '10.194.124.49', 'FTP', 'Administrator', 'Gateway',
        2, '/logging/data/MV_F3_L1_2.csv', '00:05:00'::interval, true),
    (10110::bigint, '10.194.124.49', 'FTP', 'Administrator', 'Gateway',
        3, '/logging/data/MV_F3_L2_3.csv', '00:05:00'::interval, true),
    (10111::bigint, '10.194.124.49', 'FTP', 'Administrator', 'Gateway',
        4, '/logging/data/MV_F3_L3_4.csv', '00:05:00'::interval, true),
    (10105::bigint, '10.194.124.49', 'FTP', 'Administrator', 'Gateway',
        5, '/logging/data/MV_F3_L4_5.csv', '00:05:00'::interval, true),

    -- Carlo Gavazzi 69kV (10.193.217.50). HTTPS apenas. Endpoint definitivo
    -- pendente - placeholder /index.html ate o recon HTTPS funcionar.
    (   12::bigint, '10.193.217.50', 'HTTPS', 'admin', 'admin',
        NULL, '/index.html', '00:05:00'::interval, true),
    (   13::bigint, '10.193.217.50', 'HTTPS', 'admin', 'admin',
        NULL, '/index.html', '00:05:00'::interval, true)
) AS seed (sensor, ip, protocol, username, pass, slave, path, freq, active)
WHERE NOT EXISTS (
    SELECT 1 FROM ems.ftp_source f
     WHERE f.fts_sensor = seed.sensor
       AND f.fts_meter_ip = seed.ip
);

-- Comentario de mapping pra cada sensor (referencia da planilha)
COMMENT ON TABLE ems.ftp_source IS
    'Catalogo de medidores. Seed inicial em V74__seed_ftp_source.sql baseado em
     planilha Lista de Enderecos e Mapeamento EMS (LedwayStar 2024).
     Sensor 10111 (UT_MV_F3_L3) eh COMPRESSOR - dividido entre F1, F2, F3 e F5
     na agregacao (formulas em ValueTypeRule/derived).';
