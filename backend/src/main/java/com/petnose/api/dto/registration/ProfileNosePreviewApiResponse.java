package com.petnose.api.dto.registration;

import com.fasterxml.jackson.annotation.JsonProperty;

public record ProfileNosePreviewApiResponse(
        @JsonProperty("extracted")
        boolean extracted,
        @JsonProperty("confidence")
        Double confidence,
        @JsonProperty("crop_width")
        Integer cropWidth,
        @JsonProperty("crop_height")
        Integer cropHeight,
        @JsonProperty("failure_reason")
        String failureReason,
        @JsonProperty("message")
        String message,
        @JsonProperty("error_code")
        String errorCode
) {
}
