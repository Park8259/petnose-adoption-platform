package com.petnose.api.dto.chat;

import com.fasterxml.jackson.annotation.JsonProperty;

public record FirebaseTokenResponse(
        @JsonProperty("firebase_uid")
        String firebaseUid,
        @JsonProperty("firebase_custom_token")
        String firebaseCustomToken
) {
}
