package br.com.ledstar.ems.gapfiller.api;

import br.com.ledstar.ems.gapfiller.application.BackfillRequestRepository;
import br.com.ledstar.ems.gapfiller.domain.BackfillRequest;
import jakarta.validation.Valid;
import jakarta.validation.constraints.NotNull;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.time.LocalDateTime;
import java.util.List;
import java.util.Optional;
import java.util.UUID;

@RestController
@RequestMapping("/api/v1/backfill")
public class BackfillController {

    private final BackfillRequestRepository requestRepository;

    public BackfillController(BackfillRequestRepository requestRepository) {
        this.requestRepository = requestRepository;
    }

    @PostMapping
    public ResponseEntity<BackfillResponse> submit(@Valid @RequestBody BackfillCreateRequest body,
                                                   @RequestHeader(value = "X-Requested-By", required = false) String requestedBy) {
        BackfillRequest req = new BackfillRequest(
            UUID.randomUUID(),
            BackfillRequest.Mode.HISTORICAL,
            body.sensorIds(),
            body.windowStart(),
            body.windowEnd(),
            BackfillRequest.Status.QUEUED,
            LocalDateTime.now(),
            null, null, 0L, 0L, null,
            requestedBy != null ? requestedBy : "anonymous"
        );
        BackfillRequest saved = requestRepository.create(req);
        return ResponseEntity.accepted().body(BackfillResponse.from(saved));
    }

    @GetMapping("/{id}")
    public ResponseEntity<BackfillResponse> get(@PathVariable UUID id) {
        Optional<BackfillRequest> req = requestRepository.findById(id);
        return req.map(r -> ResponseEntity.ok(BackfillResponse.from(r)))
                  .orElse(ResponseEntity.notFound().build());
    }

    public record BackfillCreateRequest(
        List<Long> sensorIds,
        @NotNull LocalDateTime windowStart,
        @NotNull LocalDateTime windowEnd
    ) {}

    public record BackfillResponse(
        UUID id,
        BackfillRequest.Mode mode,
        BackfillRequest.Status status,
        List<Long> sensorIds,
        LocalDateTime windowStart,
        LocalDateTime windowEnd,
        Long inserted,
        Long skipped,
        String error
    ) {
        public static BackfillResponse from(BackfillRequest r) {
            return new BackfillResponse(
                r.id(), r.mode(), r.status(), r.sensorIds(),
                r.windowStart(), r.windowEnd(),
                r.readingsInserted(), r.readingsSkipped(),
                r.errorMessage()
            );
        }
    }
}
