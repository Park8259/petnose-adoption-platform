package com.petnose.api.dto.auth;

import com.fasterxml.jackson.annotation.JsonAnyGetter;
import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.LinkedHashMap;
import java.util.Map;

public class PasswordResetRequestResponse {

    private final boolean requested;
    private final Map<String, Object> exposedFields;

    private PasswordResetRequestResponse(boolean requested, Map<String, Object> exposedFields) {
        this.requested = requested;
        this.exposedFields = exposedFields;
    }

    public static PasswordResetRequestResponse hidden() {
        return new PasswordResetRequestResponse(true, Map.of());
    }

    public static PasswordResetRequestResponse exposed(String resetToken, long expiresIn) {
        Map<String, Object> fields = new LinkedHashMap<>();
        fields.put("reset_token", resetToken);
        fields.put("expires_in", expiresIn);
        return new PasswordResetRequestResponse(true, fields);
    }

    @JsonProperty("requested")
    public boolean requested() {
        return requested;
    }

    @JsonAnyGetter
    public Map<String, Object> exposedFields() {
        return exposedFields;
    }
}
