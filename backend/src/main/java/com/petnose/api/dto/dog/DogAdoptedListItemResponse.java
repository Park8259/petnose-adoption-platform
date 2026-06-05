package com.petnose.api.dto.dog;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;

public record DogAdoptedListItemResponse(
        @JsonProperty("dog_id")
        String dogId,
        @JsonProperty("post_id")
        Long postId,
        @JsonProperty("post_title")
        String postTitle,
        @JsonProperty("dog_name")
        String dogName,
        @JsonProperty("breed")
        String breed,
        @JsonProperty("gender")
        String gender,
        @JsonProperty("birth_date")
        LocalDate birthDate,
        @JsonProperty("description")
        String description,
        @JsonProperty("status")
        String status,
        @JsonProperty("profile_image_url")
        String profileImageUrl,
        @JsonProperty("verification_status")
        String verificationStatus,
        @JsonProperty("adopted_at")
        LocalDateTime adoptedAt,
        @JsonProperty("created_at")
        Instant createdAt,
        @JsonProperty("updated_at")
        Instant updatedAt
) {
}
