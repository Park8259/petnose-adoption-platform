package com.petnose.api.service.nose;

import com.petnose.api.client.QdrantDogVectorClient.QdrantVectorSearchResult;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class DogNoseCandidateAggregator {

    public DogNoseAggregationResult aggregate(
            List<QdrantVectorSearchResult> referenceResults,
            List<QdrantVectorSearchResult> centroidResults,
            double reviewLowerBound
    ) {
        Map<String, List<QdrantVectorSearchResult>> referenceResultsByDogId = new HashMap<>();
        for (QdrantVectorSearchResult result : safeList(referenceResults)) {
            if (result == null || result.dogId() == null || result.dogId().isBlank()) {
                continue;
            }
            referenceResultsByDogId.computeIfAbsent(result.dogId(), ignored -> new ArrayList<>()).add(result);
        }

        Map<String, Double> centroidScoresByDogId = new HashMap<>();
        for (QdrantVectorSearchResult result : safeList(centroidResults)) {
            if (result == null || result.dogId() == null || result.dogId().isBlank()) {
                continue;
            }
            centroidScoresByDogId.merge(result.dogId(), result.score(), Math::max);
        }

        List<DogNoseCandidateScore> candidates = new ArrayList<>();
        for (Map.Entry<String, List<QdrantVectorSearchResult>> entry : referenceResultsByDogId.entrySet()) {
            List<QdrantVectorSearchResult> dogReferenceResults = new ArrayList<>(entry.getValue());
            dogReferenceResults.sort((left, right) -> Double.compare(right.score(), left.score()));

            QdrantVectorSearchResult bestReferenceResult = dogReferenceResults.get(0);
            double maxReferenceScore = bestReferenceResult.score();
            double top2AverageScore = topAverage(dogReferenceResults, 2);
            Double centroidScore = centroidScoresByDogId.get(entry.getKey());
            double finalScore = centroidScore == null ? maxReferenceScore : Math.max(maxReferenceScore, centroidScore);
            int hitCount = 0;
            for (QdrantVectorSearchResult result : dogReferenceResults) {
                if (result.score() >= reviewLowerBound) {
                    hitCount++;
                }
            }

            candidates.add(new DogNoseCandidateScore(
                    entry.getKey(),
                    finalScore,
                    maxReferenceScore,
                    top2AverageScore,
                    centroidScore,
                    hitCount,
                    bestReferenceResult.pointId(),
                    bestReferenceResult.dogImageId(),
                    bestReferenceResult.referenceIndex()
            ));
        }

        candidates.sort(DogNoseCandidateAggregator::compareCandidate);
        DogNoseCandidateScore topCandidate = candidates.isEmpty() ? null : candidates.get(0);
        return new DogNoseAggregationResult(List.copyOf(candidates), topCandidate);
    }

    private static List<QdrantVectorSearchResult> safeList(List<QdrantVectorSearchResult> results) {
        return results == null ? List.of() : results;
    }

    private static double topAverage(List<QdrantVectorSearchResult> results, int limit) {
        int count = Math.min(results.size(), limit);
        double sum = 0.0;
        for (int i = 0; i < count; i++) {
            sum += results.get(i).score();
        }
        return sum / count;
    }

    private static int compareCandidate(DogNoseCandidateScore left, DogNoseCandidateScore right) {
        int byFinalScore = Double.compare(right.finalScore(), left.finalScore());
        if (byFinalScore != 0) {
            return byFinalScore;
        }

        int byTop2AverageScore = Double.compare(right.top2AverageScore(), left.top2AverageScore());
        if (byTop2AverageScore != 0) {
            return byTop2AverageScore;
        }

        int byCentroidScore = Double.compare(
                scoreForSort(right.centroidScore()),
                scoreForSort(left.centroidScore())
        );
        if (byCentroidScore != 0) {
            return byCentroidScore;
        }

        int byHitCount = Integer.compare(right.hitCount(), left.hitCount());
        if (byHitCount != 0) {
            return byHitCount;
        }

        return left.dogId().compareTo(right.dogId());
    }

    private static double scoreForSort(Double score) {
        return score == null ? Double.NEGATIVE_INFINITY : score;
    }

    public record DogNoseCandidateScore(
            String dogId,
            double finalScore,
            double maxReferenceScore,
            double top2AverageScore,
            Double centroidScore,
            int hitCount,
            String bestReferencePointId,
            Long bestDogImageId,
            Integer bestReferenceIndex
    ) {
    }

    public record DogNoseAggregationResult(
            List<DogNoseCandidateScore> candidates,
            DogNoseCandidateScore topCandidate
    ) {
    }
}
