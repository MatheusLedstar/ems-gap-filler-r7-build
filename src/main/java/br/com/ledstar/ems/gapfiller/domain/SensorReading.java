package br.com.ledstar.ems.gapfiller.domain;

import java.time.LocalDateTime;

/**
 * Leitura unitaria de telemetria. Mapeia 1:1 com mqtt.sensordatarecord.
 * Timestamps em America/Manaus (sem TZ - timestamp without time zone na hypertable).
 */
public record SensorReading(
    long sensorId,
    LocalDateTime creation,
    String valueType,             // ex: "KW_SYS", "A_L1", "V_L1_N"
    Double value,
    String unitMeasurement,       // ex: "kW", "A", "V"
    String json                    // metadados do gateway (TerminalPn, _groupName, etc)
) {
    /**
     * Chave logica de dedup. Coincide com idx_sensordatarecord_sensor_type_creation.
     */
    public DedupKey dedupKey() {
        return new DedupKey(sensorId, creation, valueType);
    }

    public record DedupKey(long sensorId, LocalDateTime creation, String valueType) {}
}
