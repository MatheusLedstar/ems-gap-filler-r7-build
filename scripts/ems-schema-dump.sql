-- ============================================================================
-- EMS SCHEMA DUMP v2 - rodar em prod via tunnel SSH (energymanagementsystem)
--
-- TODAS as queries READ-ONLY com LIMITs e filtros temporais pra nao estourar
-- memoria nem fazer full-scan na hypertable mqtt.sensordatarecord (pode ter
-- milhoes de linhas em prod).
--
-- Schemas conhecidos (de Q01 do HOM): mqtt, ems, public, _timescaledb_*
-- ============================================================================


-- =========== Q01 schemas e extensoes =========================================
SELECT extname, extversion FROM pg_extension ORDER BY extname;

SELECT nspname FROM pg_namespace
 WHERE nspname NOT LIKE 'pg_%' AND nspname <> 'information_schema'
 ORDER BY nspname;


-- =========== Q02 todas as tabelas com tamanho ===============================
SELECT  n.nspname            AS schema,
        c.relname            AS table_name,
        c.reltuples::bigint  AS estimated_rows,
        pg_size_pretty(pg_total_relation_size(c.oid)) AS total_size
  FROM  pg_class c
  JOIN  pg_namespace n ON n.oid = c.relnamespace
 WHERE  c.relkind = 'r'
   AND  n.nspname NOT IN ('pg_catalog','information_schema','_timescaledb_internal',
                          '_timescaledb_catalog','_timescaledb_config','_timescaledb_cache',
                          '_timescaledb_functions','_timescaledb_debug')
 ORDER  BY pg_total_relation_size(c.oid) DESC
 LIMIT 200;


-- =========== Q03 DDL completo de TODAS as tabelas (schemas mqtt/ems/public/ia) ====
SELECT
  format(
    E'-- =========== %I.%I ===========\nCREATE TABLE %I.%I (\n%s\n);\n',
    n.nspname, c.relname, n.nspname, c.relname,
    string_agg(
      format('    %I %s%s%s',
             a.attname,
             pg_catalog.format_type(a.atttypid, a.atttypmod),
             CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END,
             CASE WHEN ad.adbin IS NOT NULL
                  THEN ' DEFAULT '||pg_get_expr(ad.adbin, ad.adrelid)
                  ELSE '' END),
      E',\n'
      ORDER BY a.attnum)
  ) AS ddl
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
JOIN pg_attribute a ON a.attrelid = c.oid AND a.attnum > 0 AND NOT a.attisdropped
LEFT JOIN pg_attrdef ad ON ad.adrelid = c.oid AND ad.adnum = a.attnum
WHERE c.relkind = 'r'
  AND n.nspname IN ('mqtt','ems','public','ia')
GROUP BY n.nspname, c.relname
ORDER BY n.nspname, c.relname
LIMIT 200;


-- =========== Q04 indexes ====================================================
SELECT schemaname, tablename, indexname, indexdef
  FROM pg_indexes
 WHERE schemaname IN ('mqtt','ems','public','ia')
 ORDER BY schemaname, tablename, indexname
 LIMIT 500;


-- =========== Q05 constraints (PK, FK, UNIQUE, CHECK) =========================
SELECT  n.nspname                    AS schema,
        c.relname                    AS table_name,
        con.conname,
        con.contype,
        pg_get_constraintdef(con.oid) AS definition
  FROM  pg_constraint con
  JOIN  pg_class c     ON c.oid = con.conrelid
  JOIN  pg_namespace n ON n.oid = c.relnamespace
 WHERE  n.nspname IN ('mqtt','ems','public','ia')
 ORDER  BY n.nspname, c.relname, con.contype, con.conname
 LIMIT 500;


-- =========== Q06 hypertables Timescale =======================================
SELECT * FROM timescaledb_information.hypertables
 ORDER BY hypertable_schema, hypertable_name
 LIMIT 50;


-- =========== Q07 chunks resumo + compressao =================================
SELECT  hypertable_schema, hypertable_name,
        COUNT(*) AS total,
        COUNT(*) FILTER (WHERE is_compressed) AS comprimidos,
        MIN(range_start) AS oldest,
        MAX(range_end)   AS newest
  FROM  timescaledb_information.chunks
 GROUP  BY hypertable_schema, hypertable_name
 ORDER  BY hypertable_schema, hypertable_name
 LIMIT 50;


-- =========== Q08 Continuous Aggregates ======================================
SELECT  view_schema, view_name,
        materialization_hypertable_schema AS mat_schema,
        materialization_hypertable_name   AS mat_table,
        finalized,
        view_definition
  FROM  timescaledb_information.continuous_aggregates
 ORDER  BY view_schema, view_name
 LIMIT 50;


