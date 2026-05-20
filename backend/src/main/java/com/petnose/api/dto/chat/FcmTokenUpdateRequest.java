package com.petnose.api.dto.chat;

import com.fasterxml.jackson.annotation.JsonProperty;
import com.petnose.api.domain.enums.FcmPlatform;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Size;

public record FcmTokenUpdateRequest(
        @JsonProperty("fcm_token")
        @NotBlank @Size(max = 4096) String fcmToken,
        @NotNull FcmPlatform platform
) {
}
