package com.petnose.api.service.nose;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

public class NoseReferenceQualityAnalyzer {

    private static final int MAX_REFERENCE_COUNT = 5;

    public ReferenceQualityReport analyze(
            List<List<Double>> referenceVectors,
            List<String> filenames,
            double consistencyThreshold,
            double outlierImprovementThreshold,
            boolean warningEnabled
    ) {
        validate(referenceVectors);
        List<String> safeFilenames = safeFilenames(filenames, referenceVectors.size());

        List<PairwiseScore> pairwiseScores = pairwiseScores(referenceVectors);
        ScoreStats fullStats = stats(pairwiseScores);
        List<PerImageQuality> perImageQualities = perImageQualities(
                referenceVectors.size(),
                safeFilenames,
                consistencyThreshold,
                pairwiseScores
        );
        PerImageQuality weakestImage = perImageQualities.stream()
                .min(Comparator.comparingDouble(PerImageQuality::averageScoreToOthers)
                        .thenComparingDouble(PerImageQuality::minScoreToOthers))
                .orElseThrow();

        List<LeaveOneOutSubset> leaveOneOutSubsets = leaveOneOutSubsets(
                referenceVectors,
                safeFilenames,
                consistencyThreshold,
                fullStats.average()
        );
        LeaveOneOutSubset bestSubset = leaveOneOutSubsets.stream()
                .max(Comparator.comparingDouble(LeaveOneOutSubset::averagePairwiseScore)
                        .thenComparingDouble(LeaveOneOutSubset::minPairwiseScore))
                .orElseThrow();

        double bestSubsetImprovement = bestSubset.averagePairwiseScore() - fullStats.average();
        ReferenceQualityVerdict verdict = verdict(
                fullStats.average(),
                bestSubset.averagePairwiseScore(),
                bestSubsetImprovement,
                consistencyThreshold,
                outlierImprovementThreshold,
                warningEnabled
        );
        String recommendation = recommendation(verdict, weakestImage.imageIndex());

        return new ReferenceQualityReport(
                verdict,
                fullStats.average(),
                fullStats.min(),
                fullStats.max(),
                consistencyThreshold,
                pairwiseScores,
                perImageQualities,
                weakestImage.imageIndex(),
                weakestImage.filename(),
                weakestImage.averageScoreToOthers(),
                leaveOneOutSubsets,
                bestSubset.subsetIndexes(),
                bestSubset.averagePairwiseScore(),
                bestSubsetImprovement,
                recommendation
        );
    }

    private void validate(List<List<Double>> referenceVectors) {
        if (referenceVectors == null || referenceVectors.isEmpty()) {
            throw new IllegalArgumentException("Reference vectors must not be empty.");
        }
        if (referenceVectors.size() < 2) {
            throw new IllegalArgumentException("At least two reference vectors are required.");
        }
        if (referenceVectors.size() > MAX_REFERENCE_COUNT) {
            throw new IllegalArgumentException("Reference vectors must not exceed five images.");
        }
        NoseVectorMath.validateVectors(referenceVectors);
    }

    private List<String> safeFilenames(List<String> filenames, int referenceCount) {
        if (filenames == null || filenames.size() != referenceCount) {
            return nulls(referenceCount);
        }
        return new ArrayList<>(filenames);
    }

    private List<String> nulls(int size) {
        List<String> values = new ArrayList<>(size);
        for (int i = 0; i < size; i++) {
            values.add(null);
        }
        return values;
    }

    private List<PairwiseScore> pairwiseScores(List<List<Double>> referenceVectors) {
        List<PairwiseScore> scores = new ArrayList<>();
        // Registration is capped at five references, so this O(n^2) pass is at most ten comparisons.
        for (int i = 0; i < referenceVectors.size(); i++) {
            for (int j = i + 1; j < referenceVectors.size(); j++) {
                scores.add(new PairwiseScore(i + 1, j + 1, NoseVectorMath.dot(referenceVectors.get(i), referenceVectors.get(j))));
            }
        }
        return List.copyOf(scores);
    }

    private List<PerImageQuality> perImageQualities(
            int referenceCount,
            List<String> filenames,
            double threshold,
            List<PairwiseScore> pairwiseScores
    ) {
        List<PerImageQuality> qualities = new ArrayList<>();
        for (int imageIndex = 1; imageIndex <= referenceCount; imageIndex++) {
            double sum = 0.0;
            double min = Double.POSITIVE_INFINITY;
            double max = Double.NEGATIVE_INFINITY;
            int count = 0;
            int belowThresholdCount = 0;

            for (PairwiseScore pairwiseScore : pairwiseScores) {
                if (pairwiseScore.imageA() == imageIndex || pairwiseScore.imageB() == imageIndex) {
                    double score = pairwiseScore.score();
                    sum += score;
                    min = Math.min(min, score);
                    max = Math.max(max, score);
                    count++;
                    if (score < threshold) {
                        belowThresholdCount++;
                    }
                }
            }

            qualities.add(new PerImageQuality(
                    imageIndex,
                    filenames.get(imageIndex - 1),
                    sum / count,
                    min,
                    max,
                    belowThresholdCount
            ));
        }
        return List.copyOf(qualities);
    }

