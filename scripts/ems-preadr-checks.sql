-- ============================================================================
-- EMS Pre-ADR Checks - queries pra fechar lacunas antes do ADR do worker
--
-- Cobre: Flyway state, permissoes ems_user, chunk interval, JSON timezone,
-- amostra de _terminalTime vs sdr_creation, sample comprimido vs descomprimido.
-- READ-ONLY.
-- ============================================================================


-- =========== Q01 Flyway state em mqtt e ems ==================================
SELECT 'mqtt.flyway_schema_history' AS src, installed_rank, version, description, type, script,
       installed_by, installed_on, execution_time, success
  FROM mqtt.flyway_schema_history
 ORDER BY installed_rank DESC
 LIMIT 30;

SELECT 'ems.flyway_history_data' AS src, *
  FROM ems.flyway_history_data
 ORDER BY 1 DESC
 LIMIT 20;

SELECT 'ems.flyway_history_structure' AS src, *
  FROM ems.flyway_history_structure
 ORDER BY 1 DESC
 LIMIT 20;


-- =========== Q02 Permissoes ems_user nos schemas =============================
SELECT current_user AS me, session_user AS sess, current_database() AS db;

SELECT n.nspname AS schema,
       has_schema_privilege('ems_user', n.nspname, 'USAGE')  AS can_use,
       has_schema_privilege('ems_user', n.nspname, 'CREATE') AS can_create
  FROM pg_namespace n
 WHERE n.nspname IN ('mqtt','ems','public','ia');


-- =========== Q03 Permissoes em tabelas-chave =================================
SELECT grantee, table_schema, table_name, string_agg(privilege_type, ',') AS privs
  FROM information_schema.role_table_grants
 WHERE grantee IN ('ems_user', 'PUBLIC')
   AND table_schema IN ('mqtt','ems')
   AND table_name IN ('sensordatarecord','last_sensor_value','sensor','equipment',
                      'equipment_sensor','flyway_schema_history','flyway_history_data')
 GROUP BY 1,2,3
 ORDER BY 2,3,1
 LIMIT 30;


-- =========== Q04 Tem permissao de criar tabelas? =============================
SELECT 'mqtt' AS schema,
       has_schema_privilege('ems_user','mqtt','CREATE') AS create_table_ok,
       pg_catalog.obj_description((SELECT oid FROM pg_namespace WHERE nspname='mqtt')) AS comment;
SELECT 'ems' AS schema,
       has_schema_privilege('ems_user','ems','CREATE') AS create_table_ok;


-- =========== Q05 Chunk interval e dimensoes da hypertable ====================
SELECT h.schema_name, h.table_name,
       d.column_name, d.column_type, d.num_slices, d.interval_length,
       d.interval_length / 1000000 / 86400 AS days_per_chunk
  FROM _timescaledb_catalog.hypertable h
  JOIN _timescaledb_catalog.dimension  d ON d.hypertable_id = h.id
 WHERE h.schema_name = 'mqtt' AND h.table_name = 'sensordatarecord'
 ORDER BY d.id
 LIMIT 10;


-- =========== Q06 Tamanho real da hypertable + chunks =========================
SELECT pg_size_pretty(pg_total_relation_size('mqtt.sensordatarecord')) AS root_relation,
       pg_size_pretty(hypertable_size('mqtt.sensordatarecord'))         AS hypertable_total;

SELECT pg_size_pretty(table_bytes) AS heap,
       pg_size_pretty(index_bytes) AS idx,
       pg_size_pretty(toast_bytes) AS toast,
       pg_size_pretty(total_bytes) AS total
  FROM hypertable_detailed_size('mqtt.sensordatarecord');


-- =========== Q07 Chunks recentes (comprimidos vs nao) ========================
SELECT chunk_schema, chunk_name, range_start, range_end, is_compressed,
       pg_size_pretty(chunk_size_bytes) AS size
  FROM (
       SELECT c.chunk_schema, c.chunk_name, c.range_start, c.range_end, c.is_compressed,
              hypertable_detailed_size(c.chunk_schema || '.' || c.chunk_name).total_bytes AS chunk_size_bytes
         FROM timescaledb_information.chunks c
        WHERE c.hypertable_name = 'sensordatarecord'
        ORDER BY c.range_start DESC
        LIMIT 20
       ) sub
 ORDER BY range_start DESC;


-- =========== Q08 Investigar timezone _terminalTime vs sdr_creation ===========
-- Pega amostra de 1h pra calcular delta entre _terminalTime do JSON e sdr_creation
SELECT sdr_id, sdr_sensor, sdr_valuetype,
       sdr_creation,
       (sdr_json->>'_terminalTime')::timestamp AS terminal_time,
       sdr_creation - (sdr_json->>'_terminalTime')::timestamp AS diff,
       sdr_json->>'_groupName'  AS group_name,
       sdr_json->>'TerminalPn'  AS terminal_pn
  FROM mqtt.sensordatarecord
 WHERE sdr_active = true
   AND sdr_creation > now() - INTERVAL '15 minutes'
   AND sdr_json IS NOT NULL
   AND sdr_json ? '_terminalTime'
 ORDER BY sdr_creation DESC
 LIMIT 30;


-- =========== Q09 Quais sensores enviam JSON denso? ===========================
SELECT sdr_sensor,
       COUNT(*) AS total,
       COUNT(*) FILTER (WHERE sdr_json IS NOT NULL AND jsonb_typeof(sdr_json) = 'object'
                        AND sdr_json::text != '{}')                  AS with_json,
       COUNT(*) FILTER (WHERE sdr_json ? '_terminalTime')              AS with_terminal_time,
       COUNT(*) FILTER (WHERE sdr_json ? '_groupName')                 AS with_group_name
  FROM mqtt.sensordatarecord
 WHERE sdr_active = true
   AND sdr_creation > now() - INTERVAL '10 minutes'
 GROUP BY sdr_sensor
 ORDER BY sdr_sensor
 LIMIT 100;


-- =========== Q10 mqtt.last_sensor_value - ultimo valor por sensor (pronto) ===
-- Esta tabela tem 1159 rows e e o cache - perfeita pra detectar gaps sem
-- precisar fazer query pesada na hypertable
SELECT sdr_sensor, sdr_valuetype, sdr_value, sdr_unit_measurement,
       sdr_creation, sdr_active, sdr_enable
  FROM mqtt.last_sensor_value
 WHERE sdr_active = true
 ORDER BY sdr_sensor, sdr_valuetype
 LIMIT 100;


-- =========== Q11 Quem owner da hypertable (pra saber quem comprime) ==========
SELECT n.nspname AS schema, c.relname AS table_name, r.rolname AS owner
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN pg_roles r     ON r.oid = c.relowner
 WHERE n.nspname = 'mqtt'
   AND c.relname IN ('sensordatarecord','last_sensor_value','sdr_hourly','sdr_daily','sdr_monthly')
 LIMIT 20;


-- =========== Q12 Roles existentes no banco ===================================
SELECT rolname, rolsuper, rolcreaterole, rolcreatedb, rolcanlogin
  FROM pg_roles
 WHERE rolname NOT LIKE 'pg_%'
 ORDER BY rolname
 LIMIT 50;


-- =========== Q13 Default privileges em mqtt e ems ============================
SELECT defaclrole::regrole AS owner,
       n.nspname           AS schema,
       defaclobjtype       AS obj_type,
       defaclacl           AS acl
  FROM pg_default_acl d
  LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace
 WHERE n.nspname IN ('mqtt','ems') OR n.nspname IS NULL
 LIMIT 30;