-- =========== Q09 jobs Timescale (CAG refresh, compressao, retencao) ==========
SELECT  job_id, application_name, proc_name,
        schedule_interval, config, scheduled, fixed_schedule, next_start
  FROM  timescaledb_information.jobs
 ORDER  BY proc_name, job_id
 LIMIT 100;

SELECT  job_id, last_run_started_at, last_successful_finish, last_run_status,
        total_runs, total_successes, total_failures
  FROM  timescaledb_information.job_stats
 ORDER  BY job_id
 LIMIT 100;


-- =========== Q10 compression settings =======================================
SELECT * FROM timescaledb_information.compression_settings LIMIT 50;


-- =========== Q11 triggers ativos ============================================
SELECT trigger_schema, trigger_name, event_object_schema, event_object_table,
       action_timing, event_manipulation, action_statement
  FROM information_schema.triggers
 WHERE trigger_schema NOT IN ('pg_catalog','information_schema')
 ORDER BY trigger_schema, event_object_table, trigger_name
 LIMIT 200;


-- =========== Q12 functions/procedures CUSTOMIZADOS (sem extensoes) ============
-- Filtra funcs que vieram de extensoes (TimescaleDB tem 200+ funcs publicas)
SELECT  n.nspname AS schema,
        p.proname AS name,
        pg_get_function_identity_arguments(p.oid) AS args,
        pg_get_function_result(p.oid)             AS returns,
        l.lanname AS language
  FROM  pg_proc p
  JOIN  pg_namespace n ON n.oid = p.pronamespace
  JOIN  pg_language l  ON l.oid = p.prolang
 WHERE  n.nspname IN ('mqtt','ems','public','ia')
   AND  NOT EXISTS (
       SELECT 1 FROM pg_depend d
        WHERE d.objid = p.oid AND d.deptype = 'e'
   )
 ORDER  BY n.nspname, p.proname
 LIMIT 200;


-- =========== Q13 views materializadas (NAO-CAG) =============================
SELECT schemaname, matviewname, ispopulated, definition
  FROM pg_matviews
 ORDER BY schemaname, matviewname
 LIMIT 50;


-- =========== Q14 mapeamento sensor / equipamento / area (schema ems) ========
-- IMPORTANTE: tabelas estao em schema 'ems' (nao 'mqtt' como o legado)
SELECT 'ems.sensor' AS src, * FROM ems.sensor              ORDER BY 1 LIMIT 50;
SELECT 'ems.equipment_sensor' AS src, * FROM ems.equipment_sensor LIMIT 50;
SELECT 'ems.equipment' AS src, * FROM ems.equipment        LIMIT 50;
SELECT 'ems.area' AS src, * FROM ems.area                  LIMIT 50;
SELECT 'ems.link_sensor_variable' AS src, * FROM ems.link_sensor_variable LIMIT 100;
SELECT 'ems.sensor_variable' AS src, * FROM ems.sensor_variable LIMIT 100;


-- =========== Q15 amostra de telemetria (LIMIT 30 - hypertable enorme!) ======
SELECT *
  FROM mqtt.sensordatarecord
 WHERE sdr_active = true
 ORDER BY sdr_creation DESC
 LIMIT 30;


-- =========== Q16 ultima leitura por sensor (window 7 dias - evita full scan) ==
-- Limita pra 7 dias pra evitar scan completo da hypertable (pode ter 100M linhas)
SELECT sdr_sensor,
       MAX(sdr_creation)            AS ultima,
       now() - MAX(sdr_creation)    AS atraso,
       COUNT(*) FILTER (WHERE sdr_creation > now() - INTERVAL '24 hours') AS leituras_24h,
       COUNT(*) AS leituras_7d
  FROM mqtt.sensordatarecord
 WHERE sdr_active = true
   AND sdr_creation > now() - INTERVAL '7 days'
 GROUP BY sdr_sensor
 ORDER BY atraso DESC
 LIMIT 500;


