package com.petnose.api.dto.chat;

import com.fasterxml.jackson.annotation.JsonProperty;
import jakarta.validation.constraints.NotNull;

public record ChatRoomCreateRequest(
        @JsonProperty("post_id")
        @NotNull Long postId
) {
}
