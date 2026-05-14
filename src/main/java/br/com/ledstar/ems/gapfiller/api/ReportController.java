package br.com.ledstar.ems.gapfiller.api;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.core.env.Environment;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;

import java.time.LocalDateTime;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * Endpoint de diagnóstico read-only: tira um "raio-x" do que o worker fez no banco.
 *
 * Pensado pra ser puxado logo após um deploy/run (ex: pelo {@code scripts/ems-deploy.ps1}
 * na ponte) e salvo num arquivo — assim dá pra ver, sem acesso ao banco, o resultado do
 * que o ems-gap-filler obteve / atualizou / corrigiu:
 *   - quais migrations Flyway aplicaram (V70..V76)
 *   - o catálogo de medidores (ems.ftp_source)
 *   - os pedidos de backfill HISTORICAL e seus status/contadores (ems.backfill_request)
 *   - o log append-only de gaps/anomalias tratados (ems.gap_log) + agregados
 *   - um sanity-check da telemetria (mqtt.sensordatarecord / ems.sensor) — tolerante a
 *     ambiente vazio (HOM): se a tabela não existe, reporta {@code exists:false} em vez de quebrar.
 *
 * Sem efeitos colaterais; só SELECT. Em prod o worker escuta em 127.0.0.1, então não há
 * exposição externa.
 */
@RestController
@RequestMapping("/api/v1/report")
public class ReportController {

    private static final Logger log = LoggerFactory.getLogger(ReportController.class);
    private static final int DEFAULT_LIMIT = 200;
    private static final int MAX_LIMIT = 5000;

    private final JdbcTemplate jdbc;
    private final Environment env;

    public ReportController(JdbcTemplate jdbc, Environment env) {
        this.jdbc = jdbc;
        this.env = env;
    }

    @GetMapping
    public Map<String, Object> report(@RequestParam(name = "limit", required = false) Integer limit) {
        int lim = limit == null ? DEFAULT_LIMIT : Math.max(1, Math.min(limit, MAX_LIMIT));

        Map<String, Object> out = new LinkedHashMap<>();
        out.put("generatedAt", LocalDateTime.now().toString());
        out.put("profiles", env.getActiveProfiles());
        out.put("limit", lim);

        out.put("flyway", section(() -> jdbc.queryForList("""
                SELECT installed_rank, version, description, type, success,
                       installed_on, execution_time
                  FROM ems.ems_gap_filler_flyway_history
                 ORDER BY installed_rank""")));

        out.put("ftpSource", section(() -> {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("count", jdbc.queryForObject("SELECT count(*) FROM ems.ftp_source", Long.class));
            m.put("rows", jdbc.queryForList("""
                    SELECT fts_id, fts_sensor, fts_meter_ip, fts_protocol, fts_modbus_slave_id,
                           fts_csv_path, fts_expected_freq::text AS fts_expected_freq, fts_active
                      FROM ems.ftp_source
                     ORDER BY fts_sensor"""));
            return m;
        }));

        // `lim` é um int já clampado em [1, MAX_LIMIT] — seguro concatenar no LIMIT (não vem do usuário como string).
        // NOTA: text blocks Java removem espaço em branco no fim de cada linha, então o " LIMIT " tem que vir
        // da concatenação (não do final do bloco) senão sai "LIMIT2000" colado.
        String limitClause = " LIMIT " + lim;

        // bfr_sensor_ids e bigint[] -> o driver devolve PgArray, que o Jackson nao serializa (segue
        // getResultSet()->...->QueryExecutor e estoura). Cast pra text resolve: vira "{30}".
        out.put("backfillRequests", section(() -> jdbc.queryForList("""
                SELECT bfr_id, bfr_mode, bfr_sensor_ids::text AS bfr_sensor_ids,
                       bfr_window_start, bfr_window_end,
                       bfr_status, bfr_created_at, bfr_started_at, bfr_finished_at,
                       bfr_inserted, bfr_skipped, bfr_error, bfr_requested_by
                  FROM ems.backfill_request
                 ORDER BY bfr_created_at DESC""" + limitClause)));

        // gap_log: cada sub-trecho dentro do seu section() — se um falhar (ex: LIMIT colado), os outros ainda vêm.
        Map<String, Object> gapLog = new LinkedHashMap<>();
        gapLog.put("count", section(() -> jdbc.queryForObject("SELECT count(*) FROM ems.gap_log", Long.class)));
        gapLog.put("byStatus", section(() -> jdbc.queryForList("""
                SELECT gpl_status, count(*) AS n,
                       sum(gpl_inserted) AS inserted, sum(gpl_skipped) AS skipped
                  FROM ems.gap_log GROUP BY gpl_status ORDER BY n DESC""")));
        gapLog.put("byModeSensor", section(() -> jdbc.queryForList("""
                SELECT gpl_mode, gpl_sensor, count(*) AS n,
                       sum(gpl_inserted) AS inserted, sum(gpl_skipped) AS skipped
                  FROM ems.gap_log GROUP BY gpl_mode, gpl_sensor ORDER BY gpl_mode, gpl_sensor""")));
        gapLog.put("recent", section(() -> jdbc.queryForList("""
                SELECT gpl_id, gpl_creation, gpl_sensor, gpl_window_start, gpl_window_end,
                       gpl_duration_sec, gpl_mode, gpl_inserted, gpl_skipped, gpl_status, gpl_request_id
                  FROM ems.gap_log ORDER BY gpl_creation DESC""" + limitClause)));
        out.put("gapLog", gapLog);

        out.put("telemetry", telemetrySanity());

        return out;
    }

