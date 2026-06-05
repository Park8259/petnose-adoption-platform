package com.petnose.api.dto.adoption;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.time.LocalDateTime;

public record AdoptionPostStatusUpdateResponse(
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
        @JsonProperty("published_at")
        LocalDateTime publishedAt,
        @JsonProperty("closed_at")
        LocalDateTime closedAt,
        @JsonProperty("adopter_user_id")
        Long adopterUserId,
        @JsonProperty("adopted_at")
        LocalDateTime adoptedAt,
        @JsonProperty("created_at")
        LocalDateTime createdAt,
        @JsonProperty("updated_at")
        LocalDateTime updatedAt
) {
}
