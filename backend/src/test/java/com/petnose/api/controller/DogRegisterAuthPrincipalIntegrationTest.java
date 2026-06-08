package com.petnose.api.controller;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.petnose.api.client.EmbedClient;
import com.petnose.api.client.QdrantDogVectorClient;
import com.petnose.api.domain.entity.Dog;
import com.petnose.api.domain.entity.DogImage;
import com.petnose.api.domain.entity.User;
import com.petnose.api.domain.entity.VerificationLog;
import com.petnose.api.domain.enums.DogStatus;
import com.petnose.api.domain.enums.VerificationResult;
import com.petnose.api.repository.DogImageRepository;
import com.petnose.api.repository.DogNoseReferenceRepository;
import com.petnose.api.repository.DogRepository;
import com.petnose.api.repository.UserRepository;
import com.petnose.api.repository.VerificationLogRepository;
import org.mockito.ArgumentCaptor;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.request.MockHttpServletRequestBuilder;
import org.springframework.test.web.servlet.request.MockMultipartHttpServletRequestBuilder;
import org.springframework.transaction.annotation.Transactional;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Base64;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyDouble;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.reset;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.multipart;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
@Transactional
class DogRegisterAuthPrincipalIntegrationTest {

    private static final String TEST_JWT_SECRET = "test-petnose-jwt-secret-change-me-32bytes";

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private ObjectMapper objectMapper;

    @Autowired
    private UserRepository userRepository;

    @Autowired
    private DogRepository dogRepository;

    @Autowired
    private DogImageRepository dogImageRepository;

    @Autowired
    private DogNoseReferenceRepository dogNoseReferenceRepository;

    @Autowired
    private VerificationLogRepository verificationLogRepository;

    @MockBean
    private EmbedClient embedClient;

    @MockBean
    private QdrantDogVectorClient qdrantDogVectorClient;

    @BeforeEach
    void setUp() {
        dogNoseReferenceRepository.deleteAll();
        verificationLogRepository.deleteAll();
        dogImageRepository.deleteAll();
        dogRepository.deleteAll();
        userRepository.deleteAll();
        reset(embedClient, qdrantDogVectorClient);
        when(embedClient.embedBatch(anyList()))
                .thenReturn(new EmbedClient.BatchEmbedResponse(batchItems(consistentVectors()), 128, "test-model"));
        when(qdrantDogVectorClient.searchReferencePoints(anyList(), anyInt(), anyDouble())).thenReturn(List.of());
        when(qdrantDogVectorClient.searchCentroidPoints(anyList(), anyInt(), anyDouble())).thenReturn(List.of());
    }

