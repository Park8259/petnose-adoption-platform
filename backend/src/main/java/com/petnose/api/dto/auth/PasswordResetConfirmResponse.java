package com.petnose.api.dto.auth;

import com.fasterxml.jackson.annotation.JsonProperty;

public record PasswordResetConfirmResponse(
        @JsonProperty("reset")
        boolean reset
) {
}
