package br.com.ledstar.ems.gapfiller.application;

import br.com.ledstar.ems.gapfiller.domain.SensorReading;

import java.time.LocalDateTime;
import java.util.List;

public interface TelemetryWriteRepository {

    /**
     * INSERT em batch idempotente.
     * Retorna quantidade efetivamente inserida (depois do dedup).
     */
    InsertResult insertBatch(List<SensorReading> readings);

    /**
     * Soft-delete por chave de dedup. Marca sdr_active=false em TODAS as leituras
     * que batem (sensor, valuetype, creation). Append-only - nao DELETE.
     * Eh assim que o CAG (que filtra sdr_active=true) ignora a leitura errada
     * apos refresh_continuous_aggregate.
     */
    int softDelete(SensorReading.DedupKey key);

    /**
     * Soft-delete em lote (mais eficiente que softDelete por linha).
     */
    int softDeleteBatch(List<SensorReading.DedupKey> keys);

    /**
     * Substitui uma leitura ruim pela leitura boa do gateway de forma ATOMICA:
     * soft-delete da {@code badKey} + INSERT de {@code replacement} na mesma transacao.
     * Sem isso, um soft-delete que commita seguido de um INSERT que falha deixaria um
     * gap onde antes havia (ainda que errado) um valor.
     */
    void replaceReading(SensorReading.DedupKey badKey, SensorReading replacement);

    /**
     * Descomprime chunks que cobrem uma janela de tempo.
     * Necessario antes de INSERT em janelas > 7 dias (compression policy).
     * Retorna lista de chunks descomprimidos pra recompressao posterior.
     */
    List<String> decompressChunksFor(LocalDateTime windowStart, LocalDateTime windowEnd);

    /**
     * Recomprime chunks listados (idempotente - se ja comprimido, ignora).
     */
    void recompressChunks(List<String> chunkNames);

    /**
     * Refresh dos CAGs hierarquicos para uma janela.
     * Necessario quando backfill > 3 dias (start_offset do CAG hourly).
     * Cascata: hourly -> daily -> monthly.
     */
    void refreshContinuousAggregates(LocalDateTime windowStart, LocalDateTime windowEnd);

    record InsertResult(long inserted, long skipped) {}
}
