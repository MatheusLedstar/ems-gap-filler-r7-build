package br.com.ledstar.ems.gapfiller.infra.postgres;

import br.com.ledstar.ems.gapfiller.application.CompressionGuard;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.stereotype.Component;

import javax.sql.DataSource;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.SQLException;
import java.sql.Timestamp;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.List;
import java.util.function.Supplier;

@Component
public class JdbcCompressionGuard implements CompressionGuard {

    private static final Logger log = LoggerFactory.getLogger(JdbcCompressionGuard.class);

    /** ID arbitrario constante pro advisory lock - mesmo em todas as instancias do worker. */
    private static final long ADVISORY_LOCK_KEY = 0x6D5F676170L;  // "m_gap" em ascii

    private final JdbcTemplate jdbc;
    private final DataSource dataSource;

    public JdbcCompressionGuard(JdbcTemplate jdbc, DataSource dataSource) {
        this.jdbc = jdbc;
        this.dataSource = dataSource;
    }

    @Override
    public List<String> findCompressedChunksFor(LocalDateTime start, LocalDateTime end) {
        return jdbc.query("""
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
            Timestamp.valueOf(end), Timestamp.valueOf(start));
    }

    /**
     * Roda `work` com os chunks da janela descomprimidos.
     *
     * O advisory lock do Postgres e POR SESSAO - tem que ser adquirido E liberado na
     * MESMA conexao. Como o {@link JdbcTemplate} pega uma conexao do pool a cada call,
     * aqui seguramos UMA conexao dedicada so pro lock; o resto (alter_job, decompress,
     * compress) roda via JdbcTemplate normalmente (sao operacoes independentes).
     */
    @Override
    public <T> T runWithDecompressed(LocalDateTime windowStart,
                                     LocalDateTime windowEnd,
                                     Supplier<T> work) {
        try (Connection lockConn = dataSource.getConnection()) {
            boolean prevAutoCommit = lockConn.getAutoCommit();
            lockConn.setAutoCommit(true);
            if (!tryAdvisoryLock(lockConn)) {
                throw new IllegalStateException(
                    "Outra operacao de descompressao/compressao em andamento. Aguarde.");
            }
            try {
                return runGuarded(windowStart, windowEnd, work);
            } finally {
                releaseAdvisoryLock(lockConn);
                try { lockConn.setAutoCommit(prevAutoCommit); } catch (SQLException ignored) { }
            }
        } catch (SQLException e) {
            throw new IllegalStateException("falha ao obter conexao para o advisory lock", e);
        }
    }

    private <T> T runGuarded(LocalDateTime windowStart, LocalDateTime windowEnd, Supplier<T> work) {
        Long compressionJobId = findJob("policy_compression");
        boolean policyPaused = false;
        List<String> decompressed = new ArrayList<>();
        try {
            if (compressionJobId != null) {
                try {
                    jdbc.execute("SELECT alter_job(" + compressionJobId + ", scheduled => false)");
                    policyPaused = true;
                    log.info("policy_compression pausada (job_id={})", compressionJobId);
                } catch (Exception ex) {
                    log.warn("nao consegui pausar policy_compression (seguindo sem pausar): {}", ex.getMessage());
                }
            }

            List<String> chunks = findCompressedChunksFor(windowStart, windowEnd);
            log.info("descomprimindo {} chunk(s) em {} -> {}", chunks.size(), windowStart, windowEnd);
            for (String chunk : chunks) {
                try {
                    jdbc.execute("SELECT decompress_chunk('" + chunk + "')");
                    decompressed.add(chunk);
                    log.info("decompress_chunk OK: {}", chunk);
                } catch (Exception ex) {
                    log.warn("decompress_chunk falhou {}: {}", chunk, ex.getMessage());
                }
            }

            return work.get();

        } finally {
            for (String chunk : decompressed) {
                try {
                    jdbc.execute("SELECT compress_chunk('" + chunk + "', if_not_compressed => true)");
                    log.info("recompress_chunk OK: {}", chunk);
                } catch (Exception ex) {
                    log.error("recompress_chunk FALHOU {}: {} - chunk fica decomprimido", chunk, ex.getMessage());
                }
            }
            if (policyPaused) {
                try {
                    jdbc.execute("SELECT alter_job(" + compressionJobId + ", scheduled => true)");
                    log.info("policy_compression reabilitada");
                } catch (Exception ex) {
                    log.error("FALHA ao reabilitar policy_compression (job_id={}) - REABILITAR MANUALMENTE: {}",
                              compressionJobId, ex.getMessage());
                }
            }
        }
    }

    private Long findJob(String procName) {
        return jdbc.query("""
            SELECT job_id FROM timescaledb_information.jobs
             WHERE proc_name = ?
             LIMIT 1
            """,
            rs -> rs.next() ? rs.getLong(1) : null,
            procName);
    }

    private boolean tryAdvisoryLock(Connection conn) {
        try (PreparedStatement ps = conn.prepareStatement("SELECT pg_try_advisory_lock(?)")) {
            ps.setLong(1, ADVISORY_LOCK_KEY);
            try (ResultSet rs = ps.executeQuery()) {
                return rs.next() && rs.getBoolean(1);
            }
        } catch (SQLException e) {
            log.warn("falha ao tentar advisory lock: {}", e.getMessage());
            return false;
        }
    }

    private void releaseAdvisoryLock(Connection conn) {
        try (PreparedStatement ps = conn.prepareStatement("SELECT pg_advisory_unlock(?)")) {
            ps.setLong(1, ADVISORY_LOCK_KEY);
            ps.execute();
        } catch (SQLException e) {
            log.warn("falha ao liberar advisory_lock: {}", e.getMessage());
        }
    }
}
