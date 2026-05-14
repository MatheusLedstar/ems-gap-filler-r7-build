package br.com.ledstar.ems.gapfiller.infra.postgres;

import br.com.ledstar.ems.gapfiller.application.BackfillRequestRepository;
import br.com.ledstar.ems.gapfiller.domain.BackfillRequest;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;
import org.springframework.stereotype.Repository;

import java.sql.Array;
import java.sql.Timestamp;
import java.time.LocalDateTime;
import java.util.Arrays;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

@Repository
public class JdbcBackfillRequestRepository implements BackfillRequestRepository {

    private final JdbcTemplate jdbc;

    public JdbcBackfillRequestRepository(JdbcTemplate jdbc) {
        this.jdbc = jdbc;
    }

    @Override
    public BackfillRequest create(BackfillRequest req) {
        Long[] sensors = req.sensorIds() == null ? null
            : req.sensorIds().toArray(Long[]::new);

        jdbc.update(con -> {
            var stmt = con.prepareStatement("""
                INSERT INTO ems.backfill_request (
                    bfr_id, bfr_mode, bfr_sensor_ids, bfr_window_start, bfr_window_end,
                    bfr_status, bfr_created_at, bfr_requested_by
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """);
            stmt.setObject(1, req.id());
            stmt.setString(2, req.mode().name());
            stmt.setArray(3, sensors == null ? null : con.createArrayOf("bigint", sensors));
            stmt.setTimestamp(4, Timestamp.valueOf(req.windowStart()));
            stmt.setTimestamp(5, Timestamp.valueOf(req.windowEnd()));
            stmt.setString(6, req.status().name());
            stmt.setTimestamp(7, Timestamp.valueOf(req.createdAt()));
            stmt.setString(8, req.requestedBy());
            return stmt;
        });
        return req;
    }

    @Override
    public Optional<BackfillRequest> findById(UUID id) {
        var list = jdbc.query("SELECT * FROM ems.backfill_request WHERE bfr_id = ?", mapper(), id);
        return list.isEmpty() ? Optional.empty() : Optional.of(list.get(0));
    }

    @Override
    public void updateStatus(UUID id, BackfillRequest.Status status, String errorMessage) {
        boolean isTerminal = status == BackfillRequest.Status.COMPLETED
                          || status == BackfillRequest.Status.FAILED
                          || status == BackfillRequest.Status.CANCELLED;
        boolean isStart = status == BackfillRequest.Status.RUNNING;

        jdbc.update("""
            UPDATE ems.backfill_request
               SET bfr_status      = ?,
                   bfr_error       = ?,
                   bfr_started_at  = COALESCE(bfr_started_at, CASE WHEN ? THEN now() END),
                   bfr_finished_at = CASE WHEN ? THEN now() ELSE bfr_finished_at END
             WHERE bfr_id = ?
            """,
            status.name(), errorMessage, isStart, isTerminal, id);
    }

    @Override
    public void updateCounters(UUID id, long inserted, long skipped) {
        jdbc.update("""
            UPDATE ems.backfill_request
               SET bfr_inserted = ?, bfr_skipped = ?
             WHERE bfr_id = ?
            """, inserted, skipped, id);
    }

    @Override
    public Optional<BackfillRequest> findNextQueued() {
        var list = jdbc.query("""
            SELECT * FROM ems.backfill_request
             WHERE bfr_status = 'QUEUED'
             ORDER BY bfr_created_at
             LIMIT 1
            """, mapper());
        return list.isEmpty() ? Optional.empty() : Optional.of(list.get(0));
    }

    private RowMapper<BackfillRequest> mapper() {
        return (rs, i) -> {
            Array arr = rs.getArray("bfr_sensor_ids");
            List<Long> sensorIds = null;
            if (arr != null) {
                Long[] xs = (Long[]) arr.getArray();
                sensorIds = Arrays.asList(xs);
            }
            return new BackfillRequest(
                (UUID) rs.getObject("bfr_id"),
                BackfillRequest.Mode.valueOf(rs.getString("bfr_mode")),
                sensorIds,
                rs.getTimestamp("bfr_window_start").toLocalDateTime(),
                rs.getTimestamp("bfr_window_end").toLocalDateTime(),
                BackfillRequest.Status.valueOf(rs.getString("bfr_status")),
                rs.getTimestamp("bfr_created_at").toLocalDateTime(),
                opt(rs.getTimestamp("bfr_started_at")),
                opt(rs.getTimestamp("bfr_finished_at")),
                rs.getLong("bfr_inserted"),
                rs.getLong("bfr_skipped"),
                rs.getString("bfr_error"),
                rs.getString("bfr_requested_by")
            );
        };
    }

    private static LocalDateTime opt(Timestamp t) {
        return t == null ? null : t.toLocalDateTime();
    }
}
