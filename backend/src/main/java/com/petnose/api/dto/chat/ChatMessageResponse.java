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
        @JsonProperty("image_url")
        String imageUrl,
        @JsonProperty("image_mime_type")
        String imageMimeType,
        @JsonProperty("image_file_size")
        Long imageFileSize,
        @JsonProperty("image_sha256")
        String imageSha256,
        @JsonProperty("created_at")
        String createdAt
) {
}
