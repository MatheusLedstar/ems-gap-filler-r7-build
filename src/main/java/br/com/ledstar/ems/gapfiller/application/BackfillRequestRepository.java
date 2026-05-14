package br.com.ledstar.ems.gapfiller.application;

import br.com.ledstar.ems.gapfiller.domain.BackfillRequest;

import java.util.Optional;
import java.util.UUID;

public interface BackfillRequestRepository {
    BackfillRequest create(BackfillRequest request);
    Optional<BackfillRequest> findById(UUID id);
    void updateStatus(UUID id, BackfillRequest.Status status, String errorMessage);
    void updateCounters(UUID id, long inserted, long skipped);
    Optional<BackfillRequest> findNextQueued();
}
