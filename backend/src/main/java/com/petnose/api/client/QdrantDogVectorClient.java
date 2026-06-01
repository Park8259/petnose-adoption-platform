package com.petnose.api.client;

import com.petnose.api.dto.registration.QdrantSearchResult;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.client.WebClient;
import org.springframework.web.reactive.function.client.WebClientResponseException;

import java.time.Duration;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

@Slf4j
@Component
public class QdrantDogVectorClient {

    private final WebClient webClient;
    private final String collection;
    private final int searchTopK;
    private final double searchScoreThreshold;
    private final long searchTimeoutMs;
    private final long upsertTimeoutMs;

    public QdrantDogVectorClient(
            WebClient.Builder webClientBuilder,
            @Value("${qdrant.host}") String host,
            @Value("${qdrant.port}") int port,
            @Value("${qdrant.collection}") String collection,
            @Value("${qdrant.search-top-k:5}") int searchTopK,
            @Value("${qdrant.search-score-threshold:0.55}") double searchScoreThreshold,
            @Value("${qdrant.search-timeout-ms:3000}") long searchTimeoutMs,
            @Value("${qdrant.upsert-timeout-ms:3000}") long upsertTimeoutMs
    ) {
        this.webClient = webClientBuilder
                .baseUrl("http://" + host + ":" + port)
                .build();
        this.collection = collection;
        this.searchTopK = searchTopK;
        this.searchScoreThreshold = searchScoreThreshold;
        this.searchTimeoutMs = searchTimeoutMs;
        this.upsertTimeoutMs = upsertTimeoutMs;
    }

    @SuppressWarnings("unchecked")
    public List<QdrantSearchResult> search(List<Double> vector) {
        return search(vector, searchTopK, searchScoreThreshold);
    }

    public List<QdrantSearchResult> search(List<Double> vector, int limit) {
        return search(vector, limit, null);
    }

    public List<QdrantSearchResult> searchExpectedDog(List<Double> vector, String expectedDogId) {
        return search(vector, 1, null, expectedDogFilter(expectedDogId));
    }

    public List<QdrantSearchResult> search(List<Double> vector, int limit, Double scoreThreshold) {
        return search(vector, limit, scoreThreshold, activeOnlyFilter());
    }

    public List<QdrantVectorSearchResult> searchReferencePoints(
            List<Double> vector,
            int limit,
            double scoreThreshold
    ) {
        return searchV2(vector, limit, scoreThreshold, embeddingKindFilter("REFERENCE"));
    }

    public List<QdrantVectorSearchResult> searchCentroidPoints(
            List<Double> vector,
            int limit,
            double scoreThreshold
    ) {
        return searchV2(vector, limit, scoreThreshold, embeddingKindFilter("CENTROID"));
    }

    public List<QdrantVectorSearchResult> searchExpectedDogReferences(
            List<Double> vector,
            String expectedDogId,
            int limit
    ) {
        return searchV2(vector, limit, null, expectedDogEmbeddingKindFilter(expectedDogId, "REFERENCE"));
    }

    public List<QdrantVectorSearchResult> searchExpectedDogCentroid(
            List<Double> vector,
            String expectedDogId
    ) {
        return searchV2(vector, 1, null, expectedDogEmbeddingKindFilter(expectedDogId, "CENTROID"));
    }