-- =========== Q17 deteccao de gaps (24h, LIMIT 200) ===========================
WITH samples AS (
    SELECT sdr_sensor, sdr_creation,
           LAG(sdr_creation) OVER (PARTITION BY sdr_sensor ORDER BY sdr_creation) AS prev
      FROM mqtt.sensordatarecord
     WHERE sdr_active = true
       AND sdr_creation > now() - INTERVAL '24 hours'
)
SELECT  sdr_sensor,
        COUNT(*) AS leituras,
        percentile_cont(0.5) WITHIN GROUP (ORDER BY EXTRACT(epoch FROM sdr_creation - prev))::int AS mediana_seg,
        MAX(EXTRACT(epoch FROM sdr_creation - prev))::int AS maior_gap_seg
  FROM  samples WHERE prev IS NOT NULL
 GROUP  BY sdr_sensor
 ORDER  BY maior_gap_seg DESC
 LIMIT 200;


-- =========== Q18 timezone do banco (CRITICO) ================================
SELECT current_setting('TimeZone')                 AS tz_atual,
       now()                                       AS now_real,
       now() AT TIME ZONE 'UTC'                    AS now_utc,
       now() AT TIME ZONE 'America/Manaus'         AS now_manaus;

SELECT column_name, data_type, datetime_precision
  FROM information_schema.columns
 WHERE table_schema = 'mqtt' AND table_name = 'sensordatarecord'
   AND column_name IN ('sdr_creation','sdr_value','sdr_active','sdr_sensor','sdr_valuetype');


-- =========== Q19 mapeamento sensor IDs da planilha EMS =====================
-- IDs da planilha: 10, 12, 13, 21, 30, 10105, 10109, 10110, 10111, 10112, 10154
-- + sensores ativos vistos em Q15: 10040, 10041, 10112
-- Join com equipment_sensor + equipment + area pra ver mapping completo
SELECT s.*, es.eqs_equipment, e.equ_name, a.are_name
  FROM ems.sensor s
  LEFT JOIN ems.equipment_sensor es ON es.eqs_sensor = s.sen_id
  LEFT JOIN ems.equipment e         ON e.equ_id = es.eqs_equipment
  LEFT JOIN ems.area a              ON a.are_id = e.equ_area
 WHERE s.sen_id IN (10, 12, 13, 21, 30, 10040, 10041, 10105, 10109, 10110, 10111, 10112, 10154)
 ORDER BY s.sen_id
 LIMIT 100;

-- E lista TODOS os sensores ativos no banco (cap em 200 pra nao explodir)
SELECT s.sen_id, s.sen_name, s.sen_active, s.sen_creation,
       e.equ_name AS equipment, a.are_name AS area
  FROM ems.sensor s
  LEFT JOIN ems.equipment_sensor es ON es.eqs_sensor = s.sen_id
  LEFT JOIN ems.equipment e         ON e.equ_id = es.eqs_equipment
  LEFT JOIN ems.area a              ON a.are_id = e.equ_area
 WHERE s.sen_active = true
 ORDER BY s.sen_id
 LIMIT 200;


-- =========== Q20 histograma 7 dias (densidade de telemetria) ===============
-- Output max ~7 linhas (1 por dia)
SELECT date_trunc('day', sdr_creation) AS dia,
       COUNT(*)                        AS leituras,
       COUNT(DISTINCT sdr_sensor)      AS sensores_ativos
  FROM mqtt.sensordatarecord
 WHERE sdr_active = true
   AND sdr_creation > now() - INTERVAL '7 days'
 GROUP BY 1 ORDER BY 1
 LIMIT 30;


-- =========== Q21 distribuicao por valuetype (7 dias) =======================
SELECT sdr_valuetype,
       COUNT(*)              AS total,
       MIN(sdr_creation)     AS primeira,
       MAX(sdr_creation)     AS ultima
  FROM mqtt.sensordatarecord
 WHERE sdr_active = true
   AND sdr_creation > now() - INTERVAL '7 days'
 GROUP BY sdr_valuetype
 ORDER BY total DESC
 LIMIT 100;


-- =========== Q22 tamanho em disco da hypertable ============================
SELECT pg_size_pretty(table_bytes) AS heap,
       pg_size_pretty(index_bytes) AS idx,
       pg_size_pretty(toast_bytes) AS toast,
       pg_size_pretty(total_bytes) AS total
  FROM hypertable_detailed_size('mqtt.sensordatarecord');


-- =========== Q23 busca por funcoes/views CSI/FTP/GAP/OVELOG/BACKFILL ========
SELECT n.nspname, p.proname FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE p.proname ~* '(csi|ftp|gap|backfill|ovelog|fill|ove)'
   AND NOT EXISTS (
     SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e'
   )
 ORDER BY 1, 2
 LIMIT 100;

SELECT table_schema, table_name FROM information_schema.views
 WHERE table_name ~* '(csi|ftp|gap|backfill|ovelog|fill|ove)'
 ORDER BY 1, 2
 LIMIT 100;
