package br.com.ledstar.ems.gapfiller.infra.postgres;

import br.com.ledstar.ems.gapfiller.application.CompressionGuard;
import br.com.ledstar.ems.gapfiller.support.IntegrationTestBase;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.JdbcTemplate;

import java.time.LocalDateTime;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

/**
 * Exercita o CompressionGuard contra TimescaleDB real (Testcontainers): introspecção
 * de chunks comprimidos e o ciclo do advisory lock em runWithDecompressed (adquirido
 * e liberado na mesma conexão dedicada, mesmo com exceção no work).
 */
class JdbcCompressionGuardIT extends IntegrationTestBase {

    @Autowired
    CompressionGuard compressionGuard;

    @Autowired
    JdbcTemplate jdbc;

    @Test
    void findCompressedChunksForNaoEncontraNadaEmBancoFresco() {
        // garante a existencia de pelo menos um chunk (sem politica de compressao)
        jdbc.update("""
                INSERT INTO mqtt.sensordatarecord
                       (sdr_active, sdr_creation, sdr_sensor, sdr_valuetype, sdr_value, sdr_enable)
                VALUES (true, TIMESTAMP '2026-01-15 12:00:00', 30, 'KWH', 1234.0, true)
                """);

        assertThat(compressionGuard.findCompressedChunksFor(
                LocalDateTime.of(2026, 1, 1, 0, 0),
                LocalDateTime.of(2026, 2, 1, 0, 0)))
                .isEmpty();
    }

    @Test
    void runWithDecompressedExecutaOWorkEDevolveOResultado() {
        Integer result = compressionGuard.runWithDecompressed(
                LocalDateTime.of(2026, 1, 1, 0, 0),
                LocalDateTime.of(2026, 1, 8, 0, 0),
                () -> 42);
        assertThat(result).isEqualTo(42);
    }

    @Test
    void runWithDecompressedLiberaOAdvisoryLockMesmoComExcecaoNoWork() {
        // 1a chamada: o work estoura -> a excecao propaga, mas o lock tem que ser liberado no finally
        assertThatThrownBy(() -> compressionGuard.runWithDecompressed(
                LocalDateTime.of(2026, 1, 1, 0, 0),
                LocalDateTime.of(2026, 1, 8, 0, 0),
                () -> { throw new IllegalStateException("boom"); }))
                .isInstanceOf(IllegalStateException.class)
                .hasMessage("boom");

        // 2a chamada (outra conexao do pool): se o lock tivesse vazado, isso lancaria
        // "outra operacao em andamento" - tem que funcionar normalmente
        Integer again = compressionGuard.runWithDecompressed(
                LocalDateTime.of(2026, 1, 1, 0, 0),
                LocalDateTime.of(2026, 1, 8, 0, 0),
                () -> 7);
        assertThat(again).isEqualTo(7);
    }
}
