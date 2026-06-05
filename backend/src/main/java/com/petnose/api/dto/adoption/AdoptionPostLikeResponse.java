package com.petnose.api.dto.adoption;

import com.fasterxml.jackson.annotation.JsonProperty;

public record AdoptionPostLikeResponse(
        @JsonProperty("post_id")
        Long postId,
        @JsonProperty("liked")
        boolean liked
) {
}
