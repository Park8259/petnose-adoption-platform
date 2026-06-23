package com.petnose.api.controller;

import com.petnose.api.dto.registration.ProfileNosePreviewApiResponse;
import com.petnose.api.exception.ApiException;
import com.petnose.api.service.ProfileNosePreviewService;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.HttpStatus;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;

import static org.hamcrest.Matchers.nullValue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.multipart;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(ProfileNosePreviewCompatController.class)
@ActiveProfiles("prod")
class ProfileNosePreviewCompatControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @MockBean
    private ProfileNosePreviewService profileNosePreviewService;

    @Test
    void profileNosePreviewDevAliasUsesSamePreviewResponseShapeInNonDevProfile() throws Exception {
        when(profileNosePreviewService.preview(any()))
                .thenReturn(new ProfileNosePreviewApiResponse(
                        true,
                        0.95484,
                        224,
                        224,
                        null,
                        "정면 사진에서 비문 영역을 확인했습니다.",
                        null
                ));

        mockMvc.perform(multipart("/api/dev/profile-nose-preview")
                        .file(new MockMultipartFile("profile_image", "profile.jpg", "image/jpeg", new byte[]{1, 2, 3})))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.extracted").value(true))
                .andExpect(jsonPath("$.confidence").value(0.95484))
                .andExpect(jsonPath("$.crop_width").value(224))
                .andExpect(jsonPath("$.crop_height").value(224))
                .andExpect(jsonPath("$.failure_reason").value(nullValue()))
                .andExpect(jsonPath("$.error_code").value(nullValue()));

        verify(profileNosePreviewService).preview(any());
    }

    @Test
    void profileNosePreviewDevAliasMissingImageReturnsValidationFailed() throws Exception {
        when(profileNosePreviewService.preview(isNull()))
                .thenThrow(new ApiException(HttpStatus.BAD_REQUEST, "VALIDATION_FAILED", "profile_image는 필수입니다."));

        mockMvc.perform(multipart("/api/dev/profile-nose-preview"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("VALIDATION_FAILED"))
                .andExpect(jsonPath("$.message").value("profile_image는 필수입니다."));

        verify(profileNosePreviewService).preview(isNull());
    }
}
