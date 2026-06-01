package com.petnose.api.controller;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.petnose.api.dto.registration.DogRegisterRequest;
import com.petnose.api.dto.registration.DogRegisterResponse;
import com.petnose.api.dto.registration.DuplicateCandidateResponse;
import com.petnose.api.dto.registration.ScoreBreakdownResponse;
import com.petnose.api.exception.ApiException;
import com.petnose.api.service.AuthService;
import com.petnose.api.service.DogRegistrationService;
import org.junit.jupiter.api.Test;
import org.mockito.ArgumentCaptor;
import org.mockito.ArgumentMatchers;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.WebMvcTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;

import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.nullValue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.multipart;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@WebMvcTest(DogRegistrationController.class)
class DogRegistrationControllerTest {

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private ObjectMapper objectMapper;

    @MockBean
    private DogRegistrationService dogRegistrationService;

    @MockBean
    private AuthService authService;

    @Test
    void registerDogReturnsCreatedWhenRegistrationAllowed() throws Exception {
        when(authService.currentActiveUserId("Bearer test-token")).thenReturn(42L);
        when(dogRegistrationService.register(ArgumentMatchers.any()))
                .thenReturn(new DogRegisterResponse(
                        "dog-1",
                        true,
                        "REGISTERED",
                        "VERIFIED",
                        "COMPLETED",
                        null,
                        "dog-nose-identification2:s101_224",
                        2048,
                        0.12345,
                        "/files/dogs/dog-1/nose/sample.png",
                        null,
                        null,
                        "MULTI_REFERENCE",
                        5,
                        scoreBreakdown(0.12345),
                        List.of(
                                "/files/dogs/dog-1/nose/sample.png",
                                "/files/dogs/dog-1/nose/sample-2.png",
                                "/files/dogs/dog-1/nose/sample-3.png",
                                "/files/dogs/dog-1/nose/sample-4.png",
                                "/files/dogs/dog-1/nose/sample-5.png"
                        ),
                        "registered"
                ));

        MvcResult result = mockMvc.perform(validMultipartRequest())
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.dog_id").value("dog-1"))
                .andExpect(jsonPath("$.registration_allowed").value(true))
                .andExpect(jsonPath("$.status").value("REGISTERED"))
                .andExpect(jsonPath("$.verification_status").value("VERIFIED"))
                .andExpect(jsonPath("$.embedding_status").value("COMPLETED"))
                .andExpect(jsonPath("$.qdrant_point_id").value(nullValue()))
                .andExpect(jsonPath("$.model").value("dog-nose-identification2:s101_224"))
                .andExpect(jsonPath("$.dimension").value(2048))
                .andExpect(jsonPath("$.max_similarity_score").value(0.12345))
                .andExpect(jsonPath("$.nose_image_url").value("/files/dogs/dog-1/nose/sample.png"))
                .andExpect(jsonPath("$.profile_image_url").value(nullValue()))
                .andExpect(jsonPath("$.top_match").doesNotExist())
                .andExpect(jsonPath("$.embedding_mode").value("MULTI_REFERENCE"))
                .andExpect(jsonPath("$.reference_count").value(5))
                .andExpect(jsonPath("$.score_breakdown.final_score").value(0.12345))
                .andExpect(jsonPath("$.score_breakdown.reference_consistency_score").value(0.86))
                .andExpect(jsonPath("$.nose_image_urls[0]").value("/files/dogs/dog-1/nose/sample.png"))
                .andExpect(jsonPath("$.nose_image_urls[1]").value("/files/dogs/dog-1/nose/sample-2.png"))
                .andExpect(jsonPath("$.nose_image_urls[2]").value("/files/dogs/dog-1/nose/sample-3.png"))
                .andExpect(jsonPath("$.nose_image_urls[3]").value("/files/dogs/dog-1/nose/sample-4.png"))
                .andExpect(jsonPath("$.nose_image_urls[4]").value("/files/dogs/dog-1/nose/sample-5.png"))
                .andExpect(jsonPath("$.message").value("registered"))
                .andExpect(jsonPath("$.dogId").doesNotExist())
                .andExpect(jsonPath("$.registrationAllowed").doesNotExist())
                .andReturn();

        ArgumentCaptor<DogRegisterRequest> requestCaptor = ArgumentCaptor.forClass(DogRegisterRequest.class);
        verify(dogRegistrationService).register(requestCaptor.capture());
        assertThat(requestCaptor.getValue().userId()).isEqualTo(42L);
        assertThat(requestCaptor.getValue().noseImages()).hasSize(5);

        JsonNode body = objectMapper.readTree(responseBody(result));
        assertThat(body.fieldNames())
                .toIterable()
                .containsExactly(
                        "dog_id",
                        "registration_allowed",
                        "status",
                        "verification_status",
                        "embedding_status",
                        "qdrant_point_id",
                        "model",
                        "dimension",
                        "max_similarity_score",
                        "nose_image_url",
                        "profile_image_url",
                        "top_match",
                        "embedding_mode",
                        "reference_count",
                        "score_breakdown",
                        "nose_image_urls",
                        "message"
                );
    }

