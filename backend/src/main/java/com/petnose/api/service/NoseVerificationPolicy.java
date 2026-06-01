package com.petnose.api.service;

import com.petnose.api.dto.registration.QdrantSearchResult;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.util.Comparator;
import java.util.List;
import java.util.Optional;

@Component
public class NoseVerificationPolicy {

    private final double duplicateThreshold;

    public NoseVerificationPolicy(@Value("${nose.duplicate-threshold:0.65}") double duplicateThreshold) {
        this.duplicateThreshold = duplicateThreshold;
    }

    public VerificationDecision evaluate(List<QdrantSearchResult> results) {
        Optional<QdrantSearchResult> top = results.stream()
                .max(Comparator.comparingDouble(QdrantSearchResult::score));

        double maxScore = top.map(QdrantSearchResult::score).orElse(0.0);
        boolean duplicate = top.isPresent() && maxScore >= duplicateThreshold;
        return new VerificationDecision(duplicate, maxScore, top.orElse(null), duplicateThreshold);
    }

    public double duplicateThreshold() {
        return duplicateThreshold;
    }

    public record VerificationDecision(
            boolean duplicate,
            double maxScore,
            QdrantSearchResult topMatch,
            double threshold
    ) {
    }
}
