package com.petnose.api.service.nose;

import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.assertj.core.api.Assertions.within;

class NoseReferenceConsistencyCheckerTest {

    private final NoseReferenceConsistencyChecker checker = new NoseReferenceConsistencyChecker();

    @Test
    void threeConsistentVectorsAreAccepted() {
        NoseReferenceConsistencyChecker.ReferenceConsistencyResult result = checker.check(List.of(
                List.of(1.0, 0.0),
                List.of(1.0, 0.0),
                List.of(1.0, 0.0)
        ), 0.60);

        assertThat(result.accepted()).isTrue();
        assertThat(result.averagePairwiseScore()).isEqualTo(1.0);
        assertThat(result.minPairwiseScore()).isEqualTo(1.0);
        assertThat(result.maxPairwiseScore()).isEqualTo(1.0);
        assertThat(result.pairCount()).isEqualTo(3);
        assertThat(result.threshold()).isEqualTo(0.60);
    }

    @Test
    void inconsistentVectorsAreRejected() {
        NoseReferenceConsistencyChecker.ReferenceConsistencyResult result = checker.check(List.of(
                List.of(1.0, 0.0),
                List.of(0.0, 1.0),
                List.of(-1.0, 0.0)
        ), 0.60);

        assertThat(result.accepted()).isFalse();
        assertThat(result.averagePairwiseScore()).isCloseTo(-1.0 / 3.0, within(1.0e-12));
        assertThat(result.minPairwiseScore()).isEqualTo(-1.0);
        assertThat(result.maxPairwiseScore()).isEqualTo(0.0);
        assertThat(result.pairCount()).isEqualTo(3);
    }

    @Test
    void averageMinMaxAndPairCountAreCalculated() {
        NoseReferenceConsistencyChecker.ReferenceConsistencyResult result = checker.check(List.of(
                List.of(1.0, 0.0),
                List.of(0.8, 0.6),
                List.of(0.0, 1.0)
        ), 0.60);

        assertThat(result.accepted()).isFalse();
        assertThat(result.averagePairwiseScore()).isCloseTo((0.8 + 0.0 + 0.6) / 3.0, within(1.0e-12));
        assertThat(result.minPairwiseScore()).isEqualTo(0.0);
        assertThat(result.maxPairwiseScore()).isEqualTo(0.8);
        assertThat(result.pairCount()).isEqualTo(3);
    }

    @Test
    void lessThanTwoVectorsThrows() {
        assertThatThrownBy(() -> checker.check(List.of(List.of(1.0, 0.0)), 0.60))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("At least two");
    }
}
