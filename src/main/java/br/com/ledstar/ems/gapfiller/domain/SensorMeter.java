package br.com.ledstar.ems.gapfiller.domain;

import java.time.Duration;

/**
 * Catalogo de medidor fisico (FTP source) com mapeamento sensor.sen_id <-> CSV no FTP.
 * Persistido em ems.ftp_source.
 */
public record SensorMeter(
    long ftsId,
    long senId,                  // FK ems.sensor.sen_id
    String meterIp,              // ex: 10.193.217.11
    Protocol protocol,           // FTP ou HTTPS
    String username,
    String password,
    Integer modbusSlaveId,       // opcional, so EGX300
    String csvPath,              // ex: /logging/data/MV-F3-M_1.csv
    Duration expectedFrequency,  // intervalo entre leituras (sen_time)
    boolean active
) {
    public enum Protocol { FTP, HTTPS }
}
