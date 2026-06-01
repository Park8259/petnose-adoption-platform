package com.petnose.api.service.nose;

import com.petnose.api.domain.enums.VerificationResult;
import org.junit.jupiter.api.Test;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class DogNoseDecisionPolicyTest {

    private final DogNoseDecisionPolicy policy = new DogNoseDecisionPolicy();

    @Test
    void nullTopCandidatePassesAndAllowsRegistration() {
        DogNoseDecisionPolicy.DogNoseDecision decision = policy.evaluate(null, 0.65, 0.60);

        assertThat(decision.result()).isEqualTo(VerificationResult.PASSED);
        assertThat(decision.registrationAllowed()).isTrue();
        assertThat(decision.finalScore()).isZero();
        assertThat(decision.topCandidate()).isNull();
    }

    @Test
    void scoreAtDuplicateThresholdIsDuplicateSuspected() {
        DogNoseDecisionPolicy.DogNoseDecision decision = policy.evaluate(candidate(0.65), 0.65, 0.60);

        assertThat(decision.result()).isEqualTo(VerificationResult.DUPLICATE_SUSPECTED);
        assertThat(decision.registrationAllowed()).isFalse();
        assertThat(decision.finalScore()).isEqualTo(0.65);
    }

    @Test
    void scoreBetweenReviewAndDuplicateRequiresReview() {
        DogNoseDecisionPolicy.DogNoseDecision decision = policy.evaluate(candidate(0.60), 0.65, 0.60);

        assertThat(decision.result()).isEqualTo(VerificationResult.REVIEW_REQUIRED);
        assertThat(decision.registrationAllowed()).isFalse();
        assertThat(decision.finalScore()).isEqualTo(0.60);
    }

    @Test
    void scoreBelowReviewLowerBoundPasses() {
        DogNoseDecisionPolicy.DogNoseDecision decision = policy.evaluate(candidate(0.59), 0.65, 0.60);

        assertThat(decision.result()).isEqualTo(VerificationResult.PASSED);
        assertThat(decision.registrationAllowed()).isTrue();
        assertThat(decision.finalScore()).isEqualTo(0.59);
    }

    @Test
    void invalidThresholdsThrow() {
        assertThatThrownBy(() -> policy.evaluate(candidate(0.70), 0.60, 0.60))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> policy.evaluate(candidate(0.70), 0.65, -0.01))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> policy.evaluate(candidate(0.70), 1.01, 0.60))
                .isInstanceOf(IllegalArgumentException.class);
    }

    private static DogNoseCandidateAggregator.DogNoseCandidateScore candidate(double score) {
        return new DogNoseCandidateAggregator.DogNoseCandidateScore(
                "dog-a",
                score,
                score,
                score,
                null,
                1,
                "point-a",
                1L,
                0
        );
    }
}
