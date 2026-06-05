package com.petnose.api.dto.user;

import com.fasterxml.jackson.annotation.JsonProperty;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record UserPasswordChangeRequest(
        @JsonProperty("current_password")
        @NotBlank
        @Size(max = 255)
        String currentPassword,
        @JsonProperty("new_password")
        @NotBlank
        @Size(max = 255)
        String newPassword
) {
}
