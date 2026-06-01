package com.petnose.api.service.nose;

import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.assertj.core.api.Assertions.within;

class NoseVectorMathTest {

    @Test
    void centroidNormalizesMeanVector() {
        List<Double> centroid = NoseVectorMath.centroid(List.of(
                List.of(1.0, 0.0),
                List.of(0.0, 1.0)
        ));

        double expected = 1.0 / Math.sqrt(2.0);
        assertThat(centroid).hasSize(2);
        assertThat(centroid.get(0)).isCloseTo(expected, within(1.0e-12));
        assertThat(centroid.get(1)).isCloseTo(expected, within(1.0e-12));
    }

    @Test
    void dimensionMismatchThrows() {
        assertThatThrownBy(() -> NoseVectorMath.dot(List.of(1.0, 2.0), List.of(1.0)))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("dimensions");
    }

    @Test
    void emptyVectorThrows() {
        assertThatThrownBy(() -> NoseVectorMath.normalize(List.of()))
                .isInstanceOf(IllegalArgumentException.class)
                .hasMessageContaining("empty");
    }

    @Test
    void inputVectorsAreNotMutated() {
        List<Double> first = new ArrayList<>(List.of(3.0, 0.0));
        List<Double> second = new ArrayList<>(List.of(0.0, 4.0));
        List<Double> firstSnapshot = List.copyOf(first);
        List<Double> secondSnapshot = List.copyOf(second);

        NoseVectorMath.normalize(first);
        NoseVectorMath.centroid(List.of(first, second));

        assertThat(first).containsExactlyElementsOf(firstSnapshot);
        assertThat(second).containsExactlyElementsOf(secondSnapshot);
    }
}
