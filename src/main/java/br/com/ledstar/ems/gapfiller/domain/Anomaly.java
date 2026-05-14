package br.com.ledstar.ems.gapfiller.domain;

import java.time.LocalDateTime;

/**
 * Leitura suspeita detectada por uma ou mais regras de validacao.
 * Inclui referencia ao registro no banco (sdr_id) ou indicacao de que veio do CSV (linha).
 */
public record Anomaly(
    Source source,                     // BANCO ou CSV
    Long sdrId,                         // null se source=CSV
    Integer csvLineNumber,              // null se source=BANCO
    long sensorId,
    LocalDateTime creation,
    String valueType,
    Double value,
    Reason reason,
    String detail
) {
    public enum Source { BANCO, CSV }

    public enum Reason {
        NON_MONOTONIC,         // KWH/KVARH decresceu vs leitura anterior
        OUT_OF_RANGE,          // valor fora dos limites fisicos do tipo
        OUT_OF_ORDER_TIME,     // timestamp fora de ordem cronologica (ex: linha 83 do CSV)
        FREQUENCY_OUTLIER,     // intervalo entre leituras muito alem do esperado
        DUPLICATE_TIMESTAMP    // duas leituras no mesmo (sensor, valuetype, creation) - dedup
    }
}
