package com.petnose.api.service.nose;

import com.petnose.api.client.QdrantDogVectorClient.QdrantVectorSearchResult;
import org.junit.jupiter.api.Test;

import java.util.List;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.within;

class DogNoseCandidateAggregatorTest {

    private final DogNoseCandidateAggregator aggregator = new DogNoseCandidateAggregator();

    @Test
    void groupsReferenceResultsByDogIdAndComputesScores() {
        DogNoseCandidateAggregator.DogNoseAggregationResult result = aggregator.aggregate(List.of(
                reference("point-a-low", "dog-a", 0.58, 13L, 2),
                reference("point-a-best", "dog-a", 0.80, 12L, 1),
                reference("point-a-mid", "dog-a", 0.64, 11L, 0),
                reference("point-b", "dog-b", 0.70, 21L, 0),
                reference("point-blank", " ", 0.99, 31L, 0),
                reference("point-null", null, 0.99, 32L, 0)
        ), List.of(
                centroid("centroid-a-low", "dog-a", 0.61),
                centroid("centroid-a-best", "dog-a", 0.83),
                centroid("centroid-only", "dog-c", 0.99)
        ), 0.60);

        assertThat(result.candidates()).extracting(DogNoseCandidateAggregator.DogNoseCandidateScore::dogId)
                .containsExactly("dog-a", "dog-b");
        assertThat(result.topCandidate().dogId()).isEqualTo("dog-a");

        DogNoseCandidateAggregator.DogNoseCandidateScore dogA = result.candidates().get(0);
        assertThat(dogA.finalScore()).isEqualTo(0.83);
        assertThat(dogA.maxReferenceScore()).isEqualTo(0.80);
        assertThat(dogA.top2AverageScore()).isCloseTo(0.72, within(1.0e-12));
        assertThat(dogA.centroidScore()).isEqualTo(0.83);
        assertThat(dogA.hitCount()).isEqualTo(2);
        assertThat(dogA.bestReferencePointId()).isEqualTo("point-a-best");
        assertThat(dogA.bestDogImageId()).isEqualTo(12L);
        assertThat(dogA.bestReferenceIndex()).isEqualTo(1);

        DogNoseCandidateAggregator.DogNoseCandidateScore dogB = result.candidates().get(1);
        assertThat(dogB.finalScore()).isEqualTo(0.70);
        assertThat(dogB.maxReferenceScore()).isEqualTo(0.70);
        assertThat(dogB.centroidScore()).isNull();
    }

    @Test
    void sortsCandidatesByScoreBreakdownAndDogId() {
        DogNoseCandidateAggregator.DogNoseAggregationResult result = aggregator.aggregate(List.of(
                reference("high", "dog-high", 0.90, 1L, 0),
                reference("a-best", "dog-a", 0.80, 2L, 0),
                reference("a-second", "dog-a", 0.60, 3L, 1),
                reference("b-best", "dog-b", 0.80, 4L, 0),
                reference("b-second", "dog-b", 0.70, 5L, 1),
                reference("c-best", "dog-c", 0.80, 6L, 0),
                reference("c-second", "dog-c", 0.70, 7L, 1),
                reference("d-best", "dog-d", 0.80, 8L, 0),
                reference("d-second", "dog-d", 0.70, 9L, 1),
                reference("d-third", "dog-d", 0.60, 10L, 2)
        ), List.of(
                centroid("centroid-a", "dog-a", 0.40),
                centroid("centroid-c", "dog-c", 0.90),
                centroid("centroid-d", "dog-d", 0.90)
        ), 0.60);

        assertThat(result.candidates()).extracting(DogNoseCandidateAggregator.DogNoseCandidateScore::dogId)
                .containsExactly("dog-high", "dog-d", "dog-c", "dog-b", "dog-a");
    }

    @Test
    void sortsCandidatesByCompositeFinalScore() {
        DogNoseCandidateAggregator.DogNoseAggregationResult result = aggregator.aggregate(List.of(
                reference("reference-high", "dog-reference-high", 0.80, 1L, 0),
                reference("reference-low", "dog-centroid-high", 0.62, 2L, 0)
        ), List.of(
                centroid("centroid-high", "dog-centroid-high", 0.90)
        ), 0.60);

        assertThat(result.candidates()).extracting(DogNoseCandidateAggregator.DogNoseCandidateScore::dogId)
                .containsExactly("dog-centroid-high", "dog-reference-high");
        assertThat(result.topCandidate().finalScore()).isEqualTo(0.90);
        assertThat(result.topCandidate().maxReferenceScore()).isEqualTo(0.62);
        assertThat(result.topCandidate().centroidScore()).isEqualTo(0.90);
    }

    private static QdrantVectorSearchResult reference(
            String pointId,
            String dogId,
            double score,
            Long dogImageId,
            Integer referenceIndex
    ) {
        return new QdrantVectorSearchResult(
                pointId,
                dogId,
                score,
                "REFERENCE",
                dogImageId,
                referenceIndex,
                "model-v2",
                512,
                "preprocess-v2"
        );
    }

    private static QdrantVectorSearchResult centroid(String pointId, String dogId, double score) {
        return new QdrantVectorSearchResult(
                pointId,
                dogId,
                score,
                "CENTROID",
                null,
                null,
                "model-v2",
                512,
                "preprocess-v2"
        );
    }
}
