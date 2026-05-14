package br.com.ledstar.ems.gapfiller.infra.postgres;

import br.com.ledstar.ems.gapfiller.domain.SensorMeter;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.jdbc.core.RowMapper;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

/**
 * Garante que o SQL gerado respeita {@code gapfiller.crypto.pgp-key}: com a chave vazia (caso atual,
 * senhas em texto puro), a query NAO pode mencionar {@code pgp_sym_decrypt} (senao estoura em bancos
 * sem a extensao pgcrypto — ex: o TimescaleDB do HOM).
 */
@SuppressWarnings({"unchecked", "rawtypes"})
class JdbcSensorMeterRepositoryTest {

    private final JdbcTemplate jdbc = mock(JdbcTemplate.class);

    @Test
    void semChaveCriptoOSqlNaoMencionaPgpSymDecrypt() {
        when(jdbc.query(anyString(), any(RowMapper.class))).thenReturn(List.<SensorMeter>of());

        new JdbcSensorMeterRepository(jdbc, "").findActive();

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(jdbc).query(sql.capture(), any(RowMapper.class));
        assertThat(sql.getValue())
                .doesNotContain("pgp_sym_decrypt")
                .contains("fts_password_enc AS password");
    }

    @Test
    void comChaveCriptoOSqlUsaPgpSymDecrypt() {
        when(jdbc.query(anyString(), any(RowMapper.class), any())).thenReturn(List.<SensorMeter>of());

        new JdbcSensorMeterRepository(jdbc, "uma-chave").findActive();

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(jdbc).query(sql.capture(), any(RowMapper.class), any());
        assertThat(sql.getValue()).contains("pgp_sym_decrypt(fts_password_enc::bytea, ?)");
    }
}
