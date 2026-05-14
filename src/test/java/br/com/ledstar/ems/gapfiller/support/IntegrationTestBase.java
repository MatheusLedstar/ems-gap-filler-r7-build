package br.com.ledstar.ems.gapfiller.support;

import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.utility.DockerImageName;

/**
 * Base dos testes de integracao.
 *
 * Sobe UM container TimescaleDB (mesma versao de producao: PG 17 + TS 2.21)
 * compartilhado por toda a suite (singleton pattern - start manual no static
 * block, Ryuk limpa no fim). O script db/timescale-it.sql cria o minimo do
 * schema mqtt/ems que o Flyway precisa pra rodar V70..V75 por cima.
 *
 * Os testes concretos terminam em *IT.java -> rodam no failsafe (`mvn verify`),
 * nunca no surefire (`mvn test`).
 */
@SpringBootTest(webEnvironment = SpringBootTest.WebEnvironment.NONE)
@ActiveProfiles("test")
public abstract class IntegrationTestBase {

    protected static final PostgreSQLContainer<?> POSTGRES;

    static {
        POSTGRES = new PostgreSQLContainer<>(
                DockerImageName.parse("timescale/timescaledb:2.21.0-pg17")
                        .asCompatibleSubstituteFor("postgres"))
                .withDatabaseName("ems_test")
                .withUsername("ems_user")
                .withPassword("test_pass")
                .withInitScript("db/timescale-it.sql");
        POSTGRES.start();
    }

    @DynamicPropertySource
    static void datasourceProps(DynamicPropertyRegistry registry) {
        registry.add("spring.datasource.url", POSTGRES::getJdbcUrl);
        registry.add("spring.datasource.username", POSTGRES::getUsername);
        registry.add("spring.datasource.password", POSTGRES::getPassword);
    }
}
