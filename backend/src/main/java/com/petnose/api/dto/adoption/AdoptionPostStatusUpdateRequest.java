package com.petnose.api.dto.adoption;

import com.fasterxml.jackson.annotation.JsonProperty;

public record AdoptionPostStatusUpdateRequest(
        @JsonProperty("status")
        String status,
        @JsonProperty("adopter_user_id")
        Long adopterUserId
) {
}
