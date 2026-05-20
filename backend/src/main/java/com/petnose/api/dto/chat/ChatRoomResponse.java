package com.petnose.api.dto.chat;

import com.fasterxml.jackson.annotation.JsonProperty;

public record ChatRoomResponse(
        @JsonProperty("room_id")
        String roomId,
        @JsonProperty("post_id")
        Long postId,
        @JsonProperty("firebase_room_path")
        String firebaseRoomPath,
        @JsonProperty("author_user_id")
        Long authorUserId,
        @JsonProperty("inquirer_user_id")
        Long inquirerUserId,
        String status
) {
}
