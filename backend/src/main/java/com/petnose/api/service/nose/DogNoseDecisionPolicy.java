package com.petnose.api.service.nose;

import com.petnose.api.domain.enums.VerificationResult;

public class DogNoseDecisionPolicy {

    public DogNoseDecision evaluate(
            DogNoseCandidateAggregator.DogNoseCandidateScore topCandidate,
            double duplicateThreshold,
            double reviewLowerBound
    ) {
        validateThresholds(duplicateThreshold, reviewLowerBound);

        if (topCandidate == null) {
            return new DogNoseDecision(
                    VerificationResult.PASSED,
                    true,
                    0.0,
                    null,
                    duplicateThreshold,
                    reviewLowerBound
            );
        }

        double finalScore = topCandidate.finalScore();
        if (finalScore >= duplicateThreshold) {
            return new DogNoseDecision(
                    VerificationResult.DUPLICATE_SUSPECTED,
                    false,
                    finalScore,
                    topCandidate,
                    duplicateThreshold,
                    reviewLowerBound
            );
        }

        if (finalScore >= reviewLowerBound) {
            return new DogNoseDecision(
                    VerificationResult.REVIEW_REQUIRED,
                    false,
                    finalScore,
                    topCandidate,
                    duplicateThreshold,
                    reviewLowerBound
            );
        }

        return new DogNoseDecision(
                VerificationResult.PASSED,
                true,
                finalScore,
                topCandidate,
                duplicateThreshold,
                reviewLowerBound
        );
    }

    private static void validateThresholds(double duplicateThreshold, double reviewLowerBound) {
        if (!Double.isFinite(duplicateThreshold) || !Double.isFinite(reviewLowerBound)) {
            throw new IllegalArgumentException("Thresholds must be finite.");
        }
        if (duplicateThreshold <= reviewLowerBound) {
            throw new IllegalArgumentException("Duplicate threshold must be greater than review lower bound.");
        }
        if (reviewLowerBound < 0.0 || duplicateThreshold > 1.0) {
            throw new IllegalArgumentException("Thresholds must be within the 0..1 range.");
        }
    }

    public record DogNoseDecision(
            VerificationResult result,
            boolean registrationAllowed,
            double finalScore,
            DogNoseCandidateAggregator.DogNoseCandidateScore topCandidate,
            double duplicateThreshold,
            double reviewLowerBound
    ) {
    }
}
