package com.petnose.api.dto.chat;

import com.fasterxml.jackson.annotation.JsonProperty;

public record ChatReadResponse(
        @JsonProperty("room_id")
        String roomId,
        boolean read
) {
}
