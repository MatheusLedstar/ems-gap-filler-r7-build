package br.com.ledstar.ems.gapfiller.config;

import net.javacrumbs.shedlock.core.LockProvider;
import net.javacrumbs.shedlock.provider.jdbctemplate.JdbcTemplateLockProvider;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jdbc.core.JdbcTemplate;

/**
 * Wire do ShedLock pra ems.shedlock. Sem este bean, @SchedulerLock nao funciona
 * e o EnableSchedulerLock nao tem como obter lock - falha silenciosa em multi-instancia.
 *
 * usingDbTime() pega o relogio do Postgres (NOW()) ao inves do servidor da app -
 * critico em ambientes onde os relogios da JVM podem divergir.
 */
@Configuration
public class ShedLockConfig {

    @Bean
    public LockProvider lockProvider(JdbcTemplate jdbcTemplate) {
        return new JdbcTemplateLockProvider(
            JdbcTemplateLockProvider.Configuration.builder()
                .withJdbcTemplate(jdbcTemplate)
                .withTableName("ems.shedlock")
                .usingDbTime()
                .build()
        );
    }
}
