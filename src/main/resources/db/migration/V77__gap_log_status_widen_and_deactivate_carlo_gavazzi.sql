-- (1) gpl_status estava varchar(50) - curto demais pra "error: <mensagem do postgres>"
--     (ex: 'relation "mqtt.sensordatarecord" does not exist' ja passa de 50). Alarga pra 200.
ALTER TABLE ems.gap_log ALTER COLUMN gpl_status TYPE varchar(200);

-- (2) Carlo Gavazzi 69kV (sensores 12 e 13): so expoem porta 443 e o endpoint HTTPS real
--     ainda nao foi descoberto (fts_csv_path e placeholder). Deixa-los ativos faria o loop
--     RECENT tentar busca-los a cada 15 min e contar como sensor falho no ems.gap_log /
--     ems.backfill_request. Reativar quando o endpoint estiver mapeado:
--       UPDATE ems.ftp_source SET fts_active = true, fts_csv_path = '<endpoint>' WHERE fts_sensor IN (12, 13);
UPDATE ems.ftp_source
   SET fts_active = false,
       fts_last_updated = now()
 WHERE fts_protocol = 'HTTPS'
   AND fts_sensor IN (12, 13);
