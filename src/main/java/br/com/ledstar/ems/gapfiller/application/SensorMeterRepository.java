package br.com.ledstar.ems.gapfiller.application;

import br.com.ledstar.ems.gapfiller.domain.SensorMeter;

import java.util.List;
import java.util.Optional;

public interface SensorMeterRepository {
    List<SensorMeter> findActive();
    Optional<SensorMeter> findBySensorId(long sensorId);
}
