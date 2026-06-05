package com.petnose.api.service.nose;

import java.util.List;

public class NoseReferenceConsistencyChecker {

    public ReferenceConsistencyResult check(List<List<Double>> referenceVectors, double threshold) {
        if (referenceVectors == null || referenceVectors.size() < 2) {
            throw new IllegalArgumentException("At least two reference vectors are required.");
        }
        NoseVectorMath.validateVectors(referenceVectors);

        double sum = 0.0;
        double min = Double.POSITIVE_INFINITY;
        double max = Double.NEGATIVE_INFINITY;
        int pairCount = 0;

        for (int i = 0; i < referenceVectors.size(); i++) {
            for (int j = i + 1; j < referenceVectors.size(); j++) {
                double score = NoseVectorMath.dot(referenceVectors.get(i), referenceVectors.get(j));
                sum += score;
                min = Math.min(min, score);
                max = Math.max(max, score);
                pairCount++;
            }
        }

        if (pairCount == 0) {
            return new ReferenceConsistencyResult(false, 0.0, 0.0, 0.0, 0, threshold);
        }

        double average = sum / pairCount;
        return new ReferenceConsistencyResult(
                average >= threshold,
                average,
                min,
                max,
                pairCount,
                threshold
        );
    }

    public record ReferenceConsistencyResult(
            boolean accepted,
            double averagePairwiseScore,
            double minPairwiseScore,
            double maxPairwiseScore,
            int pairCount,
            double threshold
    ) {
    }
}