    private List<LeaveOneOutSubset> leaveOneOutSubsets(
            List<List<Double>> referenceVectors,
            List<String> filenames,
            double threshold,
            double fullAverage
    ) {
        List<LeaveOneOutSubset> subsets = new ArrayList<>();
        for (int excluded = 0; excluded < referenceVectors.size(); excluded++) {
            List<Integer> subsetIndexes = new ArrayList<>();
            List<List<Double>> subsetVectors = new ArrayList<>();
            for (int i = 0; i < referenceVectors.size(); i++) {
                if (i != excluded) {
                    subsetIndexes.add(i + 1);
                    subsetVectors.add(referenceVectors.get(i));
                }
            }

            ScoreStats subsetStats = stats(pairwiseScores(subsetVectors));
            subsets.add(new LeaveOneOutSubset(
                    excluded + 1,
                    filenames.get(excluded),
                    List.copyOf(subsetIndexes),
                    subsetStats.average(),
                    subsetStats.min(),
                    subsetStats.max(),
                    subsetStats.average() >= threshold,
                    subsetStats.average() - fullAverage
            ));
        }
        return List.copyOf(subsets);
    }

    private ScoreStats stats(List<PairwiseScore> pairwiseScores) {
        if (pairwiseScores.isEmpty()) {
            return new ScoreStats(0.0, 0.0, 0.0);
        }
        double sum = 0.0;
        double min = Double.POSITIVE_INFINITY;
        double max = Double.NEGATIVE_INFINITY;
        for (PairwiseScore pairwiseScore : pairwiseScores) {
            double score = pairwiseScore.score();
            sum += score;
            min = Math.min(min, score);
            max = Math.max(max, score);
        }
        return new ScoreStats(sum / pairwiseScores.size(), min, max);
    }

    private ReferenceQualityVerdict verdict(
            double fullAverage,
            double bestSubsetAverage,
            double bestSubsetImprovement,
            double threshold,
            double outlierImprovementThreshold,
            boolean warningEnabled
    ) {
        if (fullAverage >= threshold) {
            if (warningEnabled && bestSubsetImprovement >= outlierImprovementThreshold) {
                return ReferenceQualityVerdict.WARN_ACCEPTED;
            }
            return ReferenceQualityVerdict.ACCEPTED;
        }
        if (bestSubsetAverage >= threshold) {
            return ReferenceQualityVerdict.RETAKE_ONE;
        }
        return ReferenceQualityVerdict.RETAKE_ALL;
    }

    private String recommendation(ReferenceQualityVerdict verdict, int weakestImageIndex) {
        return switch (verdict) {
            case ACCEPTED -> "비문 기준 이미지 품질 검사를 통과했습니다.";
            case WARN_ACCEPTED -> "%d번째 이미지가 상대적으로 약합니다. 정확도를 높이려면 다시 촬영하는 것을 권장합니다."
                    .formatted(weakestImageIndex);
            case RETAKE_ONE -> "%d번째 비문 이미지가 다른 이미지들과 일관성이 낮습니다. 코 전체가 중앙에 오도록 다시 촬영해주세요."
                    .formatted(weakestImageIndex);
            case RETAKE_ALL -> "비문 이미지들 사이의 코 위치나 각도가 달라 기준 이미지로 사용하기 어렵습니다. 5장을 같은 거리와 각도로 다시 촬영해주세요.";
        };
    }

    public enum ReferenceQualityVerdict {
        ACCEPTED,
        WARN_ACCEPTED,
        RETAKE_ONE,
        RETAKE_ALL
    }

    public record ReferenceQualityReport(
            ReferenceQualityVerdict verdict,
            double averagePairwiseScore,
            double minPairwiseScore,
            double maxPairwiseScore,
            double threshold,
            List<PairwiseScore> pairwiseScores,
            List<PerImageQuality> perImageQualities,
            Integer weakestImageIndex,
            String weakestImageFilename,
            Double weakestImageAverageScore,
            List<LeaveOneOutSubset> leaveOneOutSubsets,
            List<Integer> bestSubsetIndexes,
            double bestSubsetAverageScore,
            double bestSubsetImprovement,
            String recommendation
    ) {
    }

    public record PairwiseScore(
            int imageA,
            int imageB,
            double score
    ) {
    }

    public record PerImageQuality(
            int imageIndex,
            String filename,
            double averageScoreToOthers,
            double minScoreToOthers,
            double maxScoreToOthers,
            int belowThresholdPairsCount
    ) {
    }

    public record LeaveOneOutSubset(
            int excludedImageIndex,
            String excludedFilename,
            List<Integer> subsetIndexes,
            double averagePairwiseScore,
            double minPairwiseScore,
            double maxPairwiseScore,
            boolean accepted,
            double improvementVsFullAverage
    ) {
    }

    private record ScoreStats(
            double average,
            double min,
            double max
    ) {
    }
}
