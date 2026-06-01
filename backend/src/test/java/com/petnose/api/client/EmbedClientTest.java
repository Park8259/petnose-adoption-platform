package com.petnose.api.client;

import com.sun.net.httpserver.HttpServer;
import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.Test;
import org.springframework.http.MediaType;
import org.springframework.web.reactive.function.client.WebClient;

import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.concurrent.atomic.AtomicReference;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;

class EmbedClientTest {

    private HttpServer server;

    @AfterEach
    void tearDown() {
        if (server != null) {
            server.stop(0);
        }
    }

    @Test
    void embedBatchSendsRepeatedImagesAndParsesResponse() throws Exception {
        AtomicReference<String> requestBody = new AtomicReference<>();
        AtomicReference<String> requestContentType = new AtomicReference<>();
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/embed-batch", exchange -> {
            requestContentType.set(exchange.getRequestHeaders().getFirst("Content-Type"));
            requestBody.set(new String(exchange.getRequestBody().readAllBytes(), StandardCharsets.ISO_8859_1));
            byte[] response = """
                    {"status":"ok","model":"dog-nose-identification2:s101_224","dimension":3,"count":2,"items":[{"index":0,"filename":"nose-front.jpg","vector":[0.1,0.2,0.3]},{"index":1,"filename":"nose-left.jpg","vector":[0.4,0.5,0.6]}]}
                    """.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, response.length);
            exchange.getResponseBody().write(response);
            exchange.close();
        });
        server.start();

        EmbedClient client = new EmbedClient(WebClient.builder()
                .baseUrl("http://127.0.0.1:" + server.getAddress().getPort())
                .build());

        EmbedClient.BatchEmbedResponse response = client.embedBatch(List.of(
                new EmbedClient.BatchImageInput(new byte[]{1, 2, 3}, "nose-front.jpg", MediaType.IMAGE_JPEG_VALUE),
                new EmbedClient.BatchImageInput(new byte[]{4, 5, 6}, "nose-left.jpg", MediaType.IMAGE_JPEG_VALUE)
        ));

        assertThat(requestContentType.get()).startsWith("multipart/form-data");
        assertThat(countOccurrences(requestBody.get(), "name=\"images\"")).isEqualTo(2);
        assertThat(requestBody.get()).contains("filename=\"nose-front.jpg\"", "filename=\"nose-left.jpg\"");
        assertThat(response.dimension()).isEqualTo(3);
        assertThat(response.model()).isEqualTo("dog-nose-identification2:s101_224");
        assertThat(response.items()).hasSize(2);
        assertThat(response.items().getFirst().index()).isZero();
        assertThat(response.items().getFirst().vector()).containsExactly(0.1, 0.2, 0.3);
    }

    @Test
    void embedBatchRejectsEmptyRequest() {
        EmbedClient client = new EmbedClient(WebClient.builder().baseUrl("http://127.0.0.1:1").build());

        assertThatThrownBy(() -> client.embedBatch(List.of()))
                .isInstanceOf(EmbedClient.EmbedClientException.class);
    }

    @Test
    void embedBatchRejectsCountMismatch() throws Exception {
        EmbedClient client = startEmbedServerWithResponse("""
                {"status":"ok","model":"dog-nose-identification2:s101_224","dimension":2,"count":2,"items":[{"index":0,"filename":"nose.jpg","vector":[0.1,0.2]}]}
                """);

        assertThatThrownBy(() -> client.embedBatch(List.of(
                new EmbedClient.BatchImageInput(new byte[]{1}, "nose.jpg", MediaType.IMAGE_JPEG_VALUE)
        )))
                .isInstanceOf(EmbedClient.EmbedClientException.class)
                .hasMessageContaining("count");
    }

    @Test
    void embedBatchRejectsMissingItems() throws Exception {
        EmbedClient client = startEmbedServerWithResponse("""
                {"status":"ok","model":"dog-nose-identification2:s101_224","dimension":2,"count":1}
                """);

        assertThatThrownBy(() -> client.embedBatch(List.of(
                new EmbedClient.BatchImageInput(new byte[]{1}, "nose.jpg", MediaType.IMAGE_JPEG_VALUE)
        )))
                .isInstanceOf(EmbedClient.EmbedClientException.class)
                .hasMessageContaining("items");
    }

    private EmbedClient startEmbedServerWithResponse(String responseJson) throws Exception {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/embed-batch", exchange -> {
            exchange.getRequestBody().readAllBytes();
            byte[] response = responseJson.getBytes(StandardCharsets.UTF_8);
            exchange.getResponseHeaders().add("Content-Type", "application/json");
            exchange.sendResponseHeaders(200, response.length);
            exchange.getResponseBody().write(response);
            exchange.close();
        });
        server.start();
        return new EmbedClient(WebClient.builder()
                .baseUrl("http://127.0.0.1:" + server.getAddress().getPort())
                .build());
    }

    private static int countOccurrences(String value, String needle) {
        int count = 0;
        int offset = 0;
        while ((offset = value.indexOf(needle, offset)) >= 0) {
            count++;
            offset += needle.length();
        }
        return count;
    }
}
