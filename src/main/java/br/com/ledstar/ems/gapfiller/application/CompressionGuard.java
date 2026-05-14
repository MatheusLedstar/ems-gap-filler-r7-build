package br.com.ledstar.ems.gapfiller.application;

import java.time.LocalDateTime;
import java.util.List;
import java.util.function.Supplier;

/**
 * Coordena seguranca de operacoes em chunks comprimidos:
 *   1) advisory_lock no nome do servico
 *   2) pause policy_compression via alter_job
 *   3) decompress_chunk dos chunks afetados
 *   4) executa o trabalho (insert/update/delete)
 *   5) recompress_chunk no finally
 *   6) reabilita policy_compression
 *   7) libera advisory_lock no finally
 *
 * Garante que policy_compression nao roda concomitante e que chunks ficam
 * recomprimidos mesmo se o trabalho falhar.
 */
public interface CompressionGuard {

    /**
     * Executa work com chunks da janela descomprimidos.
     * Recomprime todos no finally, mesmo em erro.
     */
    <T> T runWithDecompressed(LocalDateTime windowStart,
                              LocalDateTime windowEnd,
                              Supplier<T> work);

    /**
     * Identifica chunks ATIVOS comprimidos na janela. Read-only.
     */
    List<String> findCompressedChunksFor(LocalDateTime start, LocalDateTime end);
}
