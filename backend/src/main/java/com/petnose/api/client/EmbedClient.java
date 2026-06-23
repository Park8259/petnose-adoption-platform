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

    private static final String FACE_CHECK_PURPOSE = "face_check";

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
        return embedBatch(images, null);
    }

    @SuppressWarnings("unchecked")
    public BatchEmbedResponse embedBatch(List<BatchImageInput> images, String requestId) {
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
                    .headers(headers -> setRequestId(headers, requestId))
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

    @SuppressWarnings("unchecked")
    public Map<String, Object> extractProfileNose(byte[] imageBytes, String filename, String contentType) {
        return extractProfileNose(imageBytes, filename, contentType, null, null);
    }

    @SuppressWarnings("unchecked")
    public Map<String, Object> extractProfileNose(byte[] imageBytes, String filename, String contentType, String requestId) {
        return extractProfileNose(imageBytes, filename, contentType, null, requestId);
    }

    @SuppressWarnings("unchecked")
    public Map<String, Object> extractProfileNose(
            byte[] imageBytes,
            String filename,
            String contentType,
            String purpose,
            String requestId
    ) {
        MultipartBodyBuilder builder = new MultipartBodyBuilder();
        addMultipartFilePart(builder, "image", imageBytes, filename, contentType);
        addOptionalTextPart(builder, "purpose", purpose);
        return postMultipartForMap("/internal/nose/extract", builder, "nose extract service", requestId);
    }

    public FaceNoseEmbeddingResponse extractNoseEmbeddingFromFaceImage(
            byte[] imageBytes,
            String filename,
            String contentType,
            String requestId
    ) {
        MultipartBodyBuilder builder = new MultipartBodyBuilder();
        addMultipartFilePart(builder, "image", imageBytes, filename, contentType);
        addOptionalTextPart(builder, "purpose", FACE_CHECK_PURPOSE);
        Map<String, Object> response = postMultipartForMap(
                "/internal/nose/extract-embed",
                builder,
                "nose extract embed service",
                requestId
        );
        return parseFaceNoseEmbeddingResponse(response);
    }

    @SuppressWarnings("unchecked")
    public Map<String, Object> profileNoseMatch(
            byte[] profileImageBytes,
            String profileFilename,
            String profileContentType,
            byte[] noseImageBytes,
            String noseFilename,
            String noseContentType
    ) {
        MultipartBodyBuilder builder = new MultipartBodyBuilder();
        addMultipartFilePart(builder, "profile_image", profileImageBytes, profileFilename, profileContentType);
        addMultipartFilePart(builder, "nose_image", noseImageBytes, noseFilename, noseContentType);
        return postMultipartForMap("/internal/nose/profile-match", builder, "profile nose match service");
    }

    public ProfileNoseMatchBatchResponse profileNoseMatchBatch(
            byte[] profileImageBytes,
            String profileFilename,
            String profileContentType,
            List<BatchImageInput> noseImages
    ) {
        return profileNoseMatchBatch(profileImageBytes, profileFilename, profileContentType, noseImages, null);
    }

    public ProfileNoseMatchBatchResponse profileNoseMatchBatch(
            byte[] profileImageBytes,
            String profileFilename,
            String profileContentType,
            List<BatchImageInput> noseImages,
            String requestId
    ) {
        if (noseImages == null || noseImages.isEmpty()) {
            throw new EmbedClientException("profile nose match batch 요청 이미지가 비어 있습니다.", null, null, null);
        }

        MultipartBodyBuilder builder = new MultipartBodyBuilder();
        addMultipartFilePart(builder, "profile_image", profileImageBytes, profileFilename, profileContentType);
        for (BatchImageInput noseImage : noseImages) {
            validateBatchImageInput(noseImage);
            addMultipartFilePart(
                    builder,
                    "nose_image",
                    noseImage.imageBytes(),
                    noseImage.filename(),
                    noseImage.contentType()
            );
        }

        Map<String, Object> response = postMultipartForMap(
                "/internal/nose/profile-match-batch",
                builder,
                "profile nose match batch service",
                requestId
        );
        return parseProfileNoseMatchBatchResponse(response);
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

    public record ProfileNoseMatchBatchScore(
            int index,
            Double similarityScore,
            boolean passed
    ) {}

    public record ProfileNoseMatchBatchResponse(
            boolean matched,
            double threshold,
            boolean thresholdCalibrated,
            int passCount,
            int requiredPassCount,
            Double medianScore,
            Double meanScore,
            Double minScore,
            Double maxScore,
            boolean profileNoseExtracted,
            Double profileConfidence,
            Integer profileCropWidth,
            Integer profileCropHeight,
            String model,
            Integer dimension,
            List<ProfileNoseMatchBatchScore> scores,
            Double profileVsCentroidScore,
            Boolean profileVsCentroidPassed,
            Integer centroidDimension,
            String failureReason
    ) {}

    public record FaceNoseEmbeddingResponse(
            boolean extracted,
            Double confidence,
            List<Double> bboxXyxy,
            Integer cropWidth,
            Integer cropHeight,
            String model,
            Integer dimension,
            List<Double> embedding,
            FaceCheckQualityResponse quality,
            String failureReason
    ) {}

    public record FaceCheckQualityResponse(
            String purpose,
            boolean passed,
            Double noseAreaRatio,
            Double noseWidthRatio,
            Double noseHeightRatio,
            Double edgeMarginRatio,
            Double centerX,
            Double centerY,
            String failureReason
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

    private static void addMultipartFilePart(
            MultipartBodyBuilder builder,
            String partName,
            byte[] imageBytes,
            String filename,
            String contentType
    ) {
        if (imageBytes == null || imageBytes.length == 0) {
            throw new EmbedClientException(partName + " 이미지 바이트가 비어 있습니다.", null, null, null);
        }
        if (filename == null || filename.isBlank()) {
            throw new EmbedClientException(partName + " 파일명이 비어 있습니다.", null, null, null);
        }
        if (contentType == null || contentType.isBlank()) {
            throw new EmbedClientException(partName + " contentType이 비어 있습니다.", null, null, null);
        }

        MultipartBodyBuilder.PartBuilder imagePart = builder.part(partName, new ByteArrayResource(imageBytes) {
            @Override
            public String getFilename() {
                return filename;
            }
        });
        imagePart.filename(filename);
        imagePart.contentType(MediaType.parseMediaType(contentType));
    }

    private static void addOptionalTextPart(MultipartBodyBuilder builder, String partName, String value) {
        if (value != null && !value.isBlank()) {
            builder.part(partName, value.trim());
        }
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> postMultipartForMap(String uri, MultipartBodyBuilder builder, String operationName) {
        return postMultipartForMap(uri, builder, operationName, null);
    }

    @SuppressWarnings("unchecked")
    private Map<String, Object> postMultipartForMap(String uri, MultipartBodyBuilder builder, String operationName, String requestId) {
        Map<String, Object> response;
        try {
            response = webClient.post()
                    .uri(uri)
                    .headers(headers -> setRequestId(headers, requestId))
                    .contentType(MediaType.MULTIPART_FORM_DATA)
                    .body(BodyInserters.fromMultipartData(builder.build()))
                    .retrieve()
                    .bodyToMono(Map.class)
                    .block();
        } catch (WebClientResponseException e) {
            throw new EmbedClientException(
                    "%s 호출 실패: status=%d body=%s".formatted(
                            operationName,
                            e.getStatusCode().value(),
                            e.getResponseBodyAsString()
                    ),
                    e.getStatusCode().value(),
                    e.getResponseBodyAsString(),
                    e
            );
        } catch (Exception e) {
            throw new EmbedClientException(operationName + " 호출 실패: " + e.getMessage(), null, null, e);
        }

        if (response == null) {
            throw new EmbedClientException(operationName + " 응답이 null입니다.", null, null, null);
        }
        return response;
    }

    private static void setRequestId(org.springframework.http.HttpHeaders headers, String requestId) {
        if (requestId != null && !requestId.isBlank()) {
            headers.set("X-Request-Id", requestId.trim());
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

    private static List<Double> toVectorWithoutBody(List<?> rawVector, String fieldName) {
        List<Double> vector = new ArrayList<>();
        for (Object value : rawVector) {
            if (!(value instanceof Number number)) {
                throw new EmbedClientException("nose extract embed service 응답 %s 값이 숫자가 아닙니다.".formatted(fieldName), null, null, null);
            }
            vector.add(number.doubleValue());
        }
        return vector;
    }

    private static String valueOrNull(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static ProfileNoseMatchBatchResponse parseProfileNoseMatchBatchResponse(Map<String, Object> response) {
        Object scoresObj = response.get("scores");
        List<ProfileNoseMatchBatchScore> scores = new ArrayList<>();
        if (scoresObj instanceof List<?> rawScores) {
            for (Object rawScore : rawScores) {
                if (!(rawScore instanceof Map<?, ?> scoreMap)) {
                    throw new EmbedClientException("profile nose match batch scores 형식이 올바르지 않습니다.", null, String.valueOf(response), null);
                }
                Object indexObj = scoreMap.get("index");
                if (!(indexObj instanceof Number indexNumber)) {
                    throw new EmbedClientException("profile nose match batch score.index가 숫자가 아닙니다.", null, String.valueOf(response), null);
                }
                scores.add(new ProfileNoseMatchBatchScore(
                        indexNumber.intValue(),
                        numberAsDouble(scoreMap.get("similarity_score")),
                        booleanValue(scoreMap.get("passed"))
                ));
            }
        }

        return new ProfileNoseMatchBatchResponse(
                booleanValue(response.get("matched")),
                numberAsDouble(response.get("threshold"), 0.65),
                booleanValue(response.get("threshold_calibrated")),
                numberAsInt(response.get("pass_count"), 0),
                numberAsInt(response.get("required_pass_count"), 4),
                numberAsDouble(response.get("median_score")),
                numberAsDouble(response.get("mean_score")),
                numberAsDouble(response.get("min_score")),
                numberAsDouble(response.get("max_score")),
                booleanValue(response.get("profile_nose_extracted")),
                numberAsDouble(response.get("profile_confidence")),
                numberAsInteger(response.get("profile_crop_width")),
                numberAsInteger(response.get("profile_crop_height")),
                valueOrNull(response.get("model")),
                numberAsInteger(response.get("dimension")),
                List.copyOf(scores),
                numberAsDouble(response.get("profile_vs_centroid_score")),
                booleanObject(response.get("profile_vs_centroid_passed")),
                numberAsInteger(response.get("centroid_dimension")),
                valueOrNull(response.get("failure_reason"))
        );
    }

    private static FaceNoseEmbeddingResponse parseFaceNoseEmbeddingResponse(Map<String, Object> response) {
        List<Double> bbox = null;
        Object bboxObj = response.get("bbox_xyxy");
        if (bboxObj instanceof List<?> rawBbox) {
            bbox = toVectorWithoutBody(rawBbox, "bbox_xyxy");
        }

        List<Double> embedding = null;
        Object embeddingObj = response.get("embedding");
        if (embeddingObj instanceof List<?> rawEmbedding) {
            embedding = toVectorWithoutBody(rawEmbedding, "embedding");
        }

        return new FaceNoseEmbeddingResponse(
                booleanValue(response.get("extracted")),
                numberAsDouble(response.get("confidence")),
                bbox == null ? null : List.copyOf(bbox),
                numberAsInteger(response.get("crop_width")),
                numberAsInteger(response.get("crop_height")),
                valueOrNull(response.get("model")),
                numberAsInteger(response.get("dimension")),
                embedding == null ? null : List.copyOf(embedding),
                parseFaceCheckQualityResponse(response.get("quality")),
                valueOrNull(response.get("failure_reason"))
        );
    }

    private static FaceCheckQualityResponse parseFaceCheckQualityResponse(Object value) {
        if (!(value instanceof Map<?, ?> quality)) {
            return null;
        }
        return new FaceCheckQualityResponse(
                valueOrNull(quality.get("purpose")),
                booleanValue(quality.get("passed")),
                numberAsDouble(quality.get("nose_area_ratio")),
                numberAsDouble(quality.get("nose_width_ratio")),
                numberAsDouble(quality.get("nose_height_ratio")),
                numberAsDouble(quality.get("edge_margin_ratio")),
                numberAsDouble(quality.get("center_x")),
                numberAsDouble(quality.get("center_y")),
                valueOrNull(quality.get("failure_reason"))
        );
    }

    private static Double numberAsDouble(Object value) {
        return value instanceof Number number ? number.doubleValue() : null;
    }

    private static double numberAsDouble(Object value, double defaultValue) {
        Double parsed = numberAsDouble(value);
        return parsed == null ? defaultValue : parsed;
    }

    private static Integer numberAsInteger(Object value) {
        return value instanceof Number number ? number.intValue() : null;
    }

    private static int numberAsInt(Object value, int defaultValue) {
        Integer parsed = numberAsInteger(value);
        return parsed == null ? defaultValue : parsed;
    }

    private static boolean booleanValue(Object value) {
        return value instanceof Boolean bool && bool;
    }

    private static Boolean booleanObject(Object value) {
        return value instanceof Boolean bool ? bool : null;
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
