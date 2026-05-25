package com.petnose.api.dto.registration;

import com.fasterxml.jackson.annotation.JsonProperty;

public record ScoreBreakdownResponse(
        @JsonProperty("final_score")
        Double finalScore,
        @JsonProperty("max_reference_score")
        Double maxReferenceScore,
        @JsonProperty("top2_average_score")
        Double top2AverageScore,
        @JsonProperty("centroid_score")
        Double centroidScore,
        @JsonProperty("hit_count")
        Integer hitCount,
        @JsonProperty("reference_consistency_score")
        Double referenceConsistencyScore
) {
}