    @SuppressWarnings("unchecked")
    private List<QdrantSearchResult> search(
            List<Double> vector,
            int limit,
            Double scoreThreshold,
            Map<String, Object> filter
    ) {
        Map<String, Object> request = new LinkedHashMap<>();
        request.put("vector", vector);
        request.put("limit", Math.max(1, limit));
        if (scoreThreshold != null) {
            request.put("score_threshold", scoreThreshold);
        }
        request.put("with_payload", true);
        request.put("filter", filter);

        Map<String, Object> response;
        try {
            response = webClient.post()
                    .uri("/collections/{collection}/points/search", collection)
                    .contentType(MediaType.APPLICATION_JSON)
                    .bodyValue(request)
                    .retrieve()
                    .bodyToMono(Map.class)
                    .block(Duration.ofMillis(searchTimeoutMs));
        } catch (WebClientResponseException e) {
            throw new QdrantClientException(
                    "Qdrant search 실패: status=%d body=%s".formatted(e.getStatusCode().value(), e.getResponseBodyAsString()),
                    QdrantOperation.SEARCH,
                    e.getStatusCode().value(),
                    e.getResponseBodyAsString(),
                    e
            );
        } catch (Exception e) {
            throw new QdrantClientException(
                    "Qdrant search 실패: " + e.getMessage(),
                    QdrantOperation.SEARCH,
                    null,
                    null,
                    e
            );
        }

        if (response == null || response.get("result") == null) {
            throw new QdrantClientException("Qdrant search 응답이 비어 있습니다.", QdrantOperation.SEARCH, null, null, null);
        }

        List<Map<String, Object>> points = (List<Map<String, Object>>) response.get("result");
        List<QdrantSearchResult> results = new ArrayList<>();
        for (Map<String, Object> point : points) {
            Number scoreNumber = (Number) point.get("score");
            double score = scoreNumber == null ? 0.0 : scoreNumber.doubleValue();
            String pointId = String.valueOf(point.get("id"));

            Map<String, Object> payload = (Map<String, Object>) point.get("payload");
            String dogId = payload == null ? pointId : String.valueOf(payload.getOrDefault("dog_id", pointId));
            String breed = payload == null ? null : valueOrNull(payload.get("breed"));
            String noseImagePath = payload == null ? null : valueOrNull(payload.get("nose_image_path"));

            results.add(new QdrantSearchResult(pointId, dogId, score, breed, noseImagePath));
        }
        return results;
    }

    @SuppressWarnings("unchecked")
    private List<QdrantVectorSearchResult> searchV2(
            List<Double> vector,
            int limit,
            Double scoreThreshold,
            Map<String, Object> filter
    ) {
        Map<String, Object> request = new LinkedHashMap<>();
        request.put("vector", vector);
        request.put("limit", Math.max(1, limit));
        if (scoreThreshold != null) {
            request.put("score_threshold", scoreThreshold);
        }
        request.put("with_payload", true);
        request.put("filter", filter);

        Map<String, Object> response;
        try {
            response = webClient.post()
                    .uri("/collections/{collection}/points/search", collection)
                    .contentType(MediaType.APPLICATION_JSON)
                    .bodyValue(request)
                    .retrieve()
                    .bodyToMono(Map.class)
                    .block(Duration.ofMillis(searchTimeoutMs));
        } catch (WebClientResponseException e) {
            throw new QdrantClientException(
                    "Qdrant search 실패: status=%d body=%s".formatted(e.getStatusCode().value(), e.getResponseBodyAsString()),
                    QdrantOperation.SEARCH,
                    e.getStatusCode().value(),
                    e.getResponseBodyAsString(),
                    e
            );
        } catch (Exception e) {
            throw new QdrantClientException(
                    "Qdrant search 실패: " + e.getMessage(),
                    QdrantOperation.SEARCH,
                    null,
                    null,
                    e
            );
        }

        if (response == null || response.get("result") == null) {
            throw new QdrantClientException("Qdrant search 응답이 비어 있습니다.", QdrantOperation.SEARCH, null, null, null);
        }

        List<Map<String, Object>> points = (List<Map<String, Object>>) response.get("result");
        List<QdrantVectorSearchResult> results = new ArrayList<>();
        for (Map<String, Object> point : points) {
            Map<String, Object> payload = (Map<String, Object>) point.get("payload");
            String dogId = payload == null ? null : valueOrNull(payload.get("dog_id"));
            if (dogId == null || dogId.isBlank()) {
                continue;
            }

            double score = doubleOrDefault(point.get("score"), 0.0);
            String pointId = String.valueOf(point.get("id"));

            results.add(new QdrantVectorSearchResult(
                    pointId,
                    dogId,
                    score,
                    valueOrNull(payload.get("embedding_kind")),
                    longOrNull(payload.get("dog_image_id")),
                    integerOrNull(payload.get("reference_index")),
                    valueOrNull(payload.get("model")),
                    integerOrNull(payload.get("dimension")),
                    valueOrNull(payload.get("preprocess_version"))
            ));
        }
        return results;
    }

