package br.com.ledstar.ems.gapfiller;

import br.com.ledstar.ems.gapfiller.support.IntegrationTestBase;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.JdbcTemplate;

import static org.assertj.core.api.Assertions.assertThat;

/**
 * Verifica que as migrations Flyway V70..V77 aplicaram no schema `ems` e que o
 * seed V74 populou ems.ftp_source com os 10 medidores da planilha.
 */
class MigrationAndSeedIT extends IntegrationTestBase {

    @Autowired
    JdbcTemplate jdbc;

    @Test
    void migrationsCriaramAsTabelasDoSchemaEms() {
        for (String table : new String[]{
                "ems.ftp_source", "ems.gap_log", "ems.backfill_request",
                "ems.shedlock", "ems.sensor_validation_rule", "ems.sensor_event"}) {
            Object regclass = jdbc.queryForObject("SELECT to_regclass(?)", Object.class, table);
            assertThat(regclass).as("tabela %s deve existir", table).isNotNull();
        }
    }

    @Test
    void flywayHistoryRegistrouTodasAsMigracoes() {
        var versions = jdbc.queryForList(
                "SELECT version FROM ems.ems_gap_filler_flyway_history WHERE success = true ORDER BY installed_rank",
                String.class);
        assertThat(versions).contains("70", "71", "72", "73", "74", "75", "76", "77");
    }

    @Test
    void v77DesativaCarloGavazzi() {
        Integer ativosHttps = jdbc.queryForObject(
                "SELECT count(*) FROM ems.ftp_source WHERE fts_protocol = 'HTTPS' AND fts_active", Integer.class);
        assertThat(ativosHttps).as("sensores Carlo Gavazzi 12/13 ficam inativos ate ter endpoint HTTPS").isZero();
    }

    @Test
    void seedV74PopulouDezMedidores() {
        Integer total = jdbc.queryForObject("SELECT count(*) FROM ems.ftp_source", Integer.class);
        assertThat(total).isEqualTo(10);

        Integer ftp = jdbc.queryForObject(
                "SELECT count(*) FROM ems.ftp_source WHERE fts_protocol = 'FTP'", Integer.class);
        Integer https = jdbc.queryForObject(
                "SELECT count(*) FROM ems.ftp_source WHERE fts_protocol = 'HTTPS'", Integer.class);
        assertThat(ftp).isEqualTo(8);
        assertThat(https).isEqualTo(2);
    }

    @Test
    void seedV74TemOMapeamentoCorretoDoMedidorBM() {
        var row = jdbc.queryForMap("""
                SELECT fts_meter_ip, fts_protocol, fts_modbus_slave_id, fts_csv_path, fts_username
                  FROM ems.ftp_source
                 WHERE fts_sensor = 30
                """);
        assertThat(row.get("fts_meter_ip")).isEqualTo("10.193.217.11");
        assertThat(row.get("fts_protocol")).isEqualTo("FTP");
        assertThat(row.get("fts_modbus_slave_id")).isEqualTo(1);
        assertThat(row.get("fts_csv_path")).isEqualTo("/logging/data/MV-F3-M_1.csv");
        assertThat(row.get("fts_username")).isEqualTo("Administrator");
    }

    @Test
    void seedRespeitaFkParaEmsSensor() {
        // todo fts_sensor deve existir em ems.sensor (no IT, ems.sensor existe e V76 cria a FK)
        Integer orphans = jdbc.queryForObject("""
                SELECT count(*) FROM ems.ftp_source f
                 WHERE NOT EXISTS (SELECT 1 FROM ems.sensor s WHERE s.sen_id = f.fts_sensor)
                """, Integer.class);
        assertThat(orphans).isZero();
    }

    @Test
    void v76CriaAFkQuandoEmsSensorExiste() {
        // o bootstrap do IT (timescale-it.sql) cria ems.sensor, entao V76 deve ter
        // adicionado a constraint. Em HOM vazio (sem ems.sensor) V76 vira no-op.
        Integer fk = jdbc.queryForObject("""
                SELECT count(*) FROM pg_constraint
                 WHERE conname = 'fk_ftp_source_sensor'
                   AND conrelid = 'ems.ftp_source'::regclass
                """, Integer.class);
        assertThat(fk).isEqualTo(1);
    }
}
