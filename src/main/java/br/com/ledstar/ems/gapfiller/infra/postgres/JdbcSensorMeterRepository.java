package br.com.ledstar.ems.gapfiller.infra.postgres;

import br.com.ledstar.ems.gapfiller.application.SensorMeterRepository;
import br.com.ledstar.ems.gapfiller.domain.SensorMeter;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Repository;

import java.time.Duration;
import java.util.List;
import java.util.Optional;

@Repository
public class JdbcSensorMeterRepository implements SensorMeterRepository {

    private final JdbcTemplate jdbc;
    private final String pgpKey;
    private final boolean useEncryption;

    public JdbcSensorMeterRepository(JdbcTemplate jdbc,
                                     @Value("${gapfiller.crypto.pgp-key:}") String pgpKey) {
        this.jdbc = jdbc;
        this.pgpKey = pgpKey;
        this.useEncryption = pgpKey != null && !pgpKey.isBlank();
    }

    /**
     * SQL base. Quando {@code gapfiller.crypto.pgp-key} esta vazio (caso atual: senhas em texto puro
     * no seed V74), a query NAO pode sequer mencionar {@code pgp_sym_decrypt}: o Postgres resolve a
     * funcao em parse/plan, antes de avaliar qualquer CASE, entao um {@code ELSE pgp_sym_decrypt(...)}
     * estoura com "function pgp_sym_decrypt does not exist" se a extensao pgcrypto nao estiver instalada
     * (ex: o TimescaleDB do HOM). Por isso ha duas variantes, escolhidas em runtime.
     */
    private String baseSelect() {
        String pwExpr = useEncryption ? "pgp_sym_decrypt(fts_password_enc::bytea, ?)" : "fts_password_enc";
        return "SELECT fts_id, fts_sensor, fts_meter_ip, fts_protocol, fts_username, "
             + pwExpr + " AS password, fts_modbus_slave_id, fts_csv_path, "
             + "EXTRACT(EPOCH FROM fts_expected_freq)::int AS freq_sec, fts_active FROM ems.ftp_source";
    }

    @Override
    public List<SensorMeter> findActive() {
        String sql = baseSelect() + " WHERE fts_active = true ORDER BY fts_sensor";
        return useEncryption ? jdbc.query(sql, mapper(), pgpKey) : jdbc.query(sql, mapper());
    }

    @Override
    public Optional<SensorMeter> findBySensorId(long sensorId) {
        String sql = baseSelect() + " WHERE fts_sensor = ? AND fts_active = true LIMIT 1";
        var list = useEncryption ? jdbc.query(sql, mapper(), pgpKey, sensorId)
                                 : jdbc.query(sql, mapper(), sensorId);
        return list.isEmpty() ? Optional.empty() : Optional.of(list.get(0));
    }

    private RowMapper<SensorMeter> mapper() {
        return (rs, i) -> new SensorMeter(
            rs.getLong("fts_id"),
            rs.getLong("fts_sensor"),
            rs.getString("fts_meter_ip"),
            SensorMeter.Protocol.valueOf(rs.getString("fts_protocol")),
            rs.getString("fts_username"),
            rs.getString("password"),
            (Integer) rs.getObject("fts_modbus_slave_id"),
            rs.getString("fts_csv_path"),
            Duration.ofSeconds(rs.getLong("freq_sec")),
            rs.getBoolean("fts_active")
        );
    }
}
