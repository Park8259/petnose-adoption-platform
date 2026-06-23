package com.petnose.api.service;

import com.petnose.api.client.EmbedClient;
import com.petnose.api.dto.registration.ProfileNosePreviewApiResponse;
import com.petnose.api.exception.ApiException;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.http.MediaType;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.util.ReflectionTestUtils;

import java.util.LinkedHashMap;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class ProfileNosePreviewServiceTest {

    @Mock
    private EmbedClient embedClient;

    private ProfileNosePreviewService service;

    @BeforeEach
    void setUp() {
        service = new ProfileNosePreviewService(embedClient);
        ReflectionTestUtils.setField(service, "enabled", true);
    }

    @Test
    void detectorEnabledSuccessReturnsSanitizedPreviewShape() {
        Map<String, Object> upstream = new LinkedHashMap<>();
        upstream.put("extracted", true);
        upstream.put("confidence", 0.95484);
        upstream.put("crop_width", 224);
        upstream.put("crop_height", 224);
        upstream.put("crop_base64", "raw-crop-must-not-leak");
        upstream.put("bbox_xyxy", java.util.List.of(1, 2, 3, 4));
        when(embedClient.extractProfileNose(any(byte[].class), eq("profile.jpg"), eq(MediaType.IMAGE_JPEG_VALUE)))
                .thenReturn(upstream);

        ProfileNosePreviewApiResponse response = service.preview(profileImage());

        assertThat(response.extracted()).isTrue();
        assertThat(response.confidence()).isEqualTo(0.95484);
        assertThat(response.cropWidth()).isEqualTo(224);
        assertThat(response.cropHeight()).isEqualTo(224);
        assertThat(response.failureReason()).isNull();
        assertThat(response.errorCode()).isNull();
        assertThat(response.toString()).doesNotContain("raw-crop-must-not-leak");
        verify(embedClient).extractProfileNose(any(byte[].class), eq("profile.jpg"), eq(MediaType.IMAGE_JPEG_VALUE));
    }

    @Test
    void detectorLowConfidenceReturnsExtractedFalseWithoutThrowing() {
        Map<String, Object> upstream = new LinkedHashMap<>();
        upstream.put("extracted", false);
        upstream.put("confidence", 0.31);
        upstream.put("crop_width", null);
        upstream.put("crop_height", null);
        upstream.put("failure_reason", "LOW_CONFIDENCE");
        when(embedClient.extractProfileNose(any(byte[].class), eq("profile.jpg"), eq(MediaType.IMAGE_JPEG_VALUE)))
                .thenReturn(upstream);

        ProfileNosePreviewApiResponse response = service.preview(profileImage());

        assertThat(response.extracted()).isFalse();
        assertThat(response.confidence()).isEqualTo(0.31);
        assertThat(response.cropWidth()).isNull();
        assertThat(response.cropHeight()).isNull();
        assertThat(response.failureReason()).isEqualTo("LOW_CONFIDENCE");
        assertThat(response.errorCode()).isEqualTo("LOW_CONFIDENCE");
        assertThat(response.message()).contains("더 선명한 정면 사진");
    }

    @Test
    void disabledPreviewReturnsExplicitDisabledResponseAndDoesNotCallDetector() {
        ReflectionTestUtils.setField(service, "enabled", false);

        ProfileNosePreviewApiResponse response = service.preview(profileImage());

        assertThat(response.extracted()).isFalse();
        assertThat(response.failureReason()).isEqualTo("PROFILE_NOSE_PREVIEW_DISABLED");
        assertThat(response.errorCode()).isEqualTo("PROFILE_NOSE_PREVIEW_DISABLED");
        verify(embedClient, never()).extractProfileNose(any(), any(), any());
    }

    @Test
    void detectorUnavailableReturnsExplicitResponseAndDoesNotThrow500() {
        when(embedClient.extractProfileNose(any(byte[].class), eq("profile.jpg"), eq(MediaType.IMAGE_JPEG_VALUE)))
                .thenThrow(new EmbedClient.EmbedClientException("connect failed", null, null, null));

        ProfileNosePreviewApiResponse response = service.preview(profileImage());

        assertThat(response.extracted()).isFalse();
        assertThat(response.failureReason()).isEqualTo("DETECTOR_UNAVAILABLE");
        assertThat(response.errorCode()).isEqualTo("DETECTOR_UNAVAILABLE");
        assertThat(response.message()).contains("자동 코 검출기");
    }

    @Test
    void missingProfileImageReturnsValidationFailed() {
        assertThatThrownBy(() -> service.preview(null))
                .isInstanceOf(ApiException.class)
                .hasMessageContaining("profile_image");
    }

    private static MockMultipartFile profileImage() {
        return new MockMultipartFile(
                "profile_image",
                "profile.jpg",
                MediaType.IMAGE_JPEG_VALUE,
                new byte[]{1, 2, 3}
        );
    }
}
