package br.com.ledstar.ems.gapfiller.application;

import br.com.ledstar.ems.gapfiller.domain.SensorReading;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;

public interface TelemetryQueryRepository {

    /**
     * Busca timestamps DISTINCT de leituras ATIVAS de um sensor numa janela.
     * Usa idx_sensordatarecord_sensor_type_creation pra performance.
     * Janela tipica: ate 7 dias.
     */
    List<LocalDateTime> findReadingTimestamps(long sensorId,
                                              LocalDateTime windowStart,
                                              LocalDateTime windowEnd);

    /**
     * Busca leituras ativas (sdr_active=true) com valor e valuetype, na janela.
     * Usado pelo AnomalyDetector pra rodar regras nas leituras existentes.
     */
    List<SensorReading> findActiveReadings(long sensorId,
                                           LocalDateTime windowStart,
                                           LocalDateTime windowEnd);

    /**
     * Ultimo timestamp registrado por sensor (de mqtt.last_sensor_value).
     * Retorna empty se sensor nunca teve leitura ou esta inativo.
     */
    Optional<LocalDateTime> findLastReadingFor(long sensorId);

    /**
     * Verifica se uma leitura especifica ja existe (dedup pre-INSERT).
     * Usa idx_sensordatarecord_sensor_type_creation - O(log n).
     */
    boolean existsReading(SensorReading.DedupKey key);
}
