package br.com.ledstar.ems.gapfiller.infra.postgres;

import br.com.ledstar.ems.gapfiller.application.TelemetryWriteRepository;
import br.com.ledstar.ems.gapfiller.domain.SensorReading;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;
import org.springframework.transaction.annotation.Transactional;

import java.sql.Timestamp;
import java.time.Duration;
import java.time.LocalDateTime;
import java.time.format.DateTimeFormatter;
import java.util.ArrayList;
import java.util.List;

@Repository
public class JdbcTelemetryWriteRepository implements TelemetryWriteRepository {

    private static final Logger log = LoggerFactory.getLogger(JdbcTelemetryWriteRepository.class);

    private final JdbcTemplate jdbc;

    public JdbcTelemetryWriteRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** Formato aceito direto pelo PG como literal de TIMESTAMP. */
    private static final DateTimeFormatter PG_TS = DateTimeFormatter.ofPattern("yyyy-MM-dd HH:mm:ss");

    /**
     * INSERT idempotente - checa via idx_sensordatarecord_sensor_type_creation se ja existe.
     * Faz dedup pre-INSERT por causa de ausencia de UNIQUE constraint na hypertable.
     */
    @Override
    public InsertResult insertBatch(List<SensorReading> readings) {
        if (readings.isEmpty()) return new InsertResult(0, 0);

        // 1) build set de chaves a checar
        long inserted = 0, skipped = 0;
        for (SensorReading r : readings) {
            // dedup check
            Integer hit = jdbc.query("""
                SELECT 1 FROM mqtt.sensordatarecord
                 WHERE sdr_sensor    = ?
                   AND sdr_valuetype = ?
                   AND sdr_creation  = ?
                   AND sdr_active    = true
                 LIMIT 1
                """,
                rs -> rs.next() ? 1 : null,
                r.sensorId(), r.valueType(), Timestamp.valueOf(r.creation()));

            if (hit != null) {
                skipped++;
                continue;
            }

            int rows = jdbc.update("""
                INSERT INTO mqtt.sensordatarecord (
                    sdr_active, sdr_creation, sdr_last_updated,
                    sdr_sensor, sdr_valuetype, sdr_unit_measurement,
                    sdr_json, sdr_enable, sdr_value
                ) VALUES (true, ?, now(), ?, ?, ?, ?::jsonb, true, ?)
                """,
                Timestamp.valueOf(r.creation()),
                r.sensorId(),
                r.valueType(),
                r.unitMeasurement(),
                r.json(),
                r.value());

            if (rows == 1) inserted++;
        }

        log.info("insertBatch size={} inserted={} skipped={}", readings.size(), inserted, skipped);
        return new InsertResult(inserted, skipped);
    }

    /**
     * Soft-delete por chave - marca sdr_active=false em todas leituras do (sensor, valuetype, creation).
     */
    @Override
    public int softDelete(SensorReading.DedupKey key) {
        int rows = jdbc.update("""
            UPDATE mqtt.sensordatarecord
               SET sdr_active = false,
                   sdr_last_updated = now()
             WHERE sdr_sensor    = ?
               AND sdr_valuetype = ?
               AND sdr_creation  = ?
               AND sdr_active    = true
            """,
            key.sensorId(), key.valueType(), Timestamp.valueOf(key.creation()));
        if (rows > 0) {
            log.info("softDelete sensor={} valuetype={} creation={} rows={}",
                     key.sensorId(), key.valueType(), key.creation(), rows);
        }
        return rows;
    }

    @Override
    public int softDeleteBatch(List<SensorReading.DedupKey> keys) {
        int total = 0;
        for (SensorReading.DedupKey k : keys) {
            total += softDelete(k);
        }
        return total;
    }

    /**
     * Soft-delete + INSERT na MESMA transacao. O dedup-check do {@link #insertBatch} ve o
     * soft-delete (mesma conexao/tx) entao a leitura boa entra mesmo tendo a chave igual.
     */
    @Override
    @Transactional
    public void replaceReading(SensorReading.DedupKey badKey, SensorReading replacement) {
        softDelete(badKey);
        insertBatch(List.of(replacement));
    }

