package com.petnose.api.dto.registration;

import com.fasterxml.jackson.annotation.JsonProperty;

public record ProfileMatchScoreResponse(
        @JsonProperty("index")
        int index,
        @JsonProperty("score")
        Double score,
        @JsonProperty("passed")
        boolean passed
) {
}
