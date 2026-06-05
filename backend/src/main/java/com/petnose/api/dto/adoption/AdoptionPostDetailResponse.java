package com.petnose.api.dto.adoption;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.time.LocalDate;
import java.time.LocalDateTime;

public record AdoptionPostDetailResponse(
        @JsonProperty("post_id")
        Long postId,
        @JsonProperty("dog_id")
        String dogId,
        @JsonProperty("title")
        String title,
        @JsonProperty("content")
        String content,
        @JsonProperty("status")
        String status,
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
        @JsonProperty("profile_image_url")
        String profileImageUrl,
        @JsonProperty("verification_status")
        String verificationStatus,
        @JsonProperty("author_display_name")
        String authorDisplayName,
        @JsonProperty("author_contact_phone")
        String authorContactPhone,
        @JsonProperty("author_region")
        String authorRegion,
        @JsonProperty("liked")
        boolean liked,
        @JsonProperty("published_at")
        LocalDateTime publishedAt,
        @JsonProperty("created_at")
        LocalDateTime createdAt,
        @JsonProperty("updated_at")
        LocalDateTime updatedAt
) {
}
