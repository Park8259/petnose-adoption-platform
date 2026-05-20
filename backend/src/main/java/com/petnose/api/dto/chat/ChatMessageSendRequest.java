package com.petnose.api.dto.chat;

import com.fasterxml.jackson.annotation.JsonProperty;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.Size;

public record ChatMessageSendRequest(
        @NotBlank @Size(max = 1000) String text,
        @JsonProperty("client_message_id")
        @Size(max = 100) String clientMessageId
) {
}
