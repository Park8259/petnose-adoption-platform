package com.petnose.api.dto.chat;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.List;

public record ChatRoomListResponse(
        List<ChatRoomListItemResponse> items,
        int page,
        int size,
        @JsonProperty("total_count")
        long totalCount
) {
}
