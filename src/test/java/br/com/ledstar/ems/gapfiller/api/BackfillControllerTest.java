package br.com.ledstar.ems.gapfiller.api;

import br.com.ledstar.ems.gapfiller.application.BackfillRequestRepository;
import br.com.ledstar.ems.gapfiller.domain.BackfillRequest;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.SerializationFeature;
import com.fasterxml.jackson.datatype.jsr310.JavaTimeModule;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.http.converter.json.MappingJackson2HttpMessageConverter;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.setup.MockMvcBuilders;
import org.springframework.validation.beanvalidation.LocalValidatorFactoryBean;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.argThat;
import static org.mockito.Mockito.mock;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

class BackfillControllerTest {

    private final BackfillRequestRepository repository = mock(BackfillRequestRepository.class);
    private MockMvc mvc;

    @BeforeEach
    void setup() {
        ObjectMapper om = new ObjectMapper()
                .registerModule(new JavaTimeModule())
                .disable(SerializationFeature.WRITE_DATES_AS_TIMESTAMPS);
        LocalValidatorFactoryBean validator = new LocalValidatorFactoryBean();
        validator.afterPropertiesSet();
        mvc = MockMvcBuilders.standaloneSetup(new BackfillController(repository))
                .setMessageConverters(new MappingJackson2HttpMessageConverter(om))
                .setValidator(validator)
                .build();
    }

    @Test
    void submitRetorna202ERequestQueued() throws Exception {
        when(repository.create(any())).thenAnswer(inv -> inv.getArgument(0));

        String body = """
                {"sensorIds":[30,21],"windowStart":"2026-05-01T00:00:00","windowEnd":"2026-05-08T00:00:00"}
                """;

        mvc.perform(post("/api/v1/backfill")
                        .contentType(MediaType.APPLICATION_JSON)
                        .header("X-Requested-By", "tester")
                        .content(body))
                .andExpect(status().isAccepted())
                .andExpect(jsonPath("$.status").value("QUEUED"))
                .andExpect(jsonPath("$.mode").value("HISTORICAL"))
                .andExpect(jsonPath("$.sensorIds.length()").value(2))
                .andExpect(jsonPath("$.sensorIds[0]").value(30));

        verify(repository).create(argThat(r ->
                r.status() == BackfillRequest.Status.QUEUED
                        && r.mode() == BackfillRequest.Mode.HISTORICAL
                        && "tester".equals(r.requestedBy())
                        && r.sensorIds().equals(List.of(30L, 21L))));
    }

    @Test
    void submitSemWindowStartRetorna400() throws Exception {
        String body = """
                {"windowEnd":"2026-05-08T00:00:00"}
                """;
        mvc.perform(post("/api/v1/backfill")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(body))
                .andExpect(status().isBadRequest());
    }

    @Test
    void getRetorna200ComOStatusAtual() throws Exception {
        UUID id = UUID.randomUUID();
        BackfillRequest req = new BackfillRequest(
                id, BackfillRequest.Mode.HISTORICAL, List.of(30L),
                LocalDateTime.of(2026, 5, 1, 0, 0), LocalDateTime.of(2026, 5, 8, 0, 0),
                BackfillRequest.Status.RUNNING, LocalDateTime.now(), LocalDateTime.now(),
                null, 5L, 1L, null, "tester");
        when(repository.findById(id)).thenReturn(Optional.of(req));

        mvc.perform(get("/api/v1/backfill/{id}", id))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.id").value(id.toString()))
                .andExpect(jsonPath("$.status").value("RUNNING"))
                .andExpect(jsonPath("$.inserted").value(5));
    }

    @Test
    void getRetorna404QuandoNaoExiste() throws Exception {
        UUID id = UUID.randomUUID();
        when(repository.findById(id)).thenReturn(Optional.empty());
        mvc.perform(get("/api/v1/backfill/{id}", id))
                .andExpect(status().isNotFound());
    }
}
