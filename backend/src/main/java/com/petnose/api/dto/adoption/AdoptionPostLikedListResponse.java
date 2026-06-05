package com.petnose.api.dto.adoption;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.List;

public record AdoptionPostLikedListResponse(
        @JsonProperty("items")
        List<AdoptionPostLikedListItemResponse> items,
        @JsonProperty("page")
        int page,
        @JsonProperty("size")
        int size,
        @JsonProperty("total_count")
        long totalCount
) {
}
