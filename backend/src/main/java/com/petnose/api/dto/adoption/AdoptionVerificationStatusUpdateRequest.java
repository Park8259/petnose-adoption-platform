package com.petnose.api.dto.adoption;

import com.fasterxml.jackson.annotation.JsonProperty;

public record AdoptionVerificationStatusUpdateRequest(
        @JsonProperty("verification_step1_completed")
        Boolean verificationStep1Completed,
        @JsonProperty("verification_step2_completed")
        Boolean verificationStep2Completed,
        @JsonProperty("verification_step3_completed")
        Boolean verificationStep3Completed
) {
    public boolean hasAnyStep() {
        return verificationStep1Completed != null
                || verificationStep2Completed != null
                || verificationStep3Completed != null;
    }
}
