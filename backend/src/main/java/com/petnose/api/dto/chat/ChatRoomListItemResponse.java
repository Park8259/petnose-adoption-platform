package com.petnose.api.dto.chat;

import com.fasterxml.jackson.annotation.JsonProperty;

public record ChatRoomListItemResponse(
        @JsonProperty("room_id")
        String roomId,
        @JsonProperty("post_id")
        Long postId,
        @JsonProperty("post_title")
        String postTitle,
        @JsonProperty("post_status")
        String postStatus,
        @JsonProperty("other_user_display_name")
        String otherUserDisplayName,
        @JsonProperty("last_message_preview")
        String lastMessagePreview,
        @JsonProperty("last_message_at")
        String lastMessageAt,
        @JsonProperty("unread_count")
        long unreadCount
) {
}
