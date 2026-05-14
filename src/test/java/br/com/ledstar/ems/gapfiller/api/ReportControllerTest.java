package br.com.ledstar.ems.gapfiller.api;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.springframework.core.env.Environment;
import org.springframework.http.converter.json.MappingJackson2HttpMessageConverter;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;

import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.contains;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.atLeastOnce;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class ReportControllerTest {

    private final JdbcTemplate jdbc = mock(JdbcTemplate.class);
    private final Environment env = mock(Environment.class);
    private MockMvc mvc;

    @BeforeEach
    void setup() {
        ObjectMapper om = new ObjectMapper()
                .registerModule(new JavaTimeModule())
                .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
        mvc = MockMvcBuilders.standaloneSetup(new ReportController(jdbc, env))
                .setMessageConverters(new MappingJackson2HttpMessageConverter(om))
                .build();
        when(env.getActiveProfiles()).thenReturn(new String[]{"hom"});
        when(jdbc.queryForList(anyString())).thenReturn(List.of(Map.of("k", "v")));
        when(jdbc.queryForObject(anyString(), eq(Long.class))).thenReturn(7L);
        when(jdbc.queryForObject(anyString(), eq(String.class))).thenReturn("mqtt.sensordatarecord");
    }

    @Test
    void reportRetorna200ComAsSecoesEsperadas() throws Exception {
        mvc.perform(get("/api/v1/report"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.generatedAt").exists())
                .andExpect(jsonPath("$.profiles[0]").value("hom"))
                .andExpect(jsonPath("$.flyway").exists())
                .andExpect(jsonPath("$.ftpSource.count").value(7))
                .andExpect(jsonPath("$.backfillRequests").exists())
                .andExpect(jsonPath("$.gapLog.count").value(7))
                .andExpect(jsonPath("$.telemetry.mqttSensorDataRecord.exists").value(true))
                .andExpect(jsonPath("$.telemetry.emsSensor.exists").value(true))
                .andExpect(jsonPath("$.telemetry.ftpSourceFk.fk_ftp_source_sensor_present").value(true));
    }

    @Test
    void reportNaoQuebraQuandoUmaTabelaNaoExiste() throws Exception {
        // ex: HOM "vazio" sem o schema mqtt -> a query estoura; o report deve devolver
        // {"error": ...} naquela seção e seguir 200, nunca 500.
        when(jdbc.queryForObject(eq("SELECT to_regclass('mqtt.sensordatarecord')::text"), eq(String.class)))
                .thenReturn(null);
        when(jdbc.queryForList(contains("ems_gap_filler_flyway_history")))
                .thenThrow(new RuntimeException("relation \"ems.ems_gap_filler_flyway_history\" does not exist"));

        mvc.perform(get("/api/v1/report"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.flyway.error").exists())
                .andExpect(jsonPath("$.telemetry.mqttSensorDataRecord.exists").value(false));
    }

    @Test
    void reportRespeitaOLimiteMaximo() throws Exception {
        mvc.perform(get("/api/v1/report").param("limit", "999999"))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.limit").value(5000));
    }

    @Test
    void reportNaoGeraLimitColadoNoNumero() throws Exception {
        // regressao: text block Java remove o espaco no fim da linha -> "LIMIT """ + lim => "LIMIT2000".
        mvc.perform(get("/api/v1/report").param("limit", "123")).andExpect(status().isOk());

        ArgumentCaptor<String> sql = ArgumentCaptor.forClass(String.class);
        verify(jdbc, atLeastOnce()).queryForList(sql.capture());
        assertThat(sql.getAllValues())
                .as("nenhuma query pode ter LIMIT colado num digito")
                .noneMatch(s -> s.matches("(?si).*LIMIT\\d.*"));
        assertThat(sql.getAllValues())
                .as("o LIMIT clampado deve aparecer com espaco")
                .anyMatch(s -> s.contains("LIMIT 123"));
    }
}