    private Map<String, Object> activeOnlyFilter() {
        return Map.of("must", List.of(matchCondition("is_active", true)));
    }

    private Map<String, Object> expectedDogFilter(String expectedDogId) {
        return Map.of("must", List.of(
                matchCondition("is_active", true),
                matchCondition("dog_id", expectedDogId)
        ));
    }

    private Map<String, Object> embeddingKindFilter(String embeddingKind) {
        return Map.of("must", List.of(
                matchCondition("is_active", true),
                matchCondition("embedding_kind", embeddingKind)
        ));
    }

    private Map<String, Object> expectedDogEmbeddingKindFilter(String expectedDogId, String embeddingKind) {
        return Map.of("must", List.of(
                matchCondition("is_active", true),
                matchCondition("embedding_kind", embeddingKind),
                matchCondition("dog_id", expectedDogId)
        ));
    }

    private Map<String, Object> matchCondition(String key, Object value) {
        return Map.of(
                "key", key,
                "match", Map.of("value", value)
        );
    }

    public void upsert(String pointId, List<Double> vector, Map<String, Object> payload) {
        Map<String, Object> point = new LinkedHashMap<>();
        point.put("id", pointId);
        point.put("vector", vector);
        point.put("payload", payload);

        Map<String, Object> request = Map.of("points", List.of(point));

        try {
            webClient.put()
                    .uri("/collections/{collection}/points?wait=true", collection)
                    .contentType(MediaType.APPLICATION_JSON)
                    .bodyValue(request)
                    .retrieve()
                    .toBodilessEntity()
                    .block(Duration.ofMillis(upsertTimeoutMs));
        } catch (WebClientResponseException e) {
            throw new QdrantClientException(
                    "Qdrant upsert 실패: status=%d body=%s".formatted(e.getStatusCode().value(), e.getResponseBodyAsString()),
                    QdrantOperation.UPSERT,
                    e.getStatusCode().value(),
                    e.getResponseBodyAsString(),
                    e
            );
        } catch (Exception e) {
            throw new QdrantClientException(
                    "Qdrant upsert 실패: " + e.getMessage(),
                    QdrantOperation.UPSERT,
                    null,
                    null,
                    e
            );
        }
    }

    public void upsertAll(List<QdrantPointUpsertRequest> points) {
        if (points == null || points.isEmpty()) {
            throw new IllegalArgumentException("Qdrant upsert points must not be empty.");
        }

        List<Map<String, Object>> requestPoints = new ArrayList<>();
        for (QdrantPointUpsertRequest point : points) {
            validatePointUpsertRequest(point);

            Map<String, Object> requestPoint = new LinkedHashMap<>();
            requestPoint.put("id", point.pointId());
            requestPoint.put("vector", point.vector());
            requestPoint.put("payload", point.payload());
            requestPoints.add(requestPoint);
        }

        Map<String, Object> request = Map.of("points", requestPoints);

        try {
            webClient.put()
                    .uri("/collections/{collection}/points?wait=true", collection)
                    .contentType(MediaType.APPLICATION_JSON)
                    .bodyValue(request)
                    .retrieve()
                    .toBodilessEntity()
                    .block(Duration.ofMillis(upsertTimeoutMs));
        } catch (WebClientResponseException e) {
            throw new QdrantClientException(
                    "Qdrant upsert 실패: status=%d body=%s".formatted(e.getStatusCode().value(), e.getResponseBodyAsString()),
                    QdrantOperation.UPSERT,
                    e.getStatusCode().value(),
                    e.getResponseBodyAsString(),
                    e
            );
        } catch (Exception e) {
            throw new QdrantClientException(
                    "Qdrant upsert 실패: " + e.getMessage(),
                    QdrantOperation.UPSERT,
                    null,
                    null,
                    e
            );
        }
    }

