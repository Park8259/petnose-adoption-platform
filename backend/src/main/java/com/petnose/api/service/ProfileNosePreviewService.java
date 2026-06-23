package com.petnose.api.service;

import com.petnose.api.client.EmbedClient;
import com.petnose.api.dto.registration.ProfileNosePreviewApiResponse;
import com.petnose.api.exception.ApiException;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.util.Map;

@Slf4j
@Service
@RequiredArgsConstructor
public class ProfileNosePreviewService {

    private static final String FACE_CHECK_PURPOSE = "face_check";
    private static final String PROFILE_NOSE_PREVIEW_DISABLED = "PROFILE_NOSE_PREVIEW_DISABLED";
    private static final String DETECTOR_UNAVAILABLE = "DETECTOR_UNAVAILABLE";
    private static final String INVALID_IMAGE = "INVALID_IMAGE";
    private static final String NO_NOSE_DETECTED = "NO_NOSE_DETECTED";
    private static final String MULTIPLE_NOSES_DETECTED = "MULTIPLE_NOSES_DETECTED";
    private static final String LOW_CONFIDENCE = "LOW_CONFIDENCE";

    private final EmbedClient embedClient;

    @Value("${petnose.profile-nose-preview.enabled:false}")
    private boolean enabled;

    public ProfileNosePreviewApiResponse preview(MultipartFile profileImage, String requestId) {
        if (profileImage == null || profileImage.isEmpty()) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "VALIDATION_FAILED", "profile_image는 필수입니다.");
        }
        if (!enabled) {
            return failure(
                    PROFILE_NOSE_PREVIEW_DISABLED,
                    "프로필 비문 미리보기 기능이 비활성화되어 있습니다."
            );
        }

        try {
            Map<String, Object> response = embedClient.extractProfileNose(
                    profileImage.getBytes(),
                    filenameOrDefault(profileImage),
                    contentTypeOrDefault(profileImage),
                    FACE_CHECK_PURPOSE,
                    requestId
            );
            return normalize(response);
        } catch (IOException e) {
            log.warn("[ProfileNosePreview] profile_image read failed: {}", e.getMessage());
            return failure(INVALID_IMAGE, "이미지를 읽지 못했습니다. 다른 사진을 선택해주세요.");
        } catch (EmbedClient.EmbedClientException e) {
            log.warn("[ProfileNosePreview] detector unavailable: status={}, message={}",
                    e.getUpstreamStatus(), e.getMessage());
            return failure(DETECTOR_UNAVAILABLE, "서버의 자동 코 검출기를 사용할 수 없습니다.");
        } catch (Exception e) {
            log.warn("[ProfileNosePreview] unexpected preview failure: {}", e.getMessage(), e);
            return failure(DETECTOR_UNAVAILABLE, "서버의 자동 코 검출기를 사용할 수 없습니다.");
        }
    }

    private ProfileNosePreviewApiResponse normalize(Map<String, Object> response) {
        boolean extracted = booleanValue(response.get("extracted"));
        String failureReason = valueOrNull(response.get("failure_reason"));
        Double confidence = numberAsDouble(response.get("confidence"));
        Integer cropWidth = numberAsInteger(response.get("crop_width"));
        Integer cropHeight = numberAsInteger(response.get("crop_height"));

        if (extracted) {
            return new ProfileNosePreviewApiResponse(
                    true,
                    confidence,
                    cropWidth,
                    cropHeight,
                    null,
                    "정면 사진에서 비문 영역을 확인했습니다.",
                    null
            );
        }

        String reason = failureReason == null || failureReason.isBlank() ? DETECTOR_UNAVAILABLE : failureReason;
        return new ProfileNosePreviewApiResponse(
                false,
                confidence,
                null,
                null,
                reason,
                messageFor(reason),
                reason
        );
    }

    private static ProfileNosePreviewApiResponse failure(String reason, String message) {
        return new ProfileNosePreviewApiResponse(false, null, null, null, reason, message, reason);
    }

    private static String messageFor(String failureReason) {
        return switch (failureReason) {
            case DETECTOR_UNAVAILABLE ->
                    "서버의 자동 코 검출기를 사용할 수 없습니다.";
            case INVALID_IMAGE ->
                    "이미지를 읽지 못했습니다. 다른 사진을 선택해주세요.";
            case NO_NOSE_DETECTED ->
                    "정면 사진에서 비문 영역을 찾지 못했습니다. 얼굴과 코가 함께 보이는 사진을 선택해주세요.";
            case MULTIPLE_NOSES_DETECTED ->
                    "여러 코 후보가 감지되었습니다. 한 마리만 나온 정면 사진을 선택해주세요.";
            case LOW_CONFIDENCE ->
                    "정면 사진에서 비문 영역을 충분히 확인하지 못했습니다. 더 선명한 정면 사진을 선택해주세요.";
            case PROFILE_NOSE_PREVIEW_DISABLED ->
                    "프로필 비문 미리보기 기능이 비활성화되어 있습니다.";
            default ->
                    "정면 사진에서 비문 영역을 충분히 확인하지 못했습니다. 더 선명한 정면 사진을 선택해주세요.";
        };
    }

    private static String filenameOrDefault(MultipartFile file) {
        String filename = file.getOriginalFilename();
        return filename == null || filename.isBlank() ? "profile-image.png" : filename;
    }

    private static String contentTypeOrDefault(MultipartFile file) {
        String contentType = file.getContentType();
        return contentType == null || contentType.isBlank() ? "image/png" : contentType;
    }

    private static boolean booleanValue(Object value) {
        return value instanceof Boolean bool && bool;
    }

    private static Double numberAsDouble(Object value) {
        return value instanceof Number number ? number.doubleValue() : null;
    }

    private static Integer numberAsInteger(Object value) {
        return value instanceof Number number ? number.intValue() : null;
    }

    private static String valueOrNull(Object value) {
        return value == null ? null : String.valueOf(value);
    }
}
