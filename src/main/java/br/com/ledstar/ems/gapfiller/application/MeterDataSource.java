package br.com.ledstar.ems.gapfiller.application;

import br.com.ledstar.ems.gapfiller.domain.SensorMeter;
import br.com.ledstar.ems.gapfiller.domain.SensorReading;

import java.time.LocalDateTime;
import java.util.List;

/**
 * Abstrai a fonte de dados de UM medidor fisico.
 * Implementacoes:
 *   - FtpEgx300DataSource (Schneider EGX300 - CSV via FTP)
 *   - HttpsCarloGavazziDataSource (Carlo Gavazzi 69kV - scrape HTTPS)
 */
public interface MeterDataSource {

    boolean supports(SensorMeter meter);

    /**
     * Busca leituras de um sensor numa janela.
     * Stream-based pra suportar janelas grandes sem estourar memoria.
     */
    List<SensorReading> fetchReadings(SensorMeter meter,
                                      LocalDateTime windowStart,
                                      LocalDateTime windowEnd);
}
