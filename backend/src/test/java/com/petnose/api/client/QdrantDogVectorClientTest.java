package com.petnose.api.client;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.petnose.api.dto.registration.QdrantSearchResult;
import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.web.reactive.function.client.WebClient;

import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;

class QdrantDogVectorClientTest {

    private final ObjectMapper objectMapper = new ObjectMapper();
    private HttpServer server;

    @AfterEach
    void tearDown() {
        if (server != null) {
            server.stop(0);
        }
    }

    @Test
    void defaultSearchSendsConfiguredScoreThreshold() throws Exception {
        AtomicReference<String> requestBody = new AtomicReference<>();
        AtomicReference<String> requestMethod = new AtomicReference<>();
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/collections/test_collection/points/search", exchange -> {
            requestMethod.set(exchange.getRequestMethod());
            requestBody.set(new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8));
            byte[] response = """
                    {"result":[{"id":"point-1","score":0.71,"payload":{"dog_id":"dog-1","breed":"Jindo","nose_image_path":"dogs/dog-1/nose.jpg"}}]}
                    """.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, response.length);
            exchange.getResponseBody().write(response);
            exchange.close();
        });
        server.start();

        QdrantDogVectorClient client = new QdrantDogVectorClient(
                WebClient.builder(),
                "127.0.0.1",
                server.getAddress().getPort(),
                "test_collection",
                5,
                0.70,
                3000,
                3000
        );

        List<QdrantSearchResult> results = client.search(List.of(0.1, 0.2, 0.3));

        JsonNode request = objectMapper.readTree(requestBody.get());
        assertThat(requestMethod.get()).isEqualTo("POST");
        assertThat(request.get("score_threshold").asDouble()).isEqualTo(0.70);
        assertThat(request.get("limit").asInt()).isEqualTo(5);
        assertThat(results).hasSize(1);
        assertThat(results.getFirst().score()).isEqualTo(0.71);
        assertThat(results.getFirst().dogId()).isEqualTo("dog-1");
    }

    @Test
    void expectedDogSearchFiltersToExpectedDogWithoutScoreThreshold() throws Exception {
        AtomicReference<String> requestBody = new AtomicReference<>();
        AtomicReference<String> requestMethod = new AtomicReference<>();
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/collections/test_collection/points/search", exchange -> {
            requestMethod.set(exchange.getRequestMethod());
            requestBody.set(new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8));
            byte[] response = """
                    {"result":[{"id":"expected-dog","score":0.80630887,"payload":{"dog_id":"expected-dog","breed":"Maltese","nose_image_path":"dogs/expected-dog/nose.jpg"}}]}
                    """.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, response.length);
            exchange.getResponseBody().write(response);
            exchange.close();
        });
        server.start();

        QdrantDogVectorClient client = new QdrantDogVectorClient(
                WebClient.builder(),
                "127.0.0.1",
                server.getAddress().getPort(),
                "test_collection",
                5,
                0.70,
                3000,
                3000
        );

        List<QdrantSearchResult> results = client.searchExpectedDog(List.of(0.1, 0.2, 0.3), "expected-dog");

        JsonNode request = objectMapper.readTree(requestBody.get());
        assertThat(requestMethod.get()).isEqualTo("POST");
        assertThat(request.get("vector").size()).isEqualTo(3);
        assertThat(request.get("vector").get(0).asDouble()).isEqualTo(0.1);
        assertThat(request.get("limit").asInt()).isEqualTo(1);
        assertThat(request.get("with_payload").asBoolean()).isTrue();
        assertThat(request.has("score_threshold")).isFalse();
        JsonNode must = request.path("filter").path("must");
        assertThat(must.size()).isEqualTo(2);
        assertThat(hasBooleanMatch(must, "is_active", true)).isTrue();
        assertThat(hasTextMatch(must, "dog_id", "expected-dog")).isTrue();

        assertThat(results).hasSize(1);
        assertThat(results.getFirst().pointId()).isEqualTo("expected-dog");
        assertThat(results.getFirst().dogId()).isEqualTo("expected-dog");
        assertThat(results.getFirst().score()).isEqualTo(0.80630887);
    }

    @Test
    void upsertAllSendsBatchPointsRequest() throws Exception {
        AtomicReference<String> requestBody = new AtomicReference<>();
        AtomicReference<String> requestMethod = new AtomicReference<>();
        AtomicReference<String> requestQuery = new AtomicReference<>();
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/collections/test_collection/points", exchange -> {
            requestMethod.set(exchange.getRequestMethod());
            requestQuery.set(exchange.getRequestURI().getQuery());
            requestBody.set(new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8));
            byte[] response = "{}".getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, response.length);
            exchange.getResponseBody().write(response);
            exchange.close();
        });
        server.start();

        QdrantDogVectorClient client = newClient();

        client.upsertAll(List.of(new QdrantDogVectorClient.QdrantPointUpsertRequest(
                "point-uuid",
                List.of(0.1, 0.2, 0.3),
                Map.of(
                        "dog_id", "dog-uuid",
                        "embedding_kind", "REFERENCE",
                        "reference_index", 1,
                        "dog_image_id", 101,
                        "model", "dog-nose-identification2:s101_224",
                        "dimension", 2048,
                        "preprocess_version", "rgb_resize224_bicubic_imagenet_l2_v1",
                        "is_active", true
                )
        )));

        JsonNode request = objectMapper.readTree(requestBody.get());
        assertThat(requestMethod.get()).isEqualTo("PUT");
        assertThat(requestQuery.get()).isEqualTo("wait=true");
        assertThat(request.path("points")).hasSize(1);
        JsonNode point = request.path("points").get(0);
        assertThat(point.path("id").asText()).isEqualTo("point-uuid");
        assertThat(point.path("vector")).hasSize(3);
        assertThat(point.path("payload").path("dog_id").asText()).isEqualTo("dog-uuid");
        assertThat(point.path("payload").path("embedding_kind").asText()).isEqualTo("REFERENCE");
        assertThat(point.path("payload").path("is_active").asBoolean()).isTrue();
    }

    @Test
    void searchReferencePointsSendsReferenceFilterAndParsesV2Payload() throws Exception {
        AtomicReference<String> requestBody = new AtomicReference<>();
        AtomicReference<String> requestMethod = new AtomicReference<>();
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/collections/test_collection/points/search", exchange -> {
            requestMethod.set(exchange.getRequestMethod());
            requestBody.set(new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8));
            byte[] response = """
                    {"result":[{"id":"point-1","score":0.91,"payload":{"dog_id":"dog-1","embedding_kind":"REFERENCE","dog_image_id":101,"reference_index":2,"model":"dog-nose-identification2:s101_224","dimension":2048,"preprocess_version":"rgb_resize224_bicubic_imagenet_l2_v1"}},{"id":"point-without-dog","score":0.80,"payload":{"embedding_kind":"REFERENCE"}}]}
                    """.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, response.length);
            exchange.getResponseBody().write(response);
            exchange.close();
        });
        server.start();

        QdrantDogVectorClient client = newClient();

        List<QdrantDogVectorClient.QdrantVectorSearchResult> results =
                client.searchReferencePoints(List.of(0.1, 0.2, 0.3), 10, 0.82);

        JsonNode request = objectMapper.readTree(requestBody.get());
        assertThat(requestMethod.get()).isEqualTo("POST");
        assertThat(request.get("limit").asInt()).isEqualTo(10);
        assertThat(request.get("score_threshold").asDouble()).isEqualTo(0.82);
        JsonNode must = request.path("filter").path("must");
        assertThat(must.size()).isEqualTo(2);
        assertThat(hasBooleanMatch(must, "is_active", true)).isTrue();
        assertThat(hasTextMatch(must, "embedding_kind", "REFERENCE")).isTrue();

        assertThat(results).hasSize(1);
        QdrantDogVectorClient.QdrantVectorSearchResult result = results.getFirst();
        assertThat(result.pointId()).isEqualTo("point-1");
        assertThat(result.dogId()).isEqualTo("dog-1");
        assertThat(result.score()).isEqualTo(0.91);
        assertThat(result.embeddingKind()).isEqualTo("REFERENCE");
        assertThat(result.dogImageId()).isEqualTo(101L);
        assertThat(result.referenceIndex()).isEqualTo(2);
        assertThat(result.model()).isEqualTo("dog-nose-identification2:s101_224");
        assertThat(result.dimension()).isEqualTo(2048);
        assertThat(result.preprocessVersion()).isEqualTo("rgb_resize224_bicubic_imagenet_l2_v1");
    }

    @Test
    void searchExpectedDogReferencesSendsDogAndReferenceFilter() throws Exception {
        AtomicReference<String> requestBody = new AtomicReference<>();
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/collections/test_collection/points/search", exchange -> {
            requestBody.set(new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8));
            byte[] response = "{\"result\":[]}".getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, response.length);
            exchange.getResponseBody().write(response);
            exchange.close();
        });
        server.start();

        QdrantDogVectorClient client = newClient();

        List<QdrantDogVectorClient.QdrantVectorSearchResult> results =
                client.searchExpectedDogReferences(List.of(0.1, 0.2, 0.3), "expected-dog", 4);

        JsonNode request = objectMapper.readTree(requestBody.get());
        assertThat(request.get("limit").asInt()).isEqualTo(4);
        assertThat(request.has("score_threshold")).isFalse();
        JsonNode must = request.path("filter").path("must");
        assertThat(must.size()).isEqualTo(3);
        assertThat(hasBooleanMatch(must, "is_active", true)).isTrue();
        assertThat(hasTextMatch(must, "embedding_kind", "REFERENCE")).isTrue();
        assertThat(hasTextMatch(must, "dog_id", "expected-dog")).isTrue();
        assertThat(results).isEmpty();
    }

    @Test
    void deletePointsSendsPointIdsRequest() throws Exception {
        AtomicReference<String> requestBody = new AtomicReference<>();
        AtomicReference<String> requestMethod = new AtomicReference<>();
        AtomicReference<String> requestQuery = new AtomicReference<>();
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/collections/test_collection/points/delete", exchange -> {
            requestMethod.set(exchange.getRequestMethod());
            requestQuery.set(exchange.getRequestURI().getQuery());
            requestBody.set(new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.UTF_8));
            byte[] response = "{}".getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, response.length);
            exchange.getResponseBody().write(response);
            exchange.close();
        });
        server.start();

        QdrantDogVectorClient client = newClient();

        client.deletePoints(List.of("point-id-1", "point-id-2"));

        JsonNode request = objectMapper.readTree(requestBody.get());
        assertThat(requestMethod.get()).isEqualTo("POST");
        assertThat(requestQuery.get()).isEqualTo("wait=true");
        assertThat(request.path("points")).hasSize(2);
        assertThat(request.path("points").get(0).asText()).isEqualTo("point-id-1");
        assertThat(request.path("points").get(1).asText()).isEqualTo("point-id-2");
    }

    private QdrantDogVectorClient newClient() {
        return new QdrantDogVectorClient(
                WebClient.builder(),
                "127.0.0.1",
                server.getAddress().getPort(),
                "test_collection",
                5,
                0.70,
                3000,
                3000
        );
    }

    private static boolean hasBooleanMatch(JsonNode conditions, String key, boolean value) {
        for (JsonNode condition : conditions) {
            if (key.equals(condition.path("key").asText())
                    && condition.path("match").path("value").isBoolean()
                    && condition.path("match").path("value").asBoolean() == value) {
                return true;
            }
        }
        return false;
    }

    private static boolean hasTextMatch(JsonNode conditions, String key, String value) {
        for (JsonNode condition : conditions) {
            if (key.equals(condition.path("key").asText())
                    && value.equals(condition.path("match").path("value").asText())) {
                return true;
            }
        }
        return false;
    }
}
