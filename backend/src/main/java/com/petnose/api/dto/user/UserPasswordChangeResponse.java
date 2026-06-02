package com.petnose.api.dto.user;

import com.fasterxml.jackson.annotation.JsonProperty;

public record UserPasswordChangeResponse(
        @JsonProperty("changed")
        boolean changed
) {
}