    @Test
    void dogRegisterPrincipalOnlySuccessCreatesRowsAndUpsertsReferenceAndCentroidPoints() throws Exception {
        registerUser("principal-dog@example.com");
        User user = userRepository.findByEmail("principal-dog@example.com").orElseThrow();
        String accessToken = loginAccessToken("principal-dog@example.com");

        MvcResult result = mockMvc.perform(validDogMultipart(null)
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.registration_allowed").value(true))
                .andExpect(jsonPath("$.status").value("REGISTERED"))
                .andExpect(jsonPath("$.verification_status").value("VERIFIED"))
                .andExpect(jsonPath("$.embedding_status").value("COMPLETED"))
                .andExpect(jsonPath("$.qdrant_point_id").doesNotExist())
                .andExpect(jsonPath("$.embedding_mode").value("MULTI_REFERENCE"))
                .andExpect(jsonPath("$.reference_count").value(5))
                .andExpect(jsonPath("$.model").value("test-model"))
                .andExpect(jsonPath("$.dimension").value(128))
                .andExpect(jsonPath("$.max_similarity_score").value(0.0))
                .andExpect(jsonPath("$.score_breakdown.final_score").value(0.0))
                .andExpect(jsonPath("$.nose_image_urls").isArray())
                .andExpect(jsonPath("$.top_match").doesNotExist())
                .andReturn();

        Dog dog = onlyDog();
        assertThat(dog.getOwnerUserId()).isEqualTo(user.getId());
        assertThat(dog.getStatus()).isEqualTo(DogStatus.REGISTERED);
        assertThat(dog.getAge()).isEqualTo(3);
        assertThat(dog.getPrice()).isEqualTo(250000L);
        assertThat(dog.getHealth()).isEqualTo("healthy");

        List<DogImage> noseImages = dogImageRepository.findAll();
        assertThat(noseImages).hasSize(5);
        assertThat(noseImages)
                .allSatisfy(noseImage -> {
                    assertThat(noseImage.getDogId()).isEqualTo(dog.getId());
                    assertThat(noseImage.getFilePath()).startsWith("dogs/").doesNotContain("/tmp", "\\tmp");
                });

        VerificationLog verificationLog = onlyVerificationLog();
        assertThat(verificationLog.getDogId()).isEqualTo(dog.getId());
        assertThat(verificationLog.getDogImageId()).isEqualTo(noseImages.get(0).getId());
        assertThat(verificationLog.getRequestedByUserId()).isEqualTo(user.getId());
        assertThat(verificationLog.getResult()).isEqualTo(VerificationResult.PASSED);
        assertThat(verificationLog.getScoreBreakdownJson()).contains("\"policy\":\"max_reference_or_centroid_v1\"");

        String responseDogId = objectMapper.readTree(responseBody(result)).get("dog_id").asText();
        assertThat(responseDogId).isEqualTo(dog.getId());
        assertThat(objectMapper.readTree(responseBody(result)).get("qdrant_point_id").isNull()).isTrue();

        @SuppressWarnings("unchecked")
        ArgumentCaptor<List<QdrantDogVectorClient.QdrantPointUpsertRequest>> pointsCaptor = ArgumentCaptor.forClass(List.class);
        verify(qdrantDogVectorClient).upsertAll(pointsCaptor.capture());
        assertThat(pointsCaptor.getValue()).hasSize(6);
        assertThat(pointsCaptor.getValue())
                .extracting(point -> point.payload().get("embedding_kind"))
                .containsExactly("REFERENCE", "REFERENCE", "REFERENCE", "REFERENCE", "REFERENCE", "CENTROID");
        assertThat(dogNoseReferenceRepository.findByDogIdAndActiveTrueOrderByCreatedAtAsc(dog.getId())).hasSize(6);
    }

    @Test
    void dogRegisterUsesJwtPrincipalBeforeMismatchedFormUserId() throws Exception {
        registerUser("dog-owner-a@example.com");
        registerUser("dog-owner-b@example.com");
        User userA = userRepository.findByEmail("dog-owner-a@example.com").orElseThrow();
        User userB = userRepository.findByEmail("dog-owner-b@example.com").orElseThrow();
        String accessToken = loginAccessToken("dog-owner-a@example.com");

        mockMvc.perform(validDogMultipart(userB.getId())
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.registration_allowed").value(true));

        assertThat(onlyDog().getOwnerUserId()).isEqualTo(userA.getId());
    }

    @Test
    void dogRegisterAllowsOmittedUserIdWhenBearerTokenIsValid() throws Exception {
        registerUser("dog-token-only@example.com");
        User user = userRepository.findByEmail("dog-token-only@example.com").orElseThrow();
        String accessToken = loginAccessToken("dog-token-only@example.com");

        mockMvc.perform(validDogMultipart(null)
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.registration_allowed").value(true));

        assertThat(onlyDog().getOwnerUserId()).isEqualTo(user.getId());
    }

    @Test
    void dogRegisterRejectsInvalidTokenWithoutLegacyFallback() throws Exception {
        registerUser("dog-invalid-token@example.com");
        User fallbackUser = userRepository.findByEmail("dog-invalid-token@example.com").orElseThrow();

        mockMvc.perform(validDogMultipart(fallbackUser.getId())
                        .header(HttpHeaders.AUTHORIZATION, "Bearer invalid-token"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"));

        assertPipelineRowsAbsent();
        verifyPipelineNotStarted();
    }

    @Test
    void dogRegisterRejectsMalformedAuthorizationWithoutLegacyFallback() throws Exception {
        registerUser("dog-malformed-auth@example.com");
        User fallbackUser = userRepository.findByEmail("dog-malformed-auth@example.com").orElseThrow();

        mockMvc.perform(validDogMultipart(fallbackUser.getId())
                        .header(HttpHeaders.AUTHORIZATION, "Basic invalid-token"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"));

        assertPipelineRowsAbsent();
        verifyPipelineNotStarted();
    }

    @Test
    void dogRegisterRejectsExpiredTokenWithoutLegacyFallback() throws Exception {
        registerUser("dog-expired-token@example.com");
        User fallbackUser = userRepository.findByEmail("dog-expired-token@example.com").orElseThrow();
        String expiredToken = signedToken(fallbackUser.getId(), Instant.now().minusSeconds(60).getEpochSecond());

        mockMvc.perform(validDogMultipart(fallbackUser.getId())
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + expiredToken))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"));

        assertPipelineRowsAbsent();
        verifyPipelineNotStarted();
    }

    @Test
    void dogRegisterRejectsMissingUserFromTokenBeforePipelineStarts() throws Exception {
        String tokenForMissingUser = signedToken(999_999L, Instant.now().plusSeconds(3600).getEpochSecond());

        mockMvc.perform(validDogMultipart(null)
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + tokenForMissingUser))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error_code").value("USER_NOT_FOUND"));

        assertPipelineRowsAbsent();
        verifyPipelineNotStarted();
    }

    @Test
    void dogRegisterRejectsInactiveUserBeforePipelineStarts() throws Exception {
        registerUser("dog-inactive@example.com");
        String accessToken = loginAccessToken("dog-inactive@example.com");
        User user = userRepository.findByEmail("dog-inactive@example.com").orElseThrow();
        user.setActive(false);
        userRepository.saveAndFlush(user);

        mockMvc.perform(validDogMultipart(null)
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.error_code").value("USER_INACTIVE"));

        assertPipelineRowsAbsent();
        verifyPipelineNotStarted();
    }

    @Test
    void dogRegisterRejectsMissingAuthorizationBeforePipelineStarts() throws Exception {
        mockMvc.perform(validDogMultipart(null))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"));

        assertPipelineRowsAbsent();
        verifyPipelineNotStarted();
    }

    @Test
    void dogRegisterRejectsLegacyUserIdOnlyFallbackBeforePipelineStarts() throws Exception {
        registerUser("dog-user-id-only@example.com");
        User fallbackUser = userRepository.findByEmail("dog-user-id-only@example.com").orElseThrow();

        mockMvc.perform(validDogMultipart(fallbackUser.getId()))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"));

        assertPipelineRowsAbsent();
        verifyPipelineNotStarted();
    }

    @Test
    void dogRegisterValidationStillRunsAfterAuthorizationPasses() throws Exception {
        registerUser("dog-validation@example.com");
        String accessToken = loginAccessToken("dog-validation@example.com");

        mockMvc.perform(dogMultipart(null, noseImages(5), null, "Jindo", "MALE")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("NAME_REQUIRED"));

        mockMvc.perform(dogMultipart(null, noseImages(5), "Bori", null, "MALE")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("BREED_REQUIRED"));

        mockMvc.perform(dogMultipart(null, null, "Bori", "Jindo", "MALE")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("NOSE_IMAGES_REQUIRED"));

        mockMvc.perform(legacyDogMultipart("nose.jpg", "Bori", "Jindo", "MALE")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("NOSE_IMAGES_REQUIRED"));

        mockMvc.perform(dogMultipart(null, noseImages(5), "Bori", "Jindo", "INVALID")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("VALIDATION_FAILED"));

        assertPipelineRowsAbsent();
        verifyPipelineNotStarted();
    }

    @Test
    void dogRegisterRejectsNonFiveNoseImageCountsBeforePipelineStarts() throws Exception {
        registerUser("dog-count-validation@example.com");
        String accessToken = loginAccessToken("dog-count-validation@example.com");

        for (int actualCount : List.of(2, 3, 4, 6)) {
            mockMvc.perform(dogMultipart(null, noseImages(actualCount), "Bori", "Jindo", "MALE")
                            .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken))
                    .andExpect(status().isBadRequest())
                    .andExpect(jsonPath("$.error_code").value("NOSE_IMAGES_COUNT_INVALID"))
                    .andExpect(jsonPath("$.message").value("비문 기준 이미지는 정확히 5장이 필요합니다."))
                    .andExpect(jsonPath("$.details.expected_count").value(5))
                    .andExpect(jsonPath("$.details.actual_count").value(actualCount));
        }

        assertPipelineRowsAbsent();
        verifyPipelineNotStarted();
    }

    @Test
    void dogRegisterReferenceQualityFailureReturnsDetailsBeforeSideEffects() throws Exception {
        registerUser("dog-reference-quality@example.com");
        String accessToken = loginAccessToken("dog-reference-quality@example.com");
        when(embedClient.embedBatch(anyList()))
                .thenReturn(new EmbedClient.BatchEmbedResponse(batchItems(vectorsWithAveragePairwiseScore(0.54)), 128, "test-model"));

        mockMvc.perform(validDogMultipart(null)
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("NOSE_REFERENCE_INCONSISTENT"))
                .andExpect(jsonPath("$.details.quality_verdict").value("RETAKE_ONE"))
                .andExpect(jsonPath("$.details.weakest_image_index").value(5))
                .andExpect(jsonPath("$.details.recommendation").exists())
                .andExpect(jsonPath("$.details.pairwise_scores").isArray());

        assertPipelineRowsAbsent();
        verify(qdrantDogVectorClient, never()).searchReferencePoints(anyList(), anyInt(), anyDouble());
        verify(qdrantDogVectorClient, never()).upsertAll(anyList());
    }

    @Test
    void dogRegisterDuplicateSuspectedBehaviorUnchangedWithBearerToken() throws Exception {
        registerUser("dog-duplicate@example.com");
        String accessToken = loginAccessToken("dog-duplicate@example.com");
        saveCandidateDog("candidate-dog", "Maltese");
        when(qdrantDogVectorClient.searchReferencePoints(anyList(), anyInt(), anyDouble()))
                .thenReturn(List.of(vectorResult("candidate-dog", 0.80)));

        MvcResult result = mockMvc.perform(validDogMultipart(null)
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.registration_allowed").value(false))
                .andExpect(jsonPath("$.status").value("DUPLICATE_SUSPECTED"))
                .andExpect(jsonPath("$.verification_status").value("DUPLICATE_SUSPECTED"))
                .andExpect(jsonPath("$.embedding_status").value("SKIPPED_DUPLICATE"))
                .andExpect(jsonPath("$.qdrant_point_id").doesNotExist())
                .andExpect(jsonPath("$.top_match.dog_id").value("candidate-dog"))
                .andExpect(jsonPath("$.top_match.similarity_score").value(0.80))
                .andExpect(jsonPath("$.top_match.breed").value("Maltese"))
                .andExpect(jsonPath("$.top_match.nose_image_url").doesNotExist())
                .andExpect(jsonPath("$.embedding_mode").value("MULTI_REFERENCE"))
                .andExpect(jsonPath("$.reference_count").value(5))
                .andReturn();

        assertThat(objectMapper.readTree(responseBody(result)).get("qdrant_point_id").isNull()).isTrue();
        String responseDogId = objectMapper.readTree(responseBody(result)).get("dog_id").asText();
        assertThat(dogRepository.findById(responseDogId).orElseThrow().getStatus()).isEqualTo(DogStatus.DUPLICATE_SUSPECTED);
        assertThat(dogImageRepository.count()).isEqualTo(5);
        assertThat(onlyVerificationLog().getResult()).isEqualTo(VerificationResult.DUPLICATE_SUSPECTED);
        verify(qdrantDogVectorClient, never()).upsertAll(anyList());
    }

    @Test
    void dogRegisterScoreBelowDuplicateThresholdCreatesNormalRegistrationWithBearerToken() throws Exception {
        registerUser("dog-below-threshold@example.com");
        String accessToken = loginAccessToken("dog-below-threshold@example.com");

        MvcResult result = mockMvc.perform(validDogMultipart(null)
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.registration_allowed").value(true))
                .andExpect(jsonPath("$.status").value("REGISTERED"))
                .andExpect(jsonPath("$.verification_status").value("VERIFIED"))
                .andExpect(jsonPath("$.embedding_status").value("COMPLETED"))
                .andExpect(jsonPath("$.qdrant_point_id").doesNotExist())
                .andExpect(jsonPath("$.max_similarity_score").value(0.0))
                .andExpect(jsonPath("$.embedding_mode").value("MULTI_REFERENCE"))
                .andExpect(jsonPath("$.reference_count").value(5))
                .andExpect(jsonPath("$.top_match").doesNotExist())
                .andReturn();

        Dog dog = onlyDog();
        assertThat(dog.getStatus()).isEqualTo(DogStatus.REGISTERED);
        assertThat(onlyVerificationLog().getResult()).isEqualTo(VerificationResult.PASSED);

        String responseDogId = objectMapper.readTree(responseBody(result)).get("dog_id").asText();
        assertThat(responseDogId).isEqualTo(dog.getId());
        assertThat(objectMapper.readTree(responseBody(result)).get("qdrant_point_id").isNull()).isTrue();

        verify(qdrantDogVectorClient).upsertAll(anyList());
    }

    private Dog onlyDog() {
        List<Dog> dogs = dogRepository.findAll();
        assertThat(dogs).hasSize(1);
        return dogs.get(0);
    }

    private VerificationLog onlyVerificationLog() {
        List<VerificationLog> logs = verificationLogRepository.findAll();
        assertThat(logs).hasSize(1);
        return logs.get(0);
    }

    private MockHttpServletRequestBuilder validDogMultipart(Long userId) {
        return dogMultipart(userId, noseImages(5), "Bori", "Jindo", "MALE")
                .param("birth_date", "2024-01-01")
                .param("age", "3")
                .param("price", "250000")
                .param("description", "friendly")
                .param("health", "healthy");
    }

    private MockHttpServletRequestBuilder dogMultipart(
            Long userId,
            List<MockMultipartFile> noseImages,
            String name,
            String breed,
            String gender
    ) {
        MockMultipartHttpServletRequestBuilder builder = multipart("/api/dogs/register");
        if (noseImages != null) {
            noseImages.forEach(builder::file);
        }
        if (name != null) {
            builder.param("name", name);
        }
        if (breed != null) {
            builder.param("breed", breed);
        }
        if (gender != null) {
            builder.param("gender", gender);
        }
        if (userId != null) {
            builder.param("user_id", userId.toString());
        }
        return builder;
    }

    private MockHttpServletRequestBuilder legacyDogMultipart(
            String filename,
            String name,
            String breed,
            String gender
    ) {
        return multipart("/api/dogs/register")
                .file(new MockMultipartFile("nose_image", filename, "image/jpeg", new byte[]{1, 2, 3}))
                .param("name", name)
                .param("breed", breed)
                .param("gender", gender);
    }

    private List<MockMultipartFile> noseImages(int count) {
        List<MockMultipartFile> files = new java.util.ArrayList<>();
        for (int i = 1; i <= count; i++) {
            files.add(new MockMultipartFile(
                    "nose_images",
                    "nose_%d.jpg".formatted(i),
                    "image/jpeg",
                    new byte[]{1, 2, 3}
            ));
        }
        return files;
    }

    private void registerUser(String email) throws Exception {
        mockMvc.perform(post("/api/auth/register")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "email", email,
                                "password", "password123",
                                "display_name", "DogOwner",
                                "contact_phone", "01012341234",
                                "region", "Seoul"
                        ))))
                .andExpect(status().isCreated());
    }

    private String loginAccessToken(String email) throws Exception {
        MvcResult result = mockMvc.perform(post("/api/auth/login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "email", email,
                                "password", "password123"
                        ))))
                .andExpect(status().isOk())
                .andReturn();

        return objectMapper.readTree(responseBody(result))
                .get("access_token")
                .asText();
    }

    private String responseBody(MvcResult result) {
        return new String(result.getResponse().getContentAsByteArray(), StandardCharsets.UTF_8);
    }

    private String json(Object value) throws Exception {
        return objectMapper.writeValueAsString(value);
    }

    private String signedToken(Long userId, long expiresAt) throws Exception {
        String header = base64Url(json(Map.of("alg", "HS256", "typ", "JWT")).getBytes(StandardCharsets.UTF_8));
        String payload = base64Url(json(Map.of(
                "sub", userId.toString(),
                "email", "token-user@example.com",
                "role", "USER",
                "iat", Instant.now().getEpochSecond(),
                "exp", expiresAt
        )).getBytes(StandardCharsets.UTF_8));
        String signingInput = header + "." + payload;
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(TEST_JWT_SECRET.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
        return signingInput + "." + base64Url(mac.doFinal(signingInput.getBytes(StandardCharsets.UTF_8)));
    }

    private String base64Url(byte[] bytes) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    private void verifyPipelineNotStarted() {
        verify(embedClient, never()).embedBatch(anyList());
        verify(qdrantDogVectorClient, never()).searchReferencePoints(anyList(), anyInt(), anyDouble());
        verify(qdrantDogVectorClient, never()).upsertAll(anyList());
    }

    private void assertPipelineRowsAbsent() {
        assertThat(dogRepository.count()).isZero();
        assertThat(dogImageRepository.count()).isZero();
        assertThat(dogNoseReferenceRepository.count()).isZero();
        assertThat(verificationLogRepository.count()).isZero();
    }

    private List<EmbedClient.BatchEmbedItem> batchItems(List<List<Double>> vectors) {
        List<EmbedClient.BatchEmbedItem> items = new java.util.ArrayList<>();
        for (int i = 0; i < vectors.size(); i++) {
            items.add(new EmbedClient.BatchEmbedItem(i, "nose_%d.jpg".formatted(i + 1), vectors.get(i)));
        }
        return items;
    }

    private List<List<Double>> consistentVectors() {
        return List.of(
                vector(1.0, 0.0),
                vector(0.9, 0.1),
                vector(0.85, 0.15),
                vector(0.95, 0.05),
                vector(0.88, 0.12)
        );
    }

    private List<List<Double>> vectorsWithAveragePairwiseScore(double averagePairwiseScore) {
        double fifthVectorDot = ((10.0 * averagePairwiseScore) - 6.0) / 4.0;
        double fifthVectorY = Math.sqrt(1.0 - (fifthVectorDot * fifthVectorDot));
        return List.of(
                vector(1.0, 0.0),
                vector(1.0, 0.0),
                vector(1.0, 0.0),
                vector(1.0, 0.0),
                vector(fifthVectorDot, fifthVectorY)
        );
    }

    private List<Double> vector(double first, double second) {
        List<Double> values = new java.util.ArrayList<>();
        for (int i = 0; i < 128; i++) {
            values.add(0.0);
        }
        values.set(0, first);
        values.set(1, second);
        return values;
    }

    private QdrantDogVectorClient.QdrantVectorSearchResult vectorResult(String dogId, double score) {
        return new QdrantDogVectorClient.QdrantVectorSearchResult(
                "point-" + dogId,
                dogId,
                score,
                "REFERENCE",
                1L,
                1,
                "test-model",
                128,
                "rgb_resize224_bicubic_imagenet_l2_v1"
        );
    }

    private void saveCandidateDog(String dogId, String breed) {
        Dog dog = new Dog();
        dog.setId(dogId);
        dog.setOwnerUserId(999L);
        dog.setName("Candidate");
        dog.setBreed(breed);
        dog.setStatus(DogStatus.REGISTERED);
        dogRepository.saveAndFlush(dog);
    }
}
