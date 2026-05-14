-- Tabela de locks distribuidos do ShedLock.
CREATE TABLE IF NOT EXISTS ems.shedlock (
    name        varchar(64)  PRIMARY KEY,
    lock_until  timestamp    NOT NULL,
    locked_at   timestamp    NOT NULL,
    locked_by   varchar(255) NOT NULL
);

COMMENT ON TABLE ems.shedlock IS 'Locks distribuidos do ShedLock (recent-sweep, historical-queue).';
