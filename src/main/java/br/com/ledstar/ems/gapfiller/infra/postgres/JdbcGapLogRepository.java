package br.com.ledstar.ems.gapfiller.infra.postgres;

import br.com.ledstar.ems.gapfiller.application.GapLogRepository;
import br.com.ledstar.ems.gapfiller.domain.BackfillRequest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Repository;

import java.sql.Timestamp;
import java.time.LocalDateTime;
import java.util.UUID;

@Repository
public class JdbcGapLogRepository implements GapLogRepository {

    private final JdbcTemplate jdbc;

    public JdbcGapLogRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    /** gpl_status e varchar(200) (V77); trunca por seguranca caso chegue mensagem maior. */
    private static final int MAX_STATUS = 200;

    @Override
    public void record(long sensorId, LocalDateTime windowStart, LocalDateTime windowEnd,
                       BackfillRequest.Mode mode, long inserted, long skipped, String status, UUID requestId) {
        String safeStatus = status != null && status.length() > MAX_STATUS
            ? status.substring(0, MAX_STATUS) : status;
        jdbc.update("""
            INSERT INTO ems.gap_log (
                gpl_sensor, gpl_window_start, gpl_window_end,
                gpl_mode, gpl_inserted, gpl_skipped, gpl_status, gpl_request_id
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            sensorId,
            Timestamp.valueOf(windowStart),
            Timestamp.valueOf(windowEnd),
            mode.name(),
            inserted, skipped, safeStatus,
            requestId);
    }
}
