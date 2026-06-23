package com.petnose.api.dto.registration;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.List;

public record DogRegisterResponse(
        @JsonProperty("dog_id")
        String dogId,
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
        @JsonProperty("profile_nose_match_score")
        Double profileNoseMatchScore,
        @JsonProperty("nose_image_url")
        String noseImageUrl,
        @JsonProperty("profile_image_url")
        String profileImageUrl,
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
        @JsonProperty("message")
        String message
) {
}