    /**
     * Identifica chunks que cobrem a janela. Usa show_chunks pra listar e
     * decompress_chunk pra cada um. Caro - so usar quando janela > 7d.
     */
    @Override
    public List<String> decompressChunksFor(LocalDateTime windowStart, LocalDateTime windowEnd) {
        List<String> chunks = jdbc.query("""
            SELECT format('%I.%I', chunk_schema, chunk_name)
              FROM timescaledb_information.chunks
             WHERE hypertable_schema = 'mqtt'
               AND hypertable_name   = 'sensordatarecord'
               AND is_compressed     = true
               AND range_start <  ?
               AND range_end   >= ?
             ORDER BY range_start
            """,
            (rs, i) -> rs.getString(1),
            Timestamp.valueOf(windowEnd), Timestamp.valueOf(windowStart));

        List<String> done = new ArrayList<>();
        for (String chunk : chunks) {
            try {
                jdbc.execute("SELECT decompress_chunk('" + chunk + "')");
                done.add(chunk);
                log.info("decompress_chunk OK: {}", chunk);
            } catch (Exception ex) {
                log.warn("decompress_chunk falhou {}: {}", chunk, ex.getMessage());
            }
        }
        return done;
    }

    @Override
    public void recompressChunks(List<String> chunkNames) {
        for (String chunk : chunkNames) {
            try {
                jdbc.execute("SELECT compress_chunk('" + chunk + "', if_not_compressed => true)");
                log.info("compress_chunk OK: {}", chunk);
            } catch (Exception ex) {
                log.warn("compress_chunk falhou {}: {}", chunk, ex.getMessage());
            }
        }
    }

    /**
     * Refresh CAG hourly (sempre) em cascata pra daily/monthly conforme a idade da janela.
     * Usa o procedimento padrao do TimescaleDB {@code CALL refresh_continuous_aggregate(cagg, start, end)}.
     *
     * <p>IMPORTANTE (fix r5, 13/05/2026): {@code refresh_continuous_aggregate} eh PROCEDURE e
     * gerencia tx propria. Usar {@code NamedParameterJdbcTemplate.update(...)} com {@code :start}/
     * {@code :end} faz o driver PG montar um PreparedStatement com placeholders {@code ?} dentro do
     * {@code CALL}, e o parser quebra com {@code "bad SQL grammar"} (vide prod 13/05). A solucao eh
     * inline-literal via {@link JdbcTemplate#execute(String)} (sem placeholders, sem prepared stmt).
     * Risco de SQL injection = ZERO: {@code LocalDateTime} eh tipo Java, nao input do usuario.
     *
     * <p>Versoes antigas chamavam uma proc custom {@code mqtt.sdr_hourly_refresh} que nao existe nos
     * bancos reais. Se o refresh hourly falhar mesmo assim, NAO derruba o reconcile (o dado ja foi
     * corrigido): a policy nativa {@code policy_refresh CAG hourly} (a cada 15min, start_offset 3
     * dias) atualiza o CAG sozinha.
     */
    @Override
    public void refreshContinuousAggregates(LocalDateTime windowStart, LocalDateTime windowEnd) {
        Duration age = Duration.between(windowStart, LocalDateTime.now());

        refreshOne("mqtt.sdr_hourly", windowStart, windowEnd);
        if (age.toDays() > 30)  refreshOne("mqtt.sdr_daily",   windowStart, windowEnd);
        if (age.toDays() > 365) refreshOne("mqtt.sdr_monthly", windowStart, windowEnd);
    }

    private void refreshOne(String cag, LocalDateTime start, LocalDateTime end) {
        String sql = buildRefreshSql(cag, start, end);
        try {
            jdbc.execute(sql);
            log.info("refresh {} {} -> {}", cag, start, end);
        } catch (Exception ex) {
            log.warn("refresh {} fallback ({}): CAG sera atualizado pela policy nativa em <=15min",
                     cag, ex.getMessage());
        }
    }

    /** Monta o {@code CALL} com timestamps como literal {@code TIMESTAMP 'yyyy-MM-dd HH:mm:ss'}. */
    static String buildRefreshSql(String cag, LocalDateTime start, LocalDateTime end) {
        return "CALL refresh_continuous_aggregate('" + cag + "', "
             + "TIMESTAMP '" + PG_TS.format(start) + "', "
             + "TIMESTAMP '" + PG_TS.format(end) + "')";
    }
}
