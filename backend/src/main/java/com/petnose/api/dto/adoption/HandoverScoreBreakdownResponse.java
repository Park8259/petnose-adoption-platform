package com.petnose.api.dto.adoption;

import com.fasterxml.jackson.annotation.JsonProperty;

public record HandoverScoreBreakdownResponse(
        @JsonProperty("final_score")
        Double finalScore,
        @JsonProperty("max_reference_score")
        Double maxReferenceScore,
        @JsonProperty("top2_average_score")
        Double top2AverageScore,
        @JsonProperty("centroid_score")
        Double centroidScore,
        @JsonProperty("hit_count")
        Integer hitCount
) {
}
