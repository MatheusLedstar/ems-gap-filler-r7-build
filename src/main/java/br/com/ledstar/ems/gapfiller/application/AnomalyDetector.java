package br.com.ledstar.ems.gapfiller.application;

import br.com.ledstar.ems.gapfiller.domain.Anomaly;
import br.com.ledstar.ems.gapfiller.domain.SensorReading;
import br.com.ledstar.ems.gapfiller.domain.ValueTypeRule;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

/**
 * Detecta anomalias em uma sequencia de leituras aplicando regras por valuetype.
 *
 * Regras implementadas:
 *   1) NON_MONOTONIC      - KWH/KVARH/KVAH precisam crescer (estritamente >=)
 *   2) OUT_OF_RANGE       - valor fora do range fisico do tipo
 *   3) OUT_OF_ORDER_TIME  - timestamp fora de ordem cronologica numa janela ordenada
 *   4) DUPLICATE_TIMESTAMP - duas leituras com mesmo (valuetype, creation)
 *
 * Usado em ambos lados (banco e CSV) antes de aplicar correcao.
 */
@Component
public class AnomalyDetector {

    /**
     * Roda regras numa lista de leituras. Retorna anomalias detectadas.
     * source = de onde vieram as leituras (BANCO ou CSV) para rastreabilidade.
     */
    public List<Anomaly> detect(List<SensorReading> readings, Anomaly.Source source) {
        List<Anomaly> anomalies = new ArrayList<>();

        Map<String, List<SensorReading>> byType = readings.stream()
            .collect(Collectors.groupingBy(SensorReading::valueType));

        byType.forEach((vt, list) -> {
            ValueTypeRule rule = ValueTypeRule.forValueType(vt);
            list.sort(Comparator.comparing(SensorReading::creation));

            checkRange(list, rule, source, anomalies);
            checkDuplicates(list, source, anomalies);
            if (rule.monotonicIncreasing()) {
                checkMonotonic(list, source, anomalies);
            }
            checkChronological(list, source, anomalies);
        });

        return anomalies;
    }

    private void checkRange(List<SensorReading> list, ValueTypeRule rule,
                            Anomaly.Source source, List<Anomaly> anomalies) {
        for (SensorReading r : list) {
            if (r.value() == null) continue;
            double v = r.value();
            if (v < rule.minValue() || v > rule.maxValue()) {
                anomalies.add(new Anomaly(
                    source, null, null,
                    r.sensorId(), r.creation(), r.valueType(), r.value(),
                    Anomaly.Reason.OUT_OF_RANGE,
                    String.format("value=%s fora de [%s, %s]", v, rule.minValue(), rule.maxValue())
                ));
            }
        }
    }

    private void checkDuplicates(List<SensorReading> list, Anomaly.Source source,
                                 List<Anomaly> anomalies) {
        for (int i = 1; i < list.size(); i++) {
            SensorReading prev = list.get(i - 1);
            SensorReading curr = list.get(i);
            if (curr.creation().equals(prev.creation())) {
                anomalies.add(new Anomaly(
                    source, null, null,
                    curr.sensorId(), curr.creation(), curr.valueType(), curr.value(),
                    Anomaly.Reason.DUPLICATE_TIMESTAMP,
                    String.format("duplicado com leitura anterior valor=%s", prev.value())
                ));
            }
        }
    }

    private void checkMonotonic(List<SensorReading> list, Anomaly.Source source,
                                List<Anomaly> anomalies) {
        for (int i = 1; i < list.size(); i++) {
            SensorReading prev = list.get(i - 1);
            SensorReading curr = list.get(i);
            if (prev.value() == null || curr.value() == null) continue;
            if (curr.value() < prev.value()) {
                anomalies.add(new Anomaly(
                    source, null, null,
                    curr.sensorId(), curr.creation(), curr.valueType(), curr.value(),
                    Anomaly.Reason.NON_MONOTONIC,
                    String.format("decresceu de %s (em %s) para %s (em %s)",
                        prev.value(), prev.creation(), curr.value(), curr.creation())
                ));
            }
        }
    }

    /**
     * Detecta timestamp fora de ordem dentro de uma janela ordenada.
     * Caso classico: linha 83 do CSV BM (07/05/2026 23:37) entre 05:20 e 05:30.
     * Como ja ordenamos por timestamp, esta regra atrapalha. Deteccao real eh
     * delta_to_neighbors - se uma leitura tem distancia > 100x da mediana, eh outlier.
     */
    private void checkChronological(List<SensorReading> list, Anomaly.Source source,
                                    List<Anomaly> anomalies) {
        if (list.size() < 4) return;
        List<Long> intervalsSec = new ArrayList<>();
        for (int i = 1; i < list.size(); i++) {
            intervalsSec.add(java.time.Duration.between(
                list.get(i - 1).creation(), list.get(i).creation()).getSeconds());
        }
        double median = median(new ArrayList<>(intervalsSec));
        if (median <= 0) return;

        for (int i = 1; i < list.size() - 1; i++) {
            long gapBefore = java.time.Duration.between(
                list.get(i - 1).creation(), list.get(i).creation()).getSeconds();
            long gapAfter = java.time.Duration.between(
                list.get(i).creation(), list.get(i + 1).creation()).getSeconds();

            if (gapBefore > median * 100 && gapAfter < median * 5) {
                SensorReading r = list.get(i);
                anomalies.add(new Anomaly(
                    source, null, null,
                    r.sensorId(), r.creation(), r.valueType(), r.value(),
                    Anomaly.Reason.OUT_OF_ORDER_TIME,
                    String.format("timestamp isolado (gap_before=%ds gap_after=%ds median=%.0fs)",
                        gapBefore, gapAfter, median)
                ));
            }
        }
    }

    private static double median(List<Long> values) {
        values.sort(Long::compareTo);
        int n = values.size();
        if (n == 0) return 0;
        if (n % 2 == 1) return values.get(n / 2);
        return (values.get(n / 2 - 1) + values.get(n / 2)) / 2.0;
    }
}
