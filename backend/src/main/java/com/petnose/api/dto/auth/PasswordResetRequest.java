package com.petnose.api.dto.auth;

import com.fasterxml.jackson.annotation.JsonProperty;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record PasswordResetRequest(
        @JsonProperty("email")
        @NotBlank
        @Size(max = 255)
        String email
) {
}