    @Test
    void registerDogReturnsOkWhenDuplicateSuspected() throws Exception {
        when(authService.currentActiveUserId("Bearer test-token")).thenReturn(42L);
        when(dogRegistrationService.register(ArgumentMatchers.any()))
                .thenReturn(new DogRegisterResponse(
                        "dog-2",
                        false,
                        "DUPLICATE_SUSPECTED",
                        "DUPLICATE_SUSPECTED",
                        "SKIPPED_DUPLICATE",
                        null,
                        "dog-nose-identification2:s101_224",
                        2048,
                        0.98765,
                        "/files/dogs/dog-2/nose/sample.png",
                        null,
                        new DuplicateCandidateResponse("existing-dog-1", 0.98765, "Jindo"),
                        "MULTI_REFERENCE",
                        5,
                        scoreBreakdown(0.98765),
                        List.of(
                                "/files/dogs/dog-2/nose/sample.png",
                                "/files/dogs/dog-2/nose/sample-2.png",
                                "/files/dogs/dog-2/nose/sample-3.png",
                                "/files/dogs/dog-2/nose/sample-4.png",
                                "/files/dogs/dog-2/nose/sample-5.png"
                        ),
                        "duplicate suspected"
                ));

        MvcResult result = mockMvc.perform(validMultipartRequest())
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.dog_id").value("dog-2"))
                .andExpect(jsonPath("$.registration_allowed").value(false))
                .andExpect(jsonPath("$.status").value("DUPLICATE_SUSPECTED"))
                .andExpect(jsonPath("$.verification_status").value("DUPLICATE_SUSPECTED"))
                .andExpect(jsonPath("$.embedding_status").value("SKIPPED_DUPLICATE"))
                .andExpect(jsonPath("$.qdrant_point_id").doesNotExist())
                .andExpect(jsonPath("$.model").value("dog-nose-identification2:s101_224"))
                .andExpect(jsonPath("$.dimension").value(2048))
                .andExpect(jsonPath("$.max_similarity_score").value(0.98765))
                .andExpect(jsonPath("$.nose_image_url").value("/files/dogs/dog-2/nose/sample.png"))
                .andExpect(jsonPath("$.profile_image_url").doesNotExist())
                .andExpect(jsonPath("$.top_match.dog_id").value("existing-dog-1"))
                .andExpect(jsonPath("$.top_match.similarity_score").value(0.98765))
                .andExpect(jsonPath("$.top_match.breed").value("Jindo"))
                .andExpect(jsonPath("$.top_match.nose_image_url").doesNotExist())
                .andExpect(jsonPath("$.embedding_mode").value("MULTI_REFERENCE"))
                .andExpect(jsonPath("$.reference_count").value(5))
                .andExpect(jsonPath("$.score_breakdown.final_score").value(0.98765))
                .andExpect(jsonPath("$.nose_image_urls").isArray())
                .andExpect(jsonPath("$.message").value("duplicate suspected"))
                .andExpect(jsonPath("$.topMatch").doesNotExist())
                .andReturn();

        JsonNode body = objectMapper.readTree(responseBody(result));
        assertThat(body.has("qdrant_point_id")).isTrue();
        assertThat(body.get("qdrant_point_id").isNull()).isTrue();
        assertThat(body.get("top_match").fieldNames())
                .toIterable()
                .containsExactly("dog_id", "similarity_score", "breed");
        assertThat(body.get("top_match").has("nose_image_url")).isFalse();
    }

