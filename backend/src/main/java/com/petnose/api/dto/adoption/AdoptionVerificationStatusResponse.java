package com.petnose.api.dto.adoption;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.time.LocalDateTime;

public record AdoptionVerificationStatusResponse(
        @JsonProperty("post_id")
        Long postId,
        @JsonProperty("status")
        String status,
        @JsonProperty("reserved_by_user_id")
        Long reservedByUserId,
        @JsonProperty("adopter_user_id")
        Long adopterUserId,
        @JsonProperty("verification_step1_completed")
        boolean verificationStep1Completed,
        @JsonProperty("verification_step2_completed")
        boolean verificationStep2Completed,
        @JsonProperty("verification_step3_completed")
        boolean verificationStep3Completed,
        @JsonProperty("updated_at")
        LocalDateTime updatedAt
) {
}
