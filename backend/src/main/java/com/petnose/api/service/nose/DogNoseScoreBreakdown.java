package com.petnose.api.service.nose;

public record DogNoseScoreBreakdown(
        double finalScore,
        double maxReferenceScore,
        double top2AverageScore,
        Double centroidScore,
        int hitCount,
        Double referenceConsistencyScore,
        String policy
) {

    public static final String MAX_REFERENCE_POLICY = "max_reference_v1";
}
