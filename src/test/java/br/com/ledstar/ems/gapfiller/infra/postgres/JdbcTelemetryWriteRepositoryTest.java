package br.com.ledstar.ems.gapfiller.infra.postgres;

import org.junit.jupiter.api.Test;

import java.time.LocalDateTime;

import static org.assertj.core.api.Assertions.assertThat;

class JdbcTelemetryWriteRepositoryTest {

    /**
     * Fix r5 (13/05/2026): refresh CAG via {@link JdbcTemplate#execute(String)} com timestamps
     * literais. O placeholder com {@code :start}/{@code :end} quebrava o {@code CALL} no PG real
     * em prod (PSQLException 'bad SQL grammar'). O SQL agora eh montado uma string + execute.
     */
    @Test
    void buildRefreshSql_produzCallComTimestampLiteralFormatPg() {
        String sql = JdbcTelemetryWriteRepository.buildRefreshSql(
            "mqtt.sdr_hourly",
            LocalDateTime.of(2026, 5, 13, 7, 43, 0),
            LocalDateTime.of(2026, 5, 13, 9, 43, 0));

        assertThat(sql).isEqualTo(
            "CALL refresh_continuous_aggregate('mqtt.sdr_hourly', "
            + "TIMESTAMP '2026-05-13 07:43:00', "
            + "TIMESTAMP '2026-05-13 09:43:00')");
    }

    @Test
    void buildRefreshSql_preservaSegundosNaoZerados() {
        String sql = JdbcTelemetryWriteRepository.buildRefreshSql(
            "mqtt.sdr_daily",
            LocalDateTime.of(2026, 3, 18, 19, 5, 7),
            LocalDateTime.of(2026, 3, 19, 19, 5, 7));

        assertThat(sql)
            .contains("'mqtt.sdr_daily'")
            .contains("TIMESTAMP '2026-03-18 19:05:07'")
            .contains("TIMESTAMP '2026-03-19 19:05:07'");
    }
}
