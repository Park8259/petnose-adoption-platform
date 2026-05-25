package com.petnose.api.dto.adoption;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.petnose.api.domain.enums.HandoverVerificationDecision;

public record HandoverVerificationResponse(
        @JsonProperty("post_id")
        Long postId,
        @JsonProperty("expected_dog_id")
        String expectedDogId,
        @JsonProperty("matched")
        boolean matched,
        @JsonProperty("decision")
        HandoverVerificationDecision decision,
        @JsonProperty("similarity_score")
        Double similarityScore,
        @JsonProperty("threshold")
        double threshold,
        @JsonProperty("ambiguous_threshold")
        double ambiguousThreshold,
        @JsonProperty("top_match_is_expected")
        boolean topMatchIsExpected,
        @JsonProperty("model")
        String model,
        @JsonProperty("dimension")
        int dimension,
        @JsonProperty("message")
        String message,
        @JsonProperty("score_breakdown")
        HandoverScoreBreakdownResponse scoreBreakdown
) {
}
