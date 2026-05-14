package br.com.ledstar.ems.gapfiller.application;

import br.com.ledstar.ems.gapfiller.domain.Anomaly;
import br.com.ledstar.ems.gapfiller.domain.SensorReading;
import org.junit.jupiter.api.Test;

import java.time.LocalDateTime;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;

class AnomalyDetectorTest {

    private final AnomalyDetector detector = new AnomalyDetector();

    /**
     * Caso real do print do Cesar - linha 83 do CSV BM:
     *   05:20 -> 7.728.861.696
     *   23:37 -> 7.728.922.624  (mesmo valor que aparece duplicado no banco entre 18-21h)
     *   05:30 -> 7.728.983.552
     *
     * Sequencia ordenada por timestamp deveria flagear:
     *   - 05:30 NON_MONOTONIC (decresceu de 23:37 -> 05:30)
     *   - 23:37 OUT_OF_ORDER_TIME (gap antes muito maior que mediano)
     */
    @Test
    void deveDetectarAnomaliaDaLinha83() {
        long sensorId = 30L;
        List<SensorReading> readings = List.of(
            kwh(sensorId, "07/05/2026 04:30", 7_728_264_704.0),
            kwh(sensorId, "07/05/2026 04:35", 7_728_324_096.0),
            kwh(sensorId, "07/05/2026 04:40", 7_728_383_488.0),
            kwh(sensorId, "07/05/2026 04:45", 7_728_443_392.0),
            kwh(sensorId, "07/05/2026 04:50", 7_728_503_296.0),
            kwh(sensorId, "07/05/2026 04:55", 7_728_562_688.0),
            kwh(sensorId, "07/05/2026 05:00", 7_728_622_080.0),
            kwh(sensorId, "07/05/2026 05:05", 7_728_681_984.0),
            kwh(sensorId, "07/05/2026 05:10", 7_728_741_376.0),
            kwh(sensorId, "07/05/2026 05:15", 7_728_801_280.0),
            kwh(sensorId, "07/05/2026 05:20", 7_728_861_696.0),
            kwh(sensorId, "07/05/2026 23:37", 7_728_922_624.0),
            kwh(sensorId, "07/05/2026 05:30", 7_728_983_552.0)
        );

        List<Anomaly> anomalies = detector.detect(readings, Anomaly.Source.CSV);

        assertThat(anomalies).isNotEmpty();
        assertThat(anomalies)
            .extracting(Anomaly::reason)
            .contains(Anomaly.Reason.NON_MONOTONIC);
    }

    @Test
    void deveDetectarValoresForaDoRangeFisico() {
        long sensorId = 10L;
        List<SensorReading> readings = List.of(
            new SensorReading(sensorId, ts("08/05/2026 10:00"), "V_L1_N", 220.0, "V", null),
            new SensorReading(sensorId, ts("08/05/2026 10:05"), "V_L1_N", 999_999.0, "V", null),
            new SensorReading(sensorId, ts("08/05/2026 10:10"), "V_L1_N", 220.0, "V", null)
        );
        List<Anomaly> anomalies = detector.detect(readings, Anomaly.Source.BANCO);
        assertThat(anomalies)
            .extracting(Anomaly::reason)
            .contains(Anomaly.Reason.OUT_OF_RANGE);
    }

    @Test
    void deveDetectarFrequenciaAbaixoDoRange() {
        long sensorId = 10L;
        List<SensorReading> readings = List.of(
            new SensorReading(sensorId, ts("08/05/2026 10:00"), "HZ", 60.0, "Hz", null),
            new SensorReading(sensorId, ts("08/05/2026 10:05"), "HZ", 30.0, "Hz", null),
            new SensorReading(sensorId, ts("08/05/2026 10:10"), "HZ", 60.0, "Hz", null)
        );
        List<Anomaly> anomalies = detector.detect(readings, Anomaly.Source.BANCO);
        assertThat(anomalies).hasSizeGreaterThanOrEqualTo(1);
        assertThat(anomalies)
            .anyMatch(a -> a.reason() == Anomaly.Reason.OUT_OF_RANGE && a.value() == 30.0);
    }

    @Test
    void deveDetectarTimestampDuplicado() {
        long sensorId = 10L;
        List<SensorReading> readings = List.of(
            new SensorReading(sensorId, ts("08/05/2026 10:00"), "KW_SYS", 100.0, "kW", null),
            new SensorReading(sensorId, ts("08/05/2026 10:00"), "KW_SYS", 105.0, "kW", null)
        );
        List<Anomaly> anomalies = detector.detect(readings, Anomaly.Source.BANCO);
        assertThat(anomalies)
            .extracting(Anomaly::reason)
            .contains(Anomaly.Reason.DUPLICATE_TIMESTAMP);
    }

    @Test
    void naoDeveFlagSequenciaValidaDeKwh() {
        long sensorId = 30L;
        List<SensorReading> readings = List.of(
            kwh(sensorId, "08/05/2026 04:00", 1000.0),
            kwh(sensorId, "08/05/2026 04:05", 1010.0),
            kwh(sensorId, "08/05/2026 04:10", 1020.0)
        );
        List<Anomaly> anomalies = detector.detect(readings, Anomaly.Source.BANCO);
        assertThat(anomalies).isEmpty();
    }

    private static SensorReading kwh(long sensorId, String timeStr, double value) {
        return new SensorReading(sensorId, ts(timeStr), "KWH", value, "kWh", null);
    }

    private static LocalDateTime ts(String s) {
        return LocalDateTime.parse(s,
            java.time.format.DateTimeFormatter.ofPattern("dd/MM/yyyy HH:mm"));
    }
}