    @Test
    void registerDogUsesCanonicalErrorResponse() throws Exception {
        when(authService.currentActiveUserId("Bearer test-token")).thenReturn(42L);
        when(dogRegistrationService.register(ArgumentMatchers.any()))
                .thenThrow(new ApiException(HttpStatus.NOT_FOUND, "USER_NOT_FOUND", "존재하지 않는 user_id 입니다."));

        mockMvc.perform(validMultipartRequest())
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error_code").value("USER_NOT_FOUND"))
                .andExpect(jsonPath("$.message").value("존재하지 않는 user_id 입니다."))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void registerDogReturnsReferenceQualityErrorDetails() throws Exception {
        when(authService.currentActiveUserId("Bearer test-token")).thenReturn(42L);
        when(dogRegistrationService.register(ArgumentMatchers.any()))
                .thenThrow(new ApiException(
                        HttpStatus.BAD_REQUEST,
                        "NOSE_REFERENCE_INCONSISTENT",
                        "5번째 비문 이미지가 다른 이미지들과 일관성이 낮습니다. 코 전체가 중앙에 오도록 다시 촬영해주세요.",
                        Map.of(
                                "quality_verdict", "RETAKE_ONE",
                                "weakest_image_index", 5,
                                "recommendation", "5번째 비문 이미지가 다른 이미지들과 일관성이 낮습니다. 코 전체가 중앙에 오도록 다시 촬영해주세요."
                        )
                ));

        mockMvc.perform(validMultipartRequest())
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("NOSE_REFERENCE_INCONSISTENT"))
                .andExpect(jsonPath("$.details.quality_verdict").value("RETAKE_ONE"))
                .andExpect(jsonPath("$.details.weakest_image_index").value(5))
                .andExpect(jsonPath("$.details.recommendation").exists());
    }

    @Test
    void registerDogIgnoresMultipartUserIdWhenBearerTokenIsPresent() throws Exception {
        when(authService.currentActiveUserId("Bearer test-token")).thenReturn(42L);
        when(dogRegistrationService.register(ArgumentMatchers.any()))
                .thenReturn(new DogRegisterResponse(
                        "dog-1",
                        true,
                        "REGISTERED",
                        "VERIFIED",
                        "COMPLETED",
                        "dog-1",
                        "dog-nose-identification2:s101_224",
                        2048,
                        0.12345,
                        "/files/dogs/dog-1/nose/sample.png",
                        null,
                        null,
                        "MULTI_REFERENCE",
                        5,
                        scoreBreakdown(0.12345),
                        List.of(
                                "/files/dogs/dog-1/nose/sample.png",
                                "/files/dogs/dog-1/nose/sample-2.png",
                                "/files/dogs/dog-1/nose/sample-3.png",
                                "/files/dogs/dog-1/nose/sample-4.png",
                                "/files/dogs/dog-1/nose/sample-5.png"
                        ),
                        "registered"
                ));

        mockMvc.perform(validMultipartRequestWithFormUserId())
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.registration_allowed").value(true));

        ArgumentCaptor<DogRegisterRequest> requestCaptor = ArgumentCaptor.forClass(DogRegisterRequest.class);
        verify(dogRegistrationService).register(requestCaptor.capture());
        assertThat(requestCaptor.getValue().userId()).isEqualTo(42L);
    }

    @Test
    void registerDogRejectsMissingAuthorizationBeforeService() throws Exception {
        when(authService.currentActiveUserId(null))
                .thenThrow(new ApiException(HttpStatus.UNAUTHORIZED, "UNAUTHORIZED", "Authorization Bearer token이 필요합니다."));

        mockMvc.perform(validMultipartRequestWithoutAuthorization())
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"));

        verify(dogRegistrationService, never()).register(any());
    }

    private static org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder validMultipartRequest() {
        return validMultipartRequestWithoutAuthorization()
                .header(HttpHeaders.AUTHORIZATION, "Bearer test-token");
    }

    private static org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder validMultipartRequestWithFormUserId() {
        return validMultipartRequest()
                .param("user_id", "999");
    }

    private static org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder validMultipartRequestWithoutAuthorization() {
        MockMultipartFile noseImage1 = new MockMultipartFile("nose_images", "sample.png", "image/png", new byte[]{1, 2, 3});
        MockMultipartFile noseImage2 = new MockMultipartFile("nose_images", "sample-2.png", "image/png", new byte[]{1, 2, 3});
        MockMultipartFile noseImage3 = new MockMultipartFile("nose_images", "sample-3.png", "image/png", new byte[]{1, 2, 3});
        MockMultipartFile noseImage4 = new MockMultipartFile("nose_images", "sample-4.png", "image/png", new byte[]{1, 2, 3});
        MockMultipartFile noseImage5 = new MockMultipartFile("nose_images", "sample-5.png", "image/png", new byte[]{1, 2, 3});

        return multipart("/api/dogs/register")
                .file(noseImage1)
                .file(noseImage2)
                .file(noseImage3)
                .file(noseImage4)
                .file(noseImage5)
                .param("name", "Bori")
                .param("breed", "Jindo")
                .param("gender", "MALE")
                .param("birth_date", "2024-01-01")
                .param("description", "friendly");
    }

    private static ScoreBreakdownResponse scoreBreakdown(double finalScore) {
        return new ScoreBreakdownResponse(finalScore, finalScore, finalScore, finalScore, 5, 0.86);
    }

    private String responseBody(MvcResult result) {
        return new String(result.getResponse().getContentAsByteArray(), StandardCharsets.UTF_8);
    }
}
