package com.petnose.api.dto.registration;

import com.fasterxml.jackson.annotation.JsonProperty;

public record DogProfileDraftResponse(
        @JsonProperty("dog_id")
        String dogId,
        @JsonProperty("status")
        String status,
        @JsonProperty("profile_image_url")
        String profileImageUrl,
        @JsonProperty("profile_nose_preview")
        ProfileNosePreviewResponse profileNosePreview,
        @JsonProperty("message")
        String message
) {
}
