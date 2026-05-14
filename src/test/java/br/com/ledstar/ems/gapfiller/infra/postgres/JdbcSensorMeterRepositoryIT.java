package br.com.ledstar.ems.gapfiller.infra.postgres;

import br.com.ledstar.ems.gapfiller.application.SensorMeterRepository;
import br.com.ledstar.ems.gapfiller.domain.SensorMeter;
import br.com.ledstar.ems.gapfiller.support.IntegrationTestBase;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;

import java.time.Duration;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;

class JdbcSensorMeterRepositoryIT extends IntegrationTestBase {

    @Autowired
    SensorMeterRepository repository;

    @Test
    void findActiveRetornaOsOitoMedidoresFtpAtivos() {
        // V74 seeda 10 medidores; V77 desativa os 2 Carlo Gavazzi (12/13) ate ter endpoint HTTPS.
        assertThat(repository.findActive())
                .hasSize(8)
                .extracting(SensorMeter::senId)
                .containsExactlyInAnyOrder(30L, 21L, 10109L, 10154L, 10112L, 10110L, 10111L, 10105L)
                .doesNotContain(12L, 13L);
    }

    @Test
    void findBySensorIdMapeiaTodasAsColunasDoMedidorFtp() {
        Optional<SensorMeter> opt = repository.findBySensorId(30L);
        assertThat(opt).isPresent();
        SensorMeter m = opt.get();
        assertThat(m.meterIp()).isEqualTo("10.193.217.11");
        assertThat(m.protocol()).isEqualTo(SensorMeter.Protocol.FTP);
        assertThat(m.username()).isEqualTo("Administrator");
        assertThat(m.password()).isEqualTo("Gateway");          // pgp-key vazio -> texto puro
        assertThat(m.modbusSlaveId()).isEqualTo(1);
        assertThat(m.csvPath()).isEqualTo("/logging/data/MV-F3-M_1.csv");
        assertThat(m.expectedFrequency()).isEqualTo(Duration.ofMinutes(5));
        assertThat(m.active()).isTrue();
    }

    @Test
    void findBySensorIdDeMedidorInativoRetornaEmpty() {
        // sensor 12 (Carlo Gavazzi) foi desativado em V77 -> findActive/findBySensorId filtram fts_active
        assertThat(repository.findBySensorId(12L)).isEmpty();
        assertThat(repository.findBySensorId(13L)).isEmpty();
    }

    @Test
    void findBySensorIdInexistenteRetornaEmpty() {
        assertThat(repository.findBySensorId(999_999L)).isEmpty();
    }
}