    /** Sanity-check tolerante: o HOM "vazio" pode não ter o schema {@code mqtt} nem {@code ems.sensor}. */
    private Map<String, Object> telemetrySanity() {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("mqttSensorDataRecord", section(() -> {
            Map<String, Object> t = new LinkedHashMap<>();
            String reg = jdbc.queryForObject("SELECT to_regclass('mqtt.sensordatarecord')::text", String.class);
            t.put("exists", reg != null);
            if (reg != null) {
                t.put("rowCount", jdbc.queryForObject("SELECT count(*) FROM mqtt.sensordatarecord", Long.class));
                t.put("activeRowCount", jdbc.queryForObject(
                        "SELECT count(*) FROM mqtt.sensordatarecord WHERE sdr_active", Long.class));
                t.put("latestCreation", jdbc.queryForObject(
                        "SELECT max(sdr_creation)::text FROM mqtt.sensordatarecord", String.class));
            }
            return t;
        }));
        m.put("emsSensor", section(() -> {
            Map<String, Object> t = new LinkedHashMap<>();
            String reg = jdbc.queryForObject("SELECT to_regclass('ems.sensor')::text", String.class);
            t.put("exists", reg != null);
            if (reg != null) {
                t.put("count", jdbc.queryForObject("SELECT count(*) FROM ems.sensor", Long.class));
            }
            return t;
        }));
        m.put("ftpSourceFk", section(() -> {
            Long n = jdbc.queryForObject("""
                    SELECT count(*) FROM pg_constraint
                     WHERE conname = 'fk_ftp_source_sensor'
                       AND conrelid = 'ems.ftp_source'::regclass""", Long.class);
            return Map.of("fk_ftp_source_sensor_present", n != null && n > 0);
        }));
        return m;
    }

    /** Roda um trecho e, se der erro (tabela ausente, etc.), devolve {@code {"error": "..."}} em vez de estourar 500. */
    private Object section(java.util.concurrent.Callable<?> body) {
        try {
            return body.call();
        } catch (Exception e) {
            log.warn("report: trecho falhou: {}", e.toString());
            return Map.of("error", e.getClass().getSimpleName() + ": " + e.getMessage());
        }
    }
}