    public void deletePoints(List<String> pointIds) {
        if (pointIds == null || pointIds.isEmpty()) {
            return;
        }
        for (String pointId : pointIds) {
            if (pointId == null || pointId.isBlank()) {
                throw new IllegalArgumentException("Qdrant delete point id must not be blank.");
            }
        }

        Map<String, Object> request = Map.of("points", pointIds);

        try {
            webClient.post()
                    .uri("/collections/{collection}/points/delete?wait=true", collection)
                    .contentType(MediaType.APPLICATION_JSON)
                    .bodyValue(request)
                    .retrieve()
                    .toBodilessEntity()
                    .block(Duration.ofMillis(upsertTimeoutMs));
        } catch (WebClientResponseException e) {
            throw new QdrantClientException(
                    "Qdrant delete 실패: status=%d body=%s".formatted(e.getStatusCode().value(), e.getResponseBodyAsString()),
                    QdrantOperation.DELETE,
                    e.getStatusCode().value(),
                    e.getResponseBodyAsString(),
                    e
            );
        } catch (Exception e) {
            throw new QdrantClientException(
                    "Qdrant delete 실패: " + e.getMessage(),
                    QdrantOperation.DELETE,
                    null,
                    null,
                    e
            );
        }
    }

    private static void validatePointUpsertRequest(QdrantPointUpsertRequest point) {
        if (point == null) {
            throw new IllegalArgumentException("Qdrant upsert point must not be null.");
        }
        if (point.pointId() == null || point.pointId().isBlank()) {
            throw new IllegalArgumentException("Qdrant upsert point id must not be blank.");
        }
        if (point.vector() == null || point.vector().isEmpty()) {
            throw new IllegalArgumentException("Qdrant upsert vector must not be empty.");
        }
        if (point.payload() == null) {
            throw new IllegalArgumentException("Qdrant upsert payload must not be null.");
        }
    }

    private static String valueOrNull(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static double doubleOrDefault(Object value, double defaultValue) {
        if (value instanceof Number number) {
            return number.doubleValue();
        }
        if (value instanceof String text) {
            try {
                return Double.parseDouble(text);
            } catch (NumberFormatException ignored) {
                return defaultValue;
            }
        }
        return defaultValue;
    }

    private static Long longOrNull(Object value) {
        if (value instanceof Number number) {
            return number.longValue();
        }
        if (value instanceof String text && !text.isBlank()) {
            try {
                return Long.parseLong(text);
            } catch (NumberFormatException ignored) {
                return null;
            }
        }
        return null;
    }

    private static Integer integerOrNull(Object value) {
        if (value instanceof Number number) {
            return number.intValue();
        }
        if (value instanceof String text && !text.isBlank()) {
            try {
                return Integer.parseInt(text);
            } catch (NumberFormatException ignored) {
                return null;
            }
        }
        return null;
    }

    public record QdrantPointUpsertRequest(
            String pointId,
            List<Double> vector,
            Map<String, Object> payload
    ) {}

    public record QdrantVectorSearchResult(
            String pointId,
            String dogId,
            double score,
            String embeddingKind,
            Long dogImageId,
            Integer referenceIndex,
            String model,
            Integer dimension,
            String preprocessVersion
    ) {}

    public enum QdrantOperation {
        SEARCH,
        UPSERT,
        DELETE
    }

    public static class QdrantClientException extends RuntimeException {
        private final QdrantOperation operation;
        private final Integer upstreamStatus;
        private final String upstreamBody;

        public QdrantClientException(
                String message,
                QdrantOperation operation,
                Integer upstreamStatus,
                String upstreamBody,
                Throwable cause
        ) {
            super(message, cause);
            this.operation = operation;
            this.upstreamStatus = upstreamStatus;
            this.upstreamBody = upstreamBody;
        }

        public QdrantOperation getOperation() {
            return operation;
        }

        public Integer getUpstreamStatus() {
            return upstreamStatus;
        }

        public String getUpstreamBody() {
            return upstreamBody;
        }
    }
}
