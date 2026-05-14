package br.com.ledstar.ems.gapfiller.domain;

import java.time.Duration;
import java.time.LocalDateTime;

/**
 * Janela detectada onde nao houve leitura de telemetria.
 * Timestamps em America/Manaus (mesmo TZ do banco).
 */
public record Gap(
    long sensorId,
    LocalDateTime startsAt,
    LocalDateTime endsAt,
    Duration expectedFrequency
) {
    public Duration duration() {
        return Duration.between(startsAt, endsAt);
    }

    public long expectedReadings() {
        return Math.max(0, duration().getSeconds() / expectedFrequency.getSeconds());
    }
}
