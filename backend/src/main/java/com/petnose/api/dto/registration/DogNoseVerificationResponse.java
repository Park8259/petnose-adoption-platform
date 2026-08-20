package com.petnose.api.dto.registration;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.List;

public record DogNoseVerificationResponse(
        @JsonProperty("dog_id")
        String dogId,
        @JsonProperty("profile_match_allowed")
        boolean profileMatchAllowed,
        @JsonProperty("profile_match_status")
        String profileMatchStatus,
        @JsonProperty("profile_match_threshold")
        double profileMatchThreshold,
        @JsonProperty("profile_match_min_pass_count")
        int profileMatchMinPassCount,
        @JsonProperty("profile_match_pass_count")
        int profileMatchPassCount,
        @JsonProperty("profile_match_median_score")
        Double profileMatchMedianScore,
        @JsonProperty("profile_match_aggregate")
        String profileMatchAggregate,
        @JsonProperty("profile_match_scores")
        List<ProfileMatchScoreResponse> profileMatchScores,
        @JsonProperty("threshold_calibrated")
        boolean thresholdCalibrated,
        @JsonProperty("registration_allowed")
        boolean registrationAllowed,
        @JsonProperty("status")
        String status,
        @JsonProperty("verification_status")
        String verificationStatus,
        @JsonProperty("embedding_status")
        String embeddingStatus,
        @JsonProperty("qdrant_point_id")
        String qdrantPointId,
        @JsonProperty("model")
        String model,
        @JsonProperty("dimension")
        Integer dimension,
        @JsonProperty("max_similarity_score")
        Double maxSimilarityScore,
        @JsonProperty("top_match")
        DuplicateCandidateResponse topMatch,
        @JsonProperty("embedding_mode")
        String embeddingMode,
        @JsonProperty("reference_count")
        Integer referenceCount,
        @JsonProperty("score_breakdown")
        ScoreBreakdownResponse scoreBreakdown,
        @JsonProperty("nose_image_urls")
        List<String> noseImageUrls,
        @JsonProperty("failure_reason")
        String failureReason,
        @JsonProperty("message")
        String message
) {
}
