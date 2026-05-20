package com.petnose.api.dto.chat;

import com.fasterxml.jackson.annotation.JsonProperty;

public record ChatMessageResponse(
        @JsonProperty("message_id")
        String messageId,
        @JsonProperty("room_id")
        String roomId,
        @JsonProperty("sender_uid")
        String senderUid,
        String type,
        String text,
        @JsonProperty("created_at")
        String createdAt
) {
}
