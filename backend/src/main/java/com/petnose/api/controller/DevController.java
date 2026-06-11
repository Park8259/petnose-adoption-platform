package com.petnose.api.controller;

import com.petnose.api.client.EmbedClient;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Profile;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.time.Instant;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.Map;

/**
 * [DEV ONLY] 개발 및 연결 검증용 엔드포인트.
 * 이 컨트롤러는 도메인 로직과 무관하며, 연결 상태 확인 목적으로만 사용합니다.
 * dev 프로파일에서만 활성화됩니다. test/prod 환경에는 로드되지 않습니다.
 */
@Profile("dev")
@Slf4j
@RestController
@RequestMapping("/api/dev")
@RequiredArgsConstructor
public class DevController {

    // 1x1 PNG (투명) — /api/dev/embed-sample 무바디 호출 시 사용
    private static final byte[] DEV_SAMPLE_PNG = Base64.getDecoder().decode(
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7+9kAAAAAASUVORK5CYII="
    );

    private final EmbedClient embedClient;

    @Value("${spring.application.name:petnose-api}")
    private String appName;

    @Value("${qdrant.host}")
    private String qdrantHost;

    @Value("${qdrant.port}")
    private int qdrantPort;

    @Value("${qdrant.collection}")
    private String qdrantCollection;

    @Value("${qdrant.vector-dimension}")
    private int qdrantVectorDimension;

    @Value("${qdrant.distance:Cosine}")
    private String qdrantDistance;

    /** Spring Boot 기동 확인용 ping */
    @GetMapping("/ping")
    public Map<String, Object> ping() {
        return Map.of(
                "status", "ok",
                "service", appName,
                "timestamp", Instant.now().toString()
        );
    }

    /** Python embed service 연결 확인 */
    @GetMapping("/embed-ping")
    public Map<String, Object> embedPing() {
        boolean healthy = embedClient.isHealthy();
        return Map.of(
                "embed_service_healthy", healthy,
                "timestamp", Instant.now().toString()
        );
    }

    /**
     * 이미지 업로드 후 embed service 호출 테스트.
     * body가 없으면 내부 샘플 PNG를 사용합니다.
     */
    @PostMapping("/embed-sample")
    public ResponseEntity<Map<String, Object>> embedSample(
            @RequestParam(value = "image", required = false) MultipartFile image
    ) {
        try {
            byte[] bytes;
            String filename;
            String contentType;
            String source;

            if (image == null || image.isEmpty()) {
                bytes = DEV_SAMPLE_PNG;
                filename = "dev-sample.png";
                contentType = "image/png";
                source = "internal_sample";
            } else {
                bytes = image.getBytes();
                filename = image.getOriginalFilename() == null ? "upload.png" : image.getOriginalFilename();
                contentType = image.getContentType() == null ? "image/png" : image.getContentType();
                source = "client_upload";
            }

            EmbedClient.EmbedResponse response = embedClient.embed(bytes, filename, contentType);

            Map<String, Object> body = new LinkedHashMap<>();
            body.put("status", "ok");
            body.put("source", source);
            body.put("filename", filename);
            body.put("content_type", contentType);
            body.put("model", response.model());
            body.put("dimension", response.dimension());
            body.put("vector_length", response.vector().size());
            body.put("vector_preview", response.vector().subList(0, Math.min(5, response.vector().size())));

            return ResponseEntity.ok(body);
        } catch (EmbedClient.EmbedClientException e) {
            log.error("[DevController] embed-sample 실패: status={}, body={}, message={}",
                    e.getUpstreamStatus(), e.getUpstreamBody(), e.getMessage(), e);

            Map<String, Object> errorBody = new LinkedHashMap<>();
            errorBody.put("status", "embed_call_failed");
            errorBody.put("error_message", e.getMessage());
            errorBody.put("upstream_status", e.getUpstreamStatus());
            errorBody.put("upstream_body", e.getUpstreamBody());
            errorBody.put("timestamp", Instant.now().toString());
            return ResponseEntity.status(HttpStatus.BAD_GATEWAY).body(errorBody);
        } catch (IOException e) {
            log.error("[DevController] embed-sample 입력 처리 실패: {}", e.getMessage(), e);
            return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(Map.of(
                    "status", "invalid_input",
                    "error_message", e.getMessage(),
                    "timestamp", Instant.now().toString()
            ));
        } catch (Exception e) {
            log.error("[DevController] embed-sample 예외: {}", e.getMessage(), e);
            return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(Map.of(
                    "status", "internal_error",
                    "error_message", e.getMessage(),
                    "timestamp", Instant.now().toString()
            ));
        }
    }

