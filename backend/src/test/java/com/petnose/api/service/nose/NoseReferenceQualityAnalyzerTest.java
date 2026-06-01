package com.petnose.api.service.nose;

import com.petnose.api.service.nose.NoseReferenceQualityAnalyzer.ReferenceQualityReport;
import com.petnose.api.service.nose.NoseReferenceQualityAnalyzer.ReferenceQualityVerdict;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.assertj.core.api.Assertions.within;

class NoseReferenceQualityAnalyzerTest {

    private static final double THRESHOLD = 0.55;
    private static final double OUTLIER_IMPROVEMENT_THRESHOLD = 0.04;

    private final NoseReferenceQualityAnalyzer analyzer = new NoseReferenceQualityAnalyzer();

    @Test
    void acceptedCleanSet() {
        ReferenceQualityReport report = analyze(cleanVectors());

        assertThat(report.verdict()).isEqualTo(ReferenceQualityVerdict.ACCEPTED);
        assertThat(report.pairwiseScores()).hasSize(10);
        assertThat(report.averagePairwiseScore()).isCloseTo(1.0, within(1.0e-12));
        assertThat(report.minPairwiseScore()).isCloseTo(1.0, within(1.0e-12));
        assertThat(report.maxPairwiseScore()).isCloseTo(1.0, within(1.0e-12));
    }

    @Test
    void warnAcceptedWhenLeaveOneOutImproves() {
        ReferenceQualityReport report = analyze(outlierVectors(-0.10));

        assertThat(report.averagePairwiseScore()).isCloseTo(0.56, within(1.0e-12));
        assertThat(report.bestSubsetAverageScore()).isCloseTo(1.0, within(1.0e-12));
        assertThat(report.bestSubsetImprovement()).isGreaterThanOrEqualTo(OUTLIER_IMPROVEMENT_THRESHOLD);
        assertThat(report.verdict()).isEqualTo(ReferenceQualityVerdict.WARN_ACCEPTED);
        assertThat(report.weakestImageIndex()).isEqualTo(5);
        assertThat(report.weakestImageFilename()).isEqualTo("nose_5.jpg");
    }

    @Test
    void retakeOneWhenFullFailsButSubsetPasses() {
        ReferenceQualityReport report = analyze(outlierVectors(-0.15));

        assertThat(report.averagePairwiseScore()).isCloseTo(0.54, within(1.0e-12));
        assertThat(report.bestSubsetAverageScore()).isCloseTo(1.0, within(1.0e-12));
        assertThat(report.verdict()).isEqualTo(ReferenceQualityVerdict.RETAKE_ONE);
        assertThat(report.weakestImageIndex()).isEqualTo(5);
        assertThat(report.recommendation()).contains("5번째");
    }

    @Test
    void retakeAllWhenFullAndSubsetFail() {
        ReferenceQualityReport report = analyze(inconsistentVectors());

        assertThat(report.averagePairwiseScore()).isLessThan(THRESHOLD);
        assertThat(report.bestSubsetAverageScore()).isLessThan(THRESHOLD);
        assertThat(report.verdict()).isEqualTo(ReferenceQualityVerdict.RETAKE_ALL);
    }

    @Test
    void pairCountForFiveImagesIsTen() {
        ReferenceQualityReport report = analyze(cleanVectors());

        assertThat(report.pairwiseScores()).hasSize(10);
    }

    @Test
    void publicIndexesAreOneBased() {
        ReferenceQualityReport report = analyze(outlierVectors(-0.15));

        assertThat(report.pairwiseScores().get(0).imageA()).isEqualTo(1);
        assertThat(report.pairwiseScores().get(0).imageB()).isEqualTo(2);
        assertThat(report.pairwiseScores().get(9).imageA()).isEqualTo(4);
        assertThat(report.pairwiseScores().get(9).imageB()).isEqualTo(5);
        assertThat(report.weakestImageIndex()).isEqualTo(5);
        assertThat(report.bestSubsetIndexes()).containsExactly(1, 2, 3, 4);
        assertThat(report.leaveOneOutSubsets())
                .extracting(NoseReferenceQualityAnalyzer.LeaveOneOutSubset::excludedImageIndex)
                .containsExactly(1, 2, 3, 4, 5);
    }

    @Test
    void invalidVectorsThrow() {
        assertThatThrownBy(() -> analyzer.analyze(null, null, THRESHOLD, OUTLIER_IMPROVEMENT_THRESHOLD, true))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> analyze(List.of()))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> analyze(List.of(vector(1.0, 0.0, 0.0))))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> analyze(List.of(
                vector(1.0, 0.0, 0.0),
                List.of(1.0, 0.0)
        )))
                .isInstanceOf(IllegalArgumentException.class);
        assertThatThrownBy(() -> analyze(List.of(
                vector(1.0, 0.0, 0.0),
                vector(1.0, 0.0, 0.0),
                vector(1.0, 0.0, 0.0),
                vector(1.0, 0.0, 0.0),
                vector(1.0, 0.0, 0.0),
                vector(1.0, 0.0, 0.0)
        )))
                .isInstanceOf(IllegalArgumentException.class);
    }

    @Test
    void filenameMismatchFallsBackToNullFilenames() {
        ReferenceQualityReport report = analyzer.analyze(
                cleanVectors(),
                List.of("only-one.jpg"),
                THRESHOLD,
                OUTLIER_IMPROVEMENT_THRESHOLD,
                true
        );

        assertThat(report.perImageQualities())
                .extracting(NoseReferenceQualityAnalyzer.PerImageQuality::filename)
                .containsOnlyNulls();
    }

    private ReferenceQualityReport analyze(List<List<Double>> vectors) {
        return analyzer.analyze(vectors, filenames(), THRESHOLD, OUTLIER_IMPROVEMENT_THRESHOLD, true);
    }

    private List<String> filenames() {
        return List.of("nose_1.jpg", "nose_2.jpg", "nose_3.jpg", "nose_4.jpg", "nose_5.jpg");
    }

    private static List<List<Double>> cleanVectors() {
        return List.of(
                vector(1.0, 0.0, 0.0),
                vector(1.0, 0.0, 0.0),
                vector(1.0, 0.0, 0.0),
                vector(1.0, 0.0, 0.0),
                vector(1.0, 0.0, 0.0)
        );
    }

    private static List<List<Double>> outlierVectors(double outlierDot) {
        double y = Math.sqrt(1.0 - (outlierDot * outlierDot));
        return List.of(
                vector(1.0, 0.0, 0.0),
                vector(1.0, 0.0, 0.0),
                vector(1.0, 0.0, 0.0),
                vector(1.0, 0.0, 0.0),
                vector(outlierDot, y, 0.0)
        );
    }

    private static List<List<Double>> inconsistentVectors() {
        return List.of(
                vector(1.0, 0.0, 0.0),
                vector(-1.0, 0.0, 0.0),
                vector(0.0, 1.0, 0.0),
                vector(0.0, -1.0, 0.0),
                vector(0.0, 0.0, 1.0)
        );
    }

    private static List<Double> vector(double first, double second, double third) {
        List<Double> vector = new ArrayList<>();
        vector.add(first);
        vector.add(second);
        vector.add(third);
        return vector;
    }
}
