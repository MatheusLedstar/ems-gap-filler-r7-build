package br.com.ledstar.ems.gapfiller.infra.postgres;

import br.com.ledstar.ems.gapfiller.application.TelemetryQueryRepository;
import br.com.ledstar.ems.gapfiller.domain.SensorReading;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.sql.Timestamp;
import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

@Repository
public class JdbcTelemetryQueryRepository implements TelemetryQueryRepository {

    private final JdbcTemplate jdbc;

    public JdbcTelemetryQueryRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @Override
    public List<LocalDateTime> findReadingTimestamps(long sensorId,
                                                     LocalDateTime windowStart,
                                                     LocalDateTime windowEnd) {
        return jdbc.query("""
            SELECT DISTINCT sdr_creation
              FROM mqtt.sensordatarecord
             WHERE sdr_sensor = ?
               AND sdr_active = true
               AND sdr_creation >= ?
               AND sdr_creation <  ?
             ORDER BY sdr_creation
            """,
            (rs, i) -> rs.getTimestamp(1).toLocalDateTime(),
            sensorId, Timestamp.valueOf(windowStart), Timestamp.valueOf(windowEnd));
    }

    @Override
    public List<SensorReading> findActiveReadings(long sensorId,
                                                  LocalDateTime windowStart,
                                                  LocalDateTime windowEnd) {
        return jdbc.query("""
            SELECT  sdr_sensor, sdr_creation, sdr_valuetype, sdr_value,
                    sdr_unit_measurement, sdr_json::text AS json_text
              FROM  mqtt.sensordatarecord
             WHERE  sdr_sensor   = ?
               AND  sdr_active   = true
               AND  sdr_creation >= ?
               AND  sdr_creation <  ?
             ORDER  BY sdr_creation, sdr_valuetype
            """,
            (rs, i) -> new SensorReading(
                rs.getLong("sdr_sensor"),
                rs.getTimestamp("sdr_creation").toLocalDateTime(),
                rs.getString("sdr_valuetype"),
                (Double) rs.getObject("sdr_value"),
                rs.getString("sdr_unit_measurement"),
                rs.getString("json_text")
            ),
            sensorId, Timestamp.valueOf(windowStart), Timestamp.valueOf(windowEnd));
    }

    @Override
    public Optional<LocalDateTime> findLastReadingFor(long sensorId) {
        var list = jdbc.query("""
            SELECT MAX(sdr_creation) AS last
              FROM mqtt.last_sensor_value
             WHERE sdr_sensor = ?
               AND sdr_active = true
            """,
            (rs, i) -> {
                Timestamp t = rs.getTimestamp("last");
                return t == null ? null : t.toLocalDateTime();
            },
            sensorId);
        return list.isEmpty() ? Optional.empty() : Optional.ofNullable(list.get(0));
    }

    @Override
    public boolean existsReading(SensorReading.DedupKey key) {
        Integer hit = jdbc.query("""
            SELECT 1 FROM mqtt.sensordatarecord
             WHERE sdr_sensor    = ?
               AND sdr_valuetype = ?
               AND sdr_creation  = ?
               AND sdr_active    = true
             LIMIT 1
            """,
            rs -> rs.next() ? rs.getInt(1) : null,
            key.sensorId(), key.valueType(), Timestamp.valueOf(key.creation()));
        return hit != null;
    }
}
