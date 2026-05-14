package br.com.ledstar.ems.gapfiller.infra.postgres;

import br.com.ledstar.ems.gapfiller.application.GapLogRepository;
import br.com.ledstar.ems.gapfiller.domain.BackfillRequest;
import br.com.ledstar.ems.gapfiller.support.IntegrationTestBase;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.JdbcTemplate;

import java.time.LocalDateTime;
import java.util.Map;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class JdbcGapLogRepositoryIT extends IntegrationTestBase {

    @Autowired
    GapLogRepository gapLog;

    @Autowired
    JdbcTemplate jdbc;

    @Test
    void recordRecentGravaLinhaECalculaDuracao() {
        jdbc.update("DELETE FROM ems.gap_log WHERE gpl_sensor = 10120");

        gapLog.record(10120L,
                LocalDateTime.of(2026, 5, 7, 0, 0),
                LocalDateTime.of(2026, 5, 7, 9, 0),     // 9h = 32400s
                BackfillRequest.Mode.RECENT, 100L, 5L, "ok", null);

        Map<String, Object> row = jdbc.queryForMap("""
                SELECT gpl_mode, gpl_inserted, gpl_skipped, gpl_status, gpl_duration_sec, gpl_request_id
                  FROM ems.gap_log
                 WHERE gpl_sensor = 10120
                """);
        assertThat(row.get("gpl_mode")).isEqualTo("RECENT");
        assertThat(((Number) row.get("gpl_inserted")).longValue()).isEqualTo(100L);
        assertThat(((Number) row.get("gpl_skipped")).longValue()).isEqualTo(5L);
        assertThat(row.get("gpl_status")).isEqualTo("ok");
        assertThat(((Number) row.get("gpl_duration_sec")).intValue()).isEqualTo(32_400);
        assertThat(row.get("gpl_request_id")).isNull();
    }

    @Test
    void recordHistoricalGuardaRequestIdEStatusLongo() {
        jdbc.update("DELETE FROM ems.gap_log WHERE gpl_sensor = 10121");
        UUID requestId = UUID.randomUUID();
        // gpl_status agora e varchar(200) (V77) - cabe a mensagem crua do postgres
        String longStatus = "error: relation \"mqtt.sensordatarecord\" does not exist (sensor sem telemetria)";

        gapLog.record(10121L,
                LocalDateTime.of(2024, 1, 1, 0, 0),
                LocalDateTime.of(2024, 1, 2, 0, 0),
                BackfillRequest.Mode.HISTORICAL, 0L, 0L, longStatus, requestId);

        Map<String, Object> row = jdbc.queryForMap(
                "SELECT gpl_mode, gpl_status, gpl_request_id FROM ems.gap_log WHERE gpl_sensor = 10121");
        assertThat(row.get("gpl_mode")).isEqualTo("HISTORICAL");
        assertThat(row.get("gpl_status")).isEqualTo(longStatus);
        assertThat(row.get("gpl_request_id")).isEqualTo(requestId);
    }
}
