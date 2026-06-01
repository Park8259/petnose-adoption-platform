package com.petnose.api.client;

import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Qualifier;
import org.springframework.core.io.ByteArrayResource;
import org.springframework.http.MediaType;
import org.springframework.http.client.MultipartBodyBuilder;
import org.springframework.stereotype.Component;
import org.springframework.web.reactive.function.BodyInserters;
import org.springframework.web.reactive.function.client.WebClient;
import org.springframework.web.reactive.function.client.WebClientResponseException;

import java.util.ArrayList;
import java.util.List;
import java.util.Map;

/**
 * Python embed service 호출 클라이언트.
 * Spring Boot가 이 클라이언트를 통해서만 python-embed를 호출합니다.
 */
@Slf4j
@Component
public class EmbedClient {

    private final WebClient webClient;

    public EmbedClient(@Qualifier("embedWebClient") WebClient webClient) {
        this.webClient = webClient;
    }

    /**
     * 비문 이미지 바이트를 전송하고 임베딩 벡터를 반환합니다.
     *
     * @param imageBytes 이미지 파일 바이트
     * @param filename   원본 파일명 (확장자 포함)
     * @return EmbedResponse (vector, dimension, model)
     */
    public EmbedResponse embed(byte[] imageBytes, String filename) {
        return embed(imageBytes, filename, MediaType.IMAGE_PNG_VALUE);
    }

    /**
     * 비문 이미지 바이트를 multipart/form-data(image 파트)로 전송합니다.
     */
    @SuppressWarnings("unchecked")
    public EmbedResponse embed(byte[] imageBytes, String filename, String contentType) {
        MultipartBodyBuilder builder = new MultipartBodyBuilder();
        MultipartBodyBuilder.PartBuilder imagePart = builder.part("image", new ByteArrayResource(imageBytes) {
            @Override
            public String getFilename() {
                return filename;
            }
        });
        imagePart.filename(filename);
        imagePart.contentType(MediaType.parseMediaType(contentType));

        Map<String, Object> response;
        try {
            response = webClient.post()
                    .uri("/embed")
                    .contentType(MediaType.MULTIPART_FORM_DATA)
                    .body(BodyInserters.fromMultipartData(builder.build()))
                    .retrieve()
                    .bodyToMono(Map.class)
                    .block();
        } catch (WebClientResponseException e) {
            throw new EmbedClientException(
                    "embed service 호출 실패: status=%d body=%s".formatted(
                            e.getStatusCode().value(),
                            e.getResponseBodyAsString()
                    ),
                    e.getStatusCode().value(),
                    e.getResponseBodyAsString(),
                    e
            );
        } catch (Exception e) {
            throw new EmbedClientException("embed service 호출 실패: " + e.getMessage(), null, null, e);
        }

        if (response == null) {
            throw new RuntimeException("embed service 응답이 null입니다.");
        }

        String status = (String) response.get("status");
        if (status == null || !"ok".equalsIgnoreCase(status)) {
            throw new EmbedClientException("embed service 응답 status가 비정상입니다.", null, String.valueOf(response), null);
        }

        List<Number> vectorNumbers = (List<Number>) response.get("vector");
        if (vectorNumbers == null || vectorNumbers.isEmpty()) {
            throw new EmbedClientException("embed service 응답에 vector 필드가 없습니다.", null, String.valueOf(response), null);
        }
        List<Double> vector = vectorNumbers.stream().map(Number::doubleValue).toList();

        Object dimensionObj = response.get("dimension");
        if (!(dimensionObj instanceof Number number)) {
            throw new EmbedClientException("embed service 응답의 dimension 필드가 숫자가 아닙니다.", null, String.valueOf(response), null);
        }
        int dimension = number.intValue();

        String model = (String) response.get("model");
        if (model == null || model.isBlank()) {
            throw new EmbedClientException("embed service 응답에 model 필드가 없습니다.", null, String.valueOf(response), null);
        }

        log.debug("[EmbedClient] 임베딩 완료: status={}, dimension={}, model={}", status, dimension, model);
        return new EmbedResponse(vector, dimension, model);
    }

