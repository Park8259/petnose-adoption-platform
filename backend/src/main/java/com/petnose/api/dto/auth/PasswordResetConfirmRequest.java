package com.petnose.api.dto.auth;

import com.fasterxml.jackson.annotation.JsonProperty;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record PasswordResetConfirmRequest(
        @JsonProperty("reset_token")
        @NotBlank
        String resetToken,
        @JsonProperty("new_password")
        @NotBlank
        @Size(max = 255)
        String newPassword
) {
}
