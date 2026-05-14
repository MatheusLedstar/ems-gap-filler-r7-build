package br.com.ledstar.ems.gapfiller.infra.postgres;

import br.com.ledstar.ems.gapfiller.application.BackfillRequestRepository;
import br.com.ledstar.ems.gapfiller.domain.BackfillRequest;
import br.com.ledstar.ems.gapfiller.support.IntegrationTestBase;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.jdbc.core.JdbcTemplate;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;

class JdbcBackfillRequestRepositoryIT extends IntegrationTestBase {

    @Autowired
    BackfillRequestRepository repository;

    @Autowired
    JdbcTemplate jdbc;

    private static final LocalDateTime WIN_START = LocalDateTime.of(2026, 5, 1, 0, 0);
    private static final LocalDateTime WIN_END   = LocalDateTime.of(2026, 5, 8, 0, 0);

    @BeforeEach
    void cleanQueue() {
        // o contexto Spring (e o banco) e compartilhado pela suite - cada teste
        // comeca com a fila vazia pra findNextQueued() ser deterministico.
        jdbc.update("DELETE FROM ems.backfill_request");
    }

    private BackfillRequest newQueued(List<Long> sensorIds) {
        return new BackfillRequest(
                UUID.randomUUID(), BackfillRequest.Mode.HISTORICAL, sensorIds,
                WIN_START, WIN_END, BackfillRequest.Status.QUEUED,
                LocalDateTime.now().withNano(0),
                null, null, 0L, 0L, null, "tester");
    }

    @Test
    void cicloDeVidaCompletoDoBackfill() {
        BackfillRequest req = newQueued(List.of(30L, 21L));
        repository.create(req);

        // recuperar
        Optional<BackfillRequest> fetched = repository.findById(req.id());
        assertThat(fetched).isPresent();
        assertThat(fetched.get().status()).isEqualTo(BackfillRequest.Status.QUEUED);
        assertThat(fetched.get().sensorIds()).containsExactly(30L, 21L);
        assertThat(fetched.get().requestedBy()).isEqualTo("tester");
        assertThat(fetched.get().windowStart()).isEqualTo(WIN_START);
        assertThat(fetched.get().startedAt()).isNull();

        // proximo da fila
        assertThat(repository.findNextQueued()).map(BackfillRequest::id).contains(req.id());

        // -> RUNNING (started_at preenchido)
        repository.updateStatus(req.id(), BackfillRequest.Status.RUNNING, null);
        BackfillRequest running = repository.findById(req.id()).orElseThrow();
        assertThat(running.status()).isEqualTo(BackfillRequest.Status.RUNNING);
        assertThat(running.startedAt()).isNotNull();
        assertThat(running.finishedAt()).isNull();

        // contadores
        repository.updateCounters(req.id(), 42L, 3L);
        BackfillRequest counted = repository.findById(req.id()).orElseThrow();
        assertThat(counted.readingsInserted()).isEqualTo(42L);
        assertThat(counted.readingsSkipped()).isEqualTo(3L);

        // -> COMPLETED (finished_at preenchido, sai da fila)
        repository.updateStatus(req.id(), BackfillRequest.Status.COMPLETED, null);
        BackfillRequest done = repository.findById(req.id()).orElseThrow();
        assertThat(done.status()).isEqualTo(BackfillRequest.Status.COMPLETED);
        assertThat(done.finishedAt()).isNotNull();
    }

    @Test
    void findNextQueuedPegaOMaisAntigoEIgnoraNaoQueued() {
        // limpa a fila pra isolar o teste
        jdbc.update("DELETE FROM ems.backfill_request");

        BackfillRequest older = newQueued(null);
        repository.create(older);
        BackfillRequest newer = newQueued(List.of(99L));
        repository.create(newer);
        // marca uma terceira como RUNNING - nao deve aparecer
        BackfillRequest running = newQueued(List.of(1L));
        repository.create(running);
        repository.updateStatus(running.id(), BackfillRequest.Status.RUNNING, null);

        // older foi criada primeiro -> deve vir primeiro
        Optional<BackfillRequest> next = repository.findNextQueued();
        assertThat(next).map(BackfillRequest::id).contains(older.id());
        assertThat(next.orElseThrow().sensorIds()).isNull();   // sensorIds nulo = todos os ativos
    }

    @Test
    void updateStatusComErroGravaAMensagem() {
        jdbc.update("DELETE FROM ems.backfill_request");
        BackfillRequest req = newQueued(List.of(30L));
        repository.create(req);
        repository.updateStatus(req.id(), BackfillRequest.Status.FAILED, "FTP timeout no 10.193.217.11");
        BackfillRequest failed = repository.findById(req.id()).orElseThrow();
        assertThat(failed.status()).isEqualTo(BackfillRequest.Status.FAILED);
        assertThat(failed.errorMessage()).contains("FTP timeout");
        assertThat(failed.finishedAt()).isNotNull();
    }
}