    @SuppressWarnings("unchecked")
    public BatchEmbedResponse embedBatch(List<BatchImageInput> images) {
        if (images == null || images.isEmpty()) {
            throw new EmbedClientException("embed batch 요청 이미지가 비어 있습니다.", null, null, null);
        }

        MultipartBodyBuilder builder = new MultipartBodyBuilder();
        for (BatchImageInput image : images) {
            validateBatchImageInput(image);
            MultipartBodyBuilder.PartBuilder imagePart = builder.part("images", new ByteArrayResource(image.imageBytes()) {
                @Override
                public String getFilename() {
                    return image.filename();
                }
            });
            imagePart.filename(image.filename());
            imagePart.contentType(MediaType.parseMediaType(image.contentType()));
        }

        Map<String, Object> response;
        try {
            response = webClient.post()
                    .uri("/embed-batch")
                    .contentType(MediaType.MULTIPART_FORM_DATA)
                    .body(BodyInserters.fromMultipartData(builder.build()))
                    .retrieve()
                    .bodyToMono(Map.class)
                    .block();
        } catch (WebClientResponseException e) {
            throw new EmbedClientException(
                    "embed batch service 호출 실패: status=%d body=%s".formatted(
                            e.getStatusCode().value(),
                            e.getResponseBodyAsString()
                    ),
                    e.getStatusCode().value(),
                    e.getResponseBodyAsString(),
                    e
            );
        } catch (Exception e) {
            throw new EmbedClientException("embed batch service 호출 실패: " + e.getMessage(), null, null, e);
        }

        if (response == null) {
            throw new EmbedClientException("embed batch service 응답이 null입니다.", null, null, null);
        }

        String status = valueOrNull(response.get("status"));
        if (status == null || !"ok".equalsIgnoreCase(status)) {
            throw new EmbedClientException("embed batch service 응답 status가 비정상입니다.", null, String.valueOf(response), null);
        }

        Object countObj = response.get("count");
        if (!(countObj instanceof Number countNumber)) {
            throw new EmbedClientException("embed batch service 응답의 count 필드가 숫자가 아닙니다.", null, String.valueOf(response), null);
        }

        Object dimensionObj = response.get("dimension");
        if (!(dimensionObj instanceof Number dimensionNumber)) {
            throw new EmbedClientException("embed batch service 응답의 dimension 필드가 숫자가 아닙니다.", null, String.valueOf(response), null);
        }
        int dimension = dimensionNumber.intValue();

        String model = valueOrNull(response.get("model"));
        if (model == null || model.isBlank()) {
            throw new EmbedClientException("embed batch service 응답에 model 필드가 없습니다.", null, String.valueOf(response), null);
        }

        Object itemsObj = response.get("items");
        if (!(itemsObj instanceof List<?> rawItems) || rawItems.isEmpty()) {
            throw new EmbedClientException("embed batch service 응답에 items 필드가 없습니다.", null, String.valueOf(response), null);
        }

        int count = countNumber.intValue();
        if (count != rawItems.size()) {
            throw new EmbedClientException("embed batch service 응답 count와 items 크기가 다릅니다.", null, String.valueOf(response), null);
        }

        List<BatchEmbedItem> items = new ArrayList<>();
        for (int i = 0; i < rawItems.size(); i++) {
            Object rawItem = rawItems.get(i);
            if (!(rawItem instanceof Map<?, ?> item)) {
                throw new EmbedClientException("embed batch service 응답 item 형식이 올바르지 않습니다.", null, String.valueOf(response), null);
            }

            Object indexObj = item.get("index");
            if (!(indexObj instanceof Number indexNumber) || indexNumber.intValue() != i) {
                throw new EmbedClientException("embed batch service 응답 item.index 순서가 올바르지 않습니다.", null, String.valueOf(response), null);
            }

            Object vectorObj = item.get("vector");
            if (!(vectorObj instanceof List<?> rawVector) || rawVector.isEmpty()) {
                throw new EmbedClientException("embed batch service 응답 item.vector가 비어 있습니다.", null, String.valueOf(response), null);
            }

            List<Double> vector = toVector(rawVector, response);
            if (vector.size() != dimension) {
                throw new EmbedClientException("embed batch service 응답 item.vector 크기가 dimension과 다릅니다.", null, String.valueOf(response), null);
            }

            items.add(new BatchEmbedItem(i, valueOrNull(item.get("filename")), vector));
        }

        log.debug("[EmbedClient] batch 임베딩 완료: count={}, dimension={}, model={}", count, dimension, model);
        return new BatchEmbedResponse(items, dimension, model);
    }

    /**
     * Python embed service health 확인.
     */
    public boolean isHealthy() {
        try {
            Map<?, ?> response = webClient.get()
                    .uri("/health")
                    .retrieve()
                    .bodyToMono(Map.class)
                    .block();
            return response != null && "ok".equals(response.get("status"));
        } catch (Exception e) {
            log.warn("[EmbedClient] health check 실패: {}", e.getMessage());
            return false;
        }
    }

    public record EmbedResponse(List<Double> vector, int dimension, String model) {}

    public record BatchImageInput(
            byte[] imageBytes,
            String filename,
            String contentType
    ) {}

    public record BatchEmbedItem(
            int index,
            String filename,
            List<Double> vector
    ) {}

    public record BatchEmbedResponse(
            List<BatchEmbedItem> items,
            int dimension,
            String model
    ) {}

    private static void validateBatchImageInput(BatchImageInput image) {
        if (image == null) {
            throw new EmbedClientException("embed batch 요청 이미지가 null입니다.", null, null, null);
        }
        if (image.imageBytes() == null || image.imageBytes().length == 0) {
            throw new EmbedClientException("embed batch 요청 이미지 바이트가 비어 있습니다.", null, null, null);
        }
        if (image.filename() == null || image.filename().isBlank()) {
            throw new EmbedClientException("embed batch 요청 파일명이 비어 있습니다.", null, null, null);
        }
        if (image.contentType() == null || image.contentType().isBlank()) {
            throw new EmbedClientException("embed batch 요청 contentType이 비어 있습니다.", null, null, null);
        }
    }

    private static List<Double> toVector(List<?> rawVector, Map<String, Object> response) {
        List<Double> vector = new ArrayList<>();
        for (Object value : rawVector) {
            if (!(value instanceof Number number)) {
                throw new EmbedClientException("embed batch service 응답 item.vector 값이 숫자가 아닙니다.", null, String.valueOf(response), null);
            }
            vector.add(number.doubleValue());
        }
        return vector;
    }

    private static String valueOrNull(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    public static class EmbedClientException extends RuntimeException {
        private final Integer upstreamStatus;
        private final String upstreamBody;

        public EmbedClientException(String message, Integer upstreamStatus, String upstreamBody, Throwable cause) {
            super(message, cause);
            this.upstreamStatus = upstreamStatus;
            this.upstreamBody = upstreamBody;
        }

        public Integer getUpstreamStatus() {
            return upstreamStatus;
        }

        public String getUpstreamBody() {
            return upstreamBody;
        }
    }
}