    /**
     * [DEV ONLY] Profile/face image에서 dog-nose crop을 미리보기로 추출합니다.
     * DB/Qdrant에는 아무 것도 기록하지 않습니다.
     */
    @PostMapping("/profile-nose-preview")
    public ResponseEntity<Map<String, Object>> profileNosePreview(
            @RequestParam("profile_image") MultipartFile profileImage
    ) {
        try {
            if (profileImage == null || profileImage.isEmpty()) {
                return invalidInput("profile_image is required.");
            }

            Map<String, Object> response = embedClient.extractProfileNose(
                    profileImage.getBytes(),
                    filenameOrDefault(profileImage, "profile-image.png"),
                    contentTypeOrDefault(profileImage)
            );
            return ResponseEntity.ok(response);
        } catch (EmbedClient.EmbedClientException e) {
            return upstreamFailure("profile-nose-preview", e);
        } catch (IOException e) {
            log.error("[DevController] profile-nose-preview 입력 처리 실패: {}", e.getMessage(), e);
            return invalidInput(e.getMessage());
        } catch (Exception e) {
            log.error("[DevController] profile-nose-preview 예외: {}", e.getMessage(), e);
            return internalError(e.getMessage());
        }
    }

    /**
     * [DEV ONLY] Profile-derived nose crop과 close-up nose image를 self-match합니다.
     * DB/Qdrant에는 아무 것도 기록하지 않습니다.
     */
    @PostMapping("/profile-nose-match")
    public ResponseEntity<Map<String, Object>> profileNoseMatch(
            @RequestParam("profile_image") MultipartFile profileImage,
            @RequestParam("nose_image") MultipartFile noseImage
    ) {
        try {
            if (profileImage == null || profileImage.isEmpty()) {
                return invalidInput("profile_image is required.");
            }
            if (noseImage == null || noseImage.isEmpty()) {
                return invalidInput("nose_image is required.");
            }

            Map<String, Object> response = embedClient.profileNoseMatch(
                    profileImage.getBytes(),
                    filenameOrDefault(profileImage, "profile-image.png"),
                    contentTypeOrDefault(profileImage),
                    noseImage.getBytes(),
                    filenameOrDefault(noseImage, "nose-image.png"),
                    contentTypeOrDefault(noseImage)
            );
            return ResponseEntity.ok(response);
        } catch (EmbedClient.EmbedClientException e) {
            return upstreamFailure("profile-nose-match", e);
        } catch (IOException e) {
            log.error("[DevController] profile-nose-match 입력 처리 실패: {}", e.getMessage(), e);
            return invalidInput(e.getMessage());
        } catch (Exception e) {
            log.error("[DevController] profile-nose-match 예외: {}", e.getMessage(), e);
            return internalError(e.getMessage());
        }
    }

    /** Qdrant 설정 확인 */
    @GetMapping("/qdrant-config")
    public Map<String, Object> qdrantConfig() {
        return Map.of(
                "host", qdrantHost,
                "port", qdrantPort,
                "collection", qdrantCollection,
                "vector_dimension", qdrantVectorDimension,
                "distance", qdrantDistance
        );
    }

    private static String filenameOrDefault(MultipartFile file, String fallback) {
        String filename = file.getOriginalFilename();
        return filename == null || filename.isBlank() ? fallback : filename;
    }

    private static String contentTypeOrDefault(MultipartFile file) {
        String contentType = file.getContentType();
        return contentType == null || contentType.isBlank() ? "image/png" : contentType;
    }

    private ResponseEntity<Map<String, Object>> upstreamFailure(String operation, EmbedClient.EmbedClientException e) {
        log.error("[DevController] {} 실패: status={}, body={}, message={}",
                operation, e.getUpstreamStatus(), e.getUpstreamBody(), e.getMessage(), e);

        Map<String, Object> errorBody = new LinkedHashMap<>();
        errorBody.put("status", "embed_call_failed");
        errorBody.put("error_message", e.getMessage());
        errorBody.put("upstream_status", e.getUpstreamStatus());
        errorBody.put("upstream_body", e.getUpstreamBody());
        errorBody.put("timestamp", Instant.now().toString());
        return ResponseEntity.status(HttpStatus.BAD_GATEWAY).body(errorBody);
    }

    private ResponseEntity<Map<String, Object>> invalidInput(String message) {
        String safeMessage = message == null ? "" : message;
        return ResponseEntity.status(HttpStatus.BAD_REQUEST).body(Map.of(
                "status", "invalid_input",
                "error_message", safeMessage,
                "timestamp", Instant.now().toString()
        ));
    }

    private ResponseEntity<Map<String, Object>> internalError(String message) {
        String safeMessage = message == null ? "" : message;
        return ResponseEntity.status(HttpStatus.INTERNAL_SERVER_ERROR).body(Map.of(
                "status", "internal_error",
                "error_message", safeMessage,
                "timestamp", Instant.now().toString()
        ));
    }
}
