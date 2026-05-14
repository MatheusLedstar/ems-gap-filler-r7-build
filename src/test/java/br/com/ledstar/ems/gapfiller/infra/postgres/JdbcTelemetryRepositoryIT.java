package br.com.ledstar.ems.gapfiller.infra.postgres;

import br.com.ledstar.ems.gapfiller.application.TelemetryQueryRepository;
import br.com.ledstar.ems.gapfiller.application.TelemetryWriteRepository;
import br.com.ledstar.ems.gapfiller.application.TelemetryWriteRepository.InsertResult;
import br.com.ledstar.ems.gapfiller.domain.SensorReading;
import br.com.ledstar.ems.gapfiller.support.IntegrationTestBase;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.JdbcTemplate;

import java.time.LocalDateTime;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Integracao dos repositorios de telemetria contra a hypertable real
 * mqtt.sensordatarecord (TimescaleDB no Testcontainers).
 *
 * Cobre o caso central da reconciliacao: insert idempotente (dedup pre-INSERT
 * pelo idx_sensordatarecord_sensor_type_creation, ja que nao ha UNIQUE) e
 * soft-delete (sdr_active = false) deixando a leitura corrigida re-inserivel.
 */
class JdbcTelemetryRepositoryIT extends IntegrationTestBase {

    @Autowired
    TelemetryWriteRepository write;

    @Autowired
    TelemetryQueryRepository query;

    @Autowired
    JdbcTemplate jdbc;

    private static final long SENSOR = 30L;
    private static final LocalDateTime T0 = LocalDateTime.of(2026, 5, 7, 10, 0);
    private static final LocalDateTime T1 = LocalDateTime.of(2026, 5, 7, 10, 5);

    @BeforeEach
    void clean() {
        jdbc.update("DELETE FROM mqtt.sensordatarecord WHERE sdr_sensor = ?", SENSOR);
    }

    private static SensorReading reading(LocalDateTime ts, double value) {
        return new SensorReading(SENSOR, ts, "KWH", value, "kWh", null);
    }

    @Test
    void insertBatchInsereEEhIdempotente() {
        InsertResult first = write.insertBatch(List.of(reading(T0, 100.0)));
        assertThat(first.inserted()).isEqualTo(1);
        assertThat(first.skipped()).isZero();

        assertThat(query.existsReading(new SensorReading.DedupKey(SENSOR, T0, "KWH"))).isTrue();
        assertThat(query.existsReading(new SensorReading.DedupKey(SENSOR, T1, "KWH"))).isFalse();

        // re-inserir a mesma leitura -> skip (dedup)
        InsertResult again = write.insertBatch(List.of(reading(T0, 100.0)));
        assertThat(again.inserted()).isZero();
        assertThat(again.skipped()).isEqualTo(1);
    }

    @Test
    void findActiveReadingsRespeitaJanelaESoftDelete() {
        write.insertBatch(List.of(reading(T0, 100.0), reading(T1, 200.0)));

        List<SensorReading> inWindow = query.findActiveReadings(SENSOR, T0, T1.plusMinutes(1));
        assertThat(inWindow).extracting(SensorReading::value).containsExactly(100.0, 200.0);

        // janela [T0, T1) -> exclui T1 (limite superior aberto)
        assertThat(query.findActiveReadings(SENSOR, T0, T1)).extracting(SensorReading::value)
                .containsExactly(100.0);

        // soft-delete da leitura T0
        int rows = write.softDelete(new SensorReading.DedupKey(SENSOR, T0, "KWH"));
        assertThat(rows).isEqualTo(1);
        assertThat(query.findActiveReadings(SENSOR, T0, T1.plusMinutes(1)))
                .extracting(SensorReading::value).containsExactly(200.0);
        assertThat(query.existsReading(new SensorReading.DedupKey(SENSOR, T0, "KWH"))).isFalse();
    }

    @Test
    void soltDeleteSeguidoDeInsertGravaAValorCorrigido() {
        write.insertBatch(List.of(reading(T0, 50.0)));        // valor anomalo
        write.softDelete(new SensorReading.DedupKey(SENSOR, T0, "KWH"));
        InsertResult corrected = write.insertBatch(List.of(reading(T0, 250.0)));   // correcao
        assertThat(corrected.inserted()).isEqualTo(1);

        List<SensorReading> active = query.findActiveReadings(SENSOR, T0, T0.plusSeconds(1));
        assertThat(active).hasSize(1);
        assertThat(active.get(0).value()).isEqualTo(250.0);

        // o registro antigo continua na hypertable, so que inativo (append-only)
        Integer inactive = jdbc.queryForObject(
                "SELECT count(*) FROM mqtt.sensordatarecord WHERE sdr_sensor = ? AND sdr_active = false",
                Integer.class, SENSOR);
        assertThat(inactive).isEqualTo(1);
    }

    @Test
    void replaceReadingFazSoftDeleteEInsertNumaTransacao() {
        write.insertBatch(List.of(reading(T0, 50.0)));        // valor anomalo no banco
        write.replaceReading(new SensorReading.DedupKey(SENSOR, T0, "KWH"), reading(T0, 250.0));

        List<SensorReading> active = query.findActiveReadings(SENSOR, T0, T0.plusSeconds(1));
        assertThat(active).hasSize(1);
        assertThat(active.get(0).value()).isEqualTo(250.0);

        Integer inactive = jdbc.queryForObject(
                "SELECT count(*) FROM mqtt.sensordatarecord WHERE sdr_sensor = ? AND sdr_active = false",
                Integer.class, SENSOR);
        assertThat(inactive).isEqualTo(1);
    }

    @Test
    void findReadingTimestampsRetornaDistinctOrdenado() {
        write.insertBatch(List.of(reading(T1, 200.0), reading(T0, 100.0)));
        List<LocalDateTime> ts = query.findReadingTimestamps(SENSOR, T0, T1.plusMinutes(1));
        assertThat(ts).containsExactly(T0, T1);
    }
}
