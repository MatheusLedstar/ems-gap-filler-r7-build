-- FK ems.ftp_source.fts_sensor -> ems.sensor(sen_id), adicionada CONDICIONALMENTE.
--
-- Por que aqui e nao inline no V70:
--   - O HOM (150.150.251.112, profile hom) sobe um TimescaleDB "vazio" que ainda
--     NAO tem o schema do app EMS — logo, ems.sensor nao existe. Um REFERENCES inline
--     no V70 faria o CREATE TABLE ems.ftp_source falhar e o worker nao subiria.
--   - O PRD ja tem ems.sensor populado; nele a FK e criada normalmente.
--
-- Estrategia: so tenta o ALTER se ems.sensor existir; se o ALTER falhar (ex: ainda
-- ha fts_sensor que nao casa com nenhum sen_id), apenas registra um NOTICE — a
-- migration NAO falha. O worker funciona sem a FK (e so integridade referencial).
-- Idempotente: pula se a constraint ja existe.
DO $$
BEGIN
    IF to_regclass('ems.sensor') IS NULL THEN
        RAISE NOTICE 'V76: ems.sensor nao existe — FK ftp_source->sensor NAO criada (provavelmente ambiente HOM vazio).';
        RETURN;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_constraint
         WHERE conname = 'fk_ftp_source_sensor'
           AND conrelid = 'ems.ftp_source'::regclass
    ) THEN
        RAISE NOTICE 'V76: constraint fk_ftp_source_sensor ja existe — nada a fazer.';
        RETURN;
    END IF;

    BEGIN
        ALTER TABLE ems.ftp_source
            ADD CONSTRAINT fk_ftp_source_sensor
            FOREIGN KEY (fts_sensor) REFERENCES ems.sensor(sen_id) ON DELETE RESTRICT;
        RAISE NOTICE 'V76: FK fk_ftp_source_sensor criada.';
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'V76: falha ao criar FK fk_ftp_source_sensor (%) — seguindo sem ela.', SQLERRM;
    END;
END
$$;
