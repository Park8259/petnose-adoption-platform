package com.petnose.api.controller;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.petnose.api.client.EmbedClient;
import com.petnose.api.client.QdrantDogVectorClient;
import com.petnose.api.client.QdrantDogVectorClient.QdrantVectorSearchResult;
import com.petnose.api.config.HandoverVerificationProperties;
import com.petnose.api.domain.entity.AdoptionPost;
import com.petnose.api.domain.entity.Dog;
import com.petnose.api.domain.entity.User;
import com.petnose.api.domain.enums.AdoptionPostStatus;
import com.petnose.api.domain.enums.DogGender;
import com.petnose.api.domain.enums.DogStatus;
import com.petnose.api.domain.enums.UserRole;
import com.petnose.api.repository.AdoptionPostRepository;
import com.petnose.api.repository.DogImageRepository;
import com.petnose.api.repository.DogRepository;
import com.petnose.api.repository.UserRepository;
import com.petnose.api.repository.VerificationLogRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;
import org.junit.jupiter.params.provider.EnumSource;
import org.junit.jupiter.params.provider.ValueSource;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.mock.mockito.MockBean;
import org.springframework.http.HttpHeaders;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.ResultActions;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.LocalDate;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.Base64;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.nullValue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.reset;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.when;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.multipart;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
class HandoverVerificationControllerTest {

    private static final String JWT_SECRET = "test-petnose-jwt-secret-change-me-32bytes";
    private static final String MODEL = "dog-nose-identification2:s101_224";
    private static final double MATCH_THRESHOLD = 0.65;
    private static final double AMBIGUOUS_THRESHOLD = 0.65;
    private static final int TOP_K = 5;
    private static final int VECTOR_DIMENSION = 128;

    private static final Set<String> RESPONSE_FIELDS = Set.of(
            "post_id",
            "expected_dog_id",
            "matched",
            "decision",
            "similarity_score",
            "threshold",
            "ambiguous_threshold",
            "top_match_is_expected",
            "model",
            "dimension",
            "message",
            "score_breakdown"
    );

    private static final Set<String> SCORE_BREAKDOWN_FIELDS = Set.of(
            "final_score",
            "max_reference_score",
            "top2_average_score",
            "centroid_score",
            "hit_count"
    );

    @Autowired
    private org.springframework.test.web.servlet.MockMvc mockMvc;

    @Autowired
    private ObjectMapper objectMapper;

    @Autowired
    private UserRepository userRepository;

    @Autowired
    private DogRepository dogRepository;

    @Autowired
    private DogImageRepository dogImageRepository;

    @Autowired
    private VerificationLogRepository verificationLogRepository;

    @Autowired
    private AdoptionPostRepository adoptionPostRepository;

    @Autowired
    private HandoverVerificationProperties handoverVerificationProperties;

    @MockBean
    private EmbedClient embedClient;

    @MockBean
    private QdrantDogVectorClient qdrantDogVectorClient;

    private int sequence;

    @BeforeEach
    void setUp() {
        adoptionPostRepository.deleteAll();
        verificationLogRepository.deleteAll();
        dogImageRepository.deleteAll();
        dogRepository.deleteAll();
        userRepository.deleteAll();
        reset(embedClient, qdrantDogVectorClient);
        handoverVerificationProperties.setMatchThreshold(MATCH_THRESHOLD);
        handoverVerificationProperties.setAmbiguousThreshold(AMBIGUOUS_THRESHOLD);
        handoverVerificationProperties.setTopK(TOP_K);
        sequence = 0;
    }

    @Test
    void handoverVerificationRequiresAuthorization() throws Exception {
        handoverRequest(null, 1L)
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"));

        verifyNoInteractions(embedClient, qdrantDogVectorClient);
    }

    @Test
    void handoverVerificationRejectsMalformedAuthorization() throws Exception {
        handoverRequestWithAuthorization("Token abc", 1L)
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"))
                .andExpect(jsonPath("$.details").value(nullValue()));

        verifyNoInteractions(embedClient, qdrantDogVectorClient);
    }

    @Test
    void handoverVerificationRejectsInvalidToken() throws Exception {
        handoverRequestWithAuthorization("Bearer invalid-token", 1L)
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"))
                .andExpect(jsonPath("$.details").value(nullValue()));

        verifyNoInteractions(embedClient, qdrantDogVectorClient);
    }

    @Test
    void handoverVerificationRejectsExpiredToken() throws Exception {
        User user = saveUser(true);

        handoverRequestWithAuthorization("Bearer " + signedToken(user.getId(), Instant.now().minusSeconds(60).getEpochSecond()), 1L)
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"))
                .andExpect(jsonPath("$.details").value(nullValue()));

        verifyNoInteractions(embedClient, qdrantDogVectorClient);
    }

    @Test
    void handoverVerificationReturnsUserNotFoundWhenTokenUserIsMissing() throws Exception {
        String token = signedToken(Long.MAX_VALUE, Instant.now().plusSeconds(3600).getEpochSecond());

        handoverRequest(token, 1L)
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error_code").value("USER_NOT_FOUND"))
                .andExpect(jsonPath("$.details").value(nullValue()));

        verifyNoInteractions(embedClient, qdrantDogVectorClient);
    }

    @Test
    void handoverVerificationRejectsInactiveUser() throws Exception {
        User user = saveUser(false);

        handoverRequest(tokenFor(user), 1L)
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.error_code").value("USER_INACTIVE"))
                .andExpect(jsonPath("$.details").value(nullValue()));

        verifyNoInteractions(embedClient, qdrantDogVectorClient);
    }

    @Test
    void handoverVerificationReturnsPostNotFoundWhenPostIsMissing() throws Exception {
        User user = saveUser(true);

        handoverRequest(tokenFor(user), 999999L)
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error_code").value("POST_NOT_FOUND"))
                .andExpect(jsonPath("$.details").value(nullValue()));

        verifyNoInteractions(embedClient, qdrantDogVectorClient);
    }

    @ParameterizedTest
    @EnumSource(value = AdoptionPostStatus.class, names = {"DRAFT", "COMPLETED", "CLOSED"})
    void handoverVerificationRejectsPostStatusesThatAreNotVerifiable(AdoptionPostStatus status) throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, status);

        handoverRequest(tokenFor(user), post.getId())
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("POST_NOT_VERIFIABLE"));

        verifyNoInteractions(embedClient, qdrantDogVectorClient);
    }

    @ParameterizedTest
    @EnumSource(value = AdoptionPostStatus.class, names = {"OPEN", "RESERVED"})
    void handoverVerificationAcceptsOpenAndReservedPosts(AdoptionPostStatus status) throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, status);
        mockEmbedding();
        mockExpectedDogReferenceSet(dog, 0.95);

        handoverRequest(tokenFor(user), post.getId())
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.decision").value("MATCHED"))
                .andExpect(jsonPath("$.matched").value(true));
    }

    @Test
    void handoverVerificationReturnsDogNotFoundWhenExpectedDogIsMissing() throws Exception {
        User user = saveUser(true);
        AdoptionPost post = savePost(user, UUID.randomUUID().toString(), AdoptionPostStatus.OPEN);

        handoverRequest(tokenFor(user), post.getId())
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error_code").value("DOG_NOT_FOUND"))
                .andExpect(jsonPath("$.details").value(nullValue()));

        verifyNoInteractions(embedClient, qdrantDogVectorClient);
    }

    @Test
    void handoverVerificationAcceptsRegisteredExpectedDog() throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN);
        mockEmbedding();
        mockExpectedDogReferenceSet(dog, MATCH_THRESHOLD);

        handoverRequest(tokenFor(user), post.getId())
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.decision").value("MATCHED"))
                .andExpect(jsonPath("$.matched").value(true));
    }

    @ParameterizedTest
    @EnumSource(value = DogStatus.class, names = {"PENDING", "DUPLICATE_SUSPECTED", "REJECTED", "ADOPTED", "INACTIVE"})
    void handoverVerificationRejectsExpectedDogStatusesThatAreNotRegistered(DogStatus dogStatus) throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, dogStatus);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN);

        handoverRequest(tokenFor(user), post.getId())
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("DOG_NOT_VERIFIED"))
                .andExpect(jsonPath("$.details").value(nullValue()));

        verifyNoInteractions(embedClient, qdrantDogVectorClient);
    }

    @Test
    void handoverVerificationReturnsNoseImageRequiredWhenMultipartFileIsMissing() throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN);

        handoverRequestWithAuthorization("Bearer " + tokenFor(user), post.getId(), null)
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("NOSE_IMAGE_REQUIRED"))
                .andExpect(jsonPath("$.details").value(nullValue()));

        verifyNoInteractions(embedClient, qdrantDogVectorClient);
    }

    @Test
    void handoverVerificationReturnsNoseImageRequiredWhenMultipartFileIsEmpty() throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN);

        handoverRequestWithFile(tokenFor(user), post.getId(), emptyNoseImage())
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("NOSE_IMAGE_REQUIRED"))
                .andExpect(jsonPath("$.details").value(nullValue()));

        verifyNoInteractions(embedClient, qdrantDogVectorClient);
    }

    @Test
    void handoverVerificationMapsUnreadableMultipartBytesToInvalidNoseImage() throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN);

        handoverRequestWithFile(tokenFor(user), post.getId(), unreadableNoseImage())
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.error_code").value("INVALID_NOSE_IMAGE"))
                .andExpect(jsonPath("$.details").value(nullValue()));

        verifyNoInteractions(embedClient, qdrantDogVectorClient);
    }

    @Test
    void handoverVerificationMapsEmbedUpstreamBadRequestToInvalidNoseImage() throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN);
        when(embedClient.embed(any(byte[].class), anyString(), anyString()))
                .thenThrow(new EmbedClient.EmbedClientException("invalid image", 400, "invalid", null));

        handoverRequestWithFile(tokenFor(user), post.getId(), textFileNoseImage())
                .andExpect(status().isUnprocessableEntity())
                .andExpect(jsonPath("$.error_code").value("INVALID_NOSE_IMAGE"))
                .andExpect(jsonPath("$.details").value(nullValue()));

        verifyNoInteractions(qdrantDogVectorClient);
    }

    @Test
    void handoverVerificationMapsEmbedNonBadRequestFailureToServiceUnavailable() throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN);
        when(embedClient.embed(any(byte[].class), anyString(), anyString()))
                .thenThrow(new EmbedClient.EmbedClientException("embed down", 503, "down", null));

        handoverRequest(tokenFor(user), post.getId())
                .andExpect(status().isServiceUnavailable())
                .andExpect(jsonPath("$.error_code").value("EMBED_SERVICE_UNAVAILABLE"))
                .andExpect(jsonPath("$.details").value(nullValue()));

        verifyNoInteractions(qdrantDogVectorClient);
    }

    @ParameterizedTest
    @ValueSource(strings = {"NULL", "EMPTY"})
    void handoverVerificationMapsNullOrEmptyEmbeddingVectorToEmptyEmbedding(String vectorCase) throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN);
        List<Double> vector = "NULL".equals(vectorCase) ? null : List.of();
        when(embedClient.embed(any(byte[].class), anyString(), anyString()))
                .thenReturn(new EmbedClient.EmbedResponse(vector, VECTOR_DIMENSION, MODEL));

        handoverRequest(tokenFor(user), post.getId())
                .andExpect(status().isServiceUnavailable())
                .andExpect(jsonPath("$.error_code").value("EMPTY_EMBEDDING"))
                .andExpect(jsonPath("$.details").value(nullValue()));

        verifyNoInteractions(qdrantDogVectorClient);
    }

    @Test
    void handoverVerificationMapsEmbeddingDimensionMismatch() throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN);
        when(embedClient.embed(any(byte[].class), anyString(), anyString()))
                .thenReturn(new EmbedClient.EmbedResponse(List.of(0.1, 0.2, 0.3), VECTOR_DIMENSION + 1, MODEL));

        handoverRequest(tokenFor(user), post.getId())
                .andExpect(status().isServiceUnavailable())
                .andExpect(jsonPath("$.error_code").value("EMBEDDING_DIMENSION_MISMATCH"))
                .andExpect(jsonPath("$.details").value(nullValue()));

        verifyNoInteractions(qdrantDogVectorClient);
    }

    @Test
    void handoverVerificationMapsQdrantSearchFailure() throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN);
        mockEmbedding();
        when(qdrantDogVectorClient.searchExpectedDogReferences(anyList(), eq(dog.getId()), eq(TOP_K)))
                .thenThrow(new QdrantDogVectorClient.QdrantClientException(
                        "qdrant down",
                        QdrantDogVectorClient.QdrantOperation.SEARCH,
                        503,
                        "down",
                        null
                ));

        handoverRequest(tokenFor(user), post.getId())
                .andExpect(status().isServiceUnavailable())
                .andExpect(jsonPath("$.error_code").value("QDRANT_SEARCH_FAILED"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void handoverVerificationReturnsMatchedWhenExpectedDogIsTopResultAboveThreshold() throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN);
        mockEmbedding();
        mockExpectedDogReferenceSetWithCentroid(dog, 0.91, 0.98231, 0.81769);

        MvcResult result = handoverRequest(tokenFor(user), post.getId())
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.post_id").value(post.getId()))
                .andExpect(jsonPath("$.expected_dog_id").value(dog.getId()))
                .andExpect(jsonPath("$.matched").value(true))
                .andExpect(jsonPath("$.decision").value("MATCHED"))
                .andExpect(jsonPath("$.similarity_score").value(0.98231))
                .andExpect(jsonPath("$.threshold").value(MATCH_THRESHOLD))
                .andExpect(jsonPath("$.ambiguous_threshold").value(AMBIGUOUS_THRESHOLD))
                .andExpect(jsonPath("$.top_match_is_expected").value(true))
                .andExpect(jsonPath("$.model").value(MODEL))
                .andExpect(jsonPath("$.dimension").value(VECTOR_DIMENSION))
                .andExpect(jsonPath("$.message").value("분양글에 등록된 강아지와 일치합니다."))
                .andExpect(jsonPath("$.score_breakdown.final_score").value(0.98231))
                .andExpect(jsonPath("$.score_breakdown.max_reference_score").value(0.98231))
                .andExpect(jsonPath("$.score_breakdown.top2_average_score").value(0.9))
                .andExpect(jsonPath("$.score_breakdown.centroid_score").value(0.91))
                .andExpect(jsonPath("$.score_breakdown.hit_count").value(2))
                .andReturn();

        assertResponseIsSafe(result);
        verify(qdrantDogVectorClient).searchExpectedDogReferences(anyList(), eq(dog.getId()), eq(TOP_K));
        verify(qdrantDogVectorClient).searchExpectedDogCentroid(anyList(), eq(dog.getId()));
    }

    @Test
    void handoverVerificationUsesExpectedDogReferenceSetAndDoesNotUseGlobalTopK() throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN);
        mockEmbedding();
        mockExpectedDogReferenceSet(dog, 0.95);

        handoverRequest(tokenFor(user), post.getId())
                .andExpect(status().isOk());

        verify(qdrantDogVectorClient).searchExpectedDogReferences(eq(List.of(0.1, 0.2, 0.3)), eq(dog.getId()), eq(TOP_K));
        verify(qdrantDogVectorClient).searchExpectedDogCentroid(eq(List.of(0.1, 0.2, 0.3)), eq(dog.getId()));
        verify(qdrantDogVectorClient, never()).searchExpectedDog(anyList(), anyString());
        verify(qdrantDogVectorClient, never()).search(anyList(), eq(TOP_K));
        verify(qdrantDogVectorClient, never()).search(anyList());
    }

    @ParameterizedTest
    @CsvSource({
            "0.80630887, MATCHED, true",
            "0.65, MATCHED, true",
            "0.6500001, MATCHED, true",
            "0.649999, NOT_MATCHED, false",
            "0.60, NOT_MATCHED, false",
            "0.59999, NOT_MATCHED, false"
    })
    void handoverVerificationAppliesExpectedDogReferenceDecisionBoundaries(
            double score,
            String expectedDecision,
            boolean expectedMatched
    ) throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN);
        mockEmbedding();
        mockExpectedDogReferenceSet(dog, score);

        MvcResult result = handoverRequest(tokenFor(user), post.getId())
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.decision").value(expectedDecision))
                .andExpect(jsonPath("$.matched").value(expectedMatched))
                .andExpect(jsonPath("$.top_match_is_expected").value(true))
                .andExpect(jsonPath("$.similarity_score").value(score))
                .andExpect(jsonPath("$.threshold").value(MATCH_THRESHOLD))
                .andExpect(jsonPath("$.ambiguous_threshold").value(AMBIGUOUS_THRESHOLD))
                .andReturn();

        assertResponseIsSafe(result);
    }

    @Test
    void handoverVerificationUsesCentroidScoreForDecisionWhenHigherThanReferences() throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN);
        mockEmbedding();
        mockExpectedDogReferenceSetWithCentroid(dog, 0.66, 0.58);

        MvcResult result = handoverRequest(tokenFor(user), post.getId())
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.decision").value("MATCHED"))
                .andExpect(jsonPath("$.matched").value(true))
                .andExpect(jsonPath("$.similarity_score").value(0.66))
                .andExpect(jsonPath("$.score_breakdown.final_score").value(0.66))
                .andExpect(jsonPath("$.score_breakdown.max_reference_score").value(0.58))
                .andExpect(jsonPath("$.score_breakdown.centroid_score").value(0.66))
                .andReturn();

        assertResponseIsSafe(result);
    }

    @Test
    void handoverVerificationReturnsNotMatchedBelowMatchThresholdUnderBinaryPolicy() throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN);
        mockEmbedding();
        mockExpectedDogReferenceSetWithCentroid(dog, 0.64, 0.63);

        MvcResult result = handoverRequest(tokenFor(user), post.getId())
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.decision").value("NOT_MATCHED"))
                .andExpect(jsonPath("$.matched").value(false))
                .andExpect(jsonPath("$.top_match_is_expected").value(true))
                .andExpect(jsonPath("$.similarity_score").value(0.64))
                .andExpect(jsonPath("$.threshold").value(MATCH_THRESHOLD))
                .andExpect(jsonPath("$.ambiguous_threshold").value(AMBIGUOUS_THRESHOLD))
                .andExpect(jsonPath("$.message").value("분양글에 등록된 강아지와 일치하지 않습니다. 거래 전 확인이 필요합니다."))
                .andReturn();

        assertResponseIsSafe(result);
    }

    @Test
    void handoverVerificationRejectsAmbiguousThresholdAboveMatchThreshold() throws Exception {
        handoverVerificationProperties.setAmbiguousThreshold(MATCH_THRESHOLD + 0.01);
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN);
        mockEmbedding();
        mockExpectedDogReferenceSet(dog, 0.70);

        handoverRequest(tokenFor(user), post.getId())
                .andExpect(status().isInternalServerError())
                .andExpect(jsonPath("$.error_code").value("INVALID_HANDOVER_VERIFICATION_THRESHOLD"));
    }

    @Test
    void handoverVerificationSkipsNonExpectedDogReferenceResultsWithoutLeakingIdentifiers() throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.RESERVED);
        String otherDogId = UUID.randomUUID().toString();
        mockEmbedding();
        when(qdrantDogVectorClient.searchExpectedDogReferences(anyList(), eq(dog.getId()), eq(TOP_K)))
                .thenReturn(List.of(
                        foreignReferenceResult("other-point", otherDogId, 0.99123),
                        referenceResult(dog, 0, 0.55)
                ));
        when(qdrantDogVectorClient.searchExpectedDogCentroid(anyList(), eq(dog.getId())))
                .thenReturn(List.of(
                        foreignCentroidResult("other-centroid", otherDogId, 0.99),
                        centroidResult(dog, 0.56)
                ));

        MvcResult result = handoverRequest(tokenFor(user), post.getId())
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.post_id").value(post.getId()))
                .andExpect(jsonPath("$.expected_dog_id").value(dog.getId()))
                .andExpect(jsonPath("$.matched").value(false))
                .andExpect(jsonPath("$.decision").value("NOT_MATCHED"))
                .andExpect(jsonPath("$.similarity_score").value(0.56))
                .andExpect(jsonPath("$.top_match_is_expected").value(true))
                .andExpect(jsonPath("$.score_breakdown.centroid_score").value(0.56))
                .andExpect(jsonPath("$.message").value("분양글에 등록된 강아지와 일치하지 않습니다. 거래 전 확인이 필요합니다."))
                .andReturn();

        assertResponseIsSafe(result);
        assertThat(responseBody(result)).doesNotContain(otherDogId, "other-point", "other-centroid");
    }

    @Test
    void handoverVerificationDoesNotLeakQdrantPayloadOrOtherDogIdentifiers() throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN);
        String otherPointId = "qdrant-private-point-id";
        String otherDogId = UUID.randomUUID().toString();
        String privateBreed = "private-payload-breed";
        String privateNosePath = "dogs/private-dog/nose/private-nose-image.jpg";
        mockEmbedding();
        when(qdrantDogVectorClient.searchExpectedDogReferences(anyList(), eq(dog.getId()), eq(TOP_K)))
                .thenReturn(List.of(
                        foreignReferenceResult(otherPointId, otherDogId, 0.99123),
                        referenceResult(dog, 0, 0.55)
                ));
        when(qdrantDogVectorClient.searchExpectedDogCentroid(anyList(), eq(dog.getId())))
                .thenReturn(List.of(centroidResult(dog, 0.56)));

        MvcResult result = handoverRequest(tokenFor(user), post.getId())
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.post_id").value(post.getId()))
                .andExpect(jsonPath("$.expected_dog_id").value(dog.getId()))
                .andExpect(jsonPath("$.matched").value(false))
                .andExpect(jsonPath("$.decision").value("NOT_MATCHED"))
                .andExpect(jsonPath("$.top_match_is_expected").value(true))
                .andReturn();

        assertResponseIsSafe(result);
        assertThat(responseBody(result)).doesNotContain(
                otherPointId,
                otherDogId,
                privateBreed,
                privateNosePath,
                "nose_image_path",
                "profile_image_url",
                "payload"
        );
    }

    @Test
    void handoverVerificationReturnsNoMatchCandidateWhenQdrantReturnsNoCandidates() throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.OPEN);
        mockEmbedding();
        when(qdrantDogVectorClient.searchExpectedDogReferences(anyList(), eq(dog.getId()), eq(TOP_K))).thenReturn(List.of());
        when(qdrantDogVectorClient.searchExpectedDogCentroid(anyList(), eq(dog.getId()))).thenReturn(List.of());

        MvcResult result = handoverRequest(tokenFor(user), post.getId())
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.matched").value(false))
                .andExpect(jsonPath("$.decision").value("NO_MATCH_CANDIDATE"))
                .andExpect(jsonPath("$.similarity_score").value(nullValue()))
                .andExpect(jsonPath("$.top_match_is_expected").value(false))
                .andExpect(jsonPath("$.score_breakdown.final_score").value(nullValue()))
                .andExpect(jsonPath("$.score_breakdown.max_reference_score").value(nullValue()))
                .andExpect(jsonPath("$.score_breakdown.top2_average_score").value(nullValue()))
                .andExpect(jsonPath("$.score_breakdown.centroid_score").value(nullValue()))
                .andExpect(jsonPath("$.score_breakdown.hit_count").value(0))
                .andExpect(jsonPath("$.message").value("일치 후보를 찾지 못했습니다. 비문 이미지를 다시 촬영해주세요."))
                .andReturn();

        assertResponseIsSafe(result);
    }

    @Test
    void successfulHandoverVerificationDoesNotPersistRecordsOrMutatePostOrDog() throws Exception {
        User user = saveUser(true);
        Dog dog = saveDog(user, DogStatus.REGISTERED);
        AdoptionPost post = savePost(user, dog, AdoptionPostStatus.RESERVED);
        PersistenceSnapshot before = snapshot(post, dog);
        mockEmbedding();
        mockExpectedDogReferenceSet(dog, 0.95);

        handoverRequest(tokenFor(user), post.getId())
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.decision").value("MATCHED"));

        assertNoPersistenceOrStatusMutation(before, post, dog);
    }

    private void mockEmbedding() {
        when(embedClient.embed(any(byte[].class), anyString(), anyString()))
                .thenReturn(new EmbedClient.EmbedResponse(List.of(0.1, 0.2, 0.3), VECTOR_DIMENSION, MODEL));
    }

    private void mockExpectedDogReferenceSet(Dog dog, double... referenceScores) {
        mockExpectedDogReferenceSetWithCentroid(dog, maxScore(referenceScores), referenceScores);
    }

    private void mockExpectedDogReferenceSetWithCentroid(Dog dog, double centroidScore, double... referenceScores) {
        when(qdrantDogVectorClient.searchExpectedDogReferences(anyList(), eq(dog.getId()), eq(TOP_K)))
                .thenReturn(referenceResults(dog, referenceScores));
        when(qdrantDogVectorClient.searchExpectedDogCentroid(anyList(), eq(dog.getId())))
                .thenReturn(List.of(centroidResult(dog, centroidScore)));
    }

    private double maxScore(double... scores) {
        double maxScore = 0.0;
        for (double score : scores) {
            maxScore = Math.max(maxScore, score);
        }
        return maxScore;
    }

    private List<QdrantVectorSearchResult> referenceResults(Dog dog, double... scores) {
        List<QdrantVectorSearchResult> results = new ArrayList<>();
        for (int i = 0; i < scores.length; i++) {
            results.add(referenceResult(dog, i, scores[i]));
        }
        return results;
    }

    private QdrantVectorSearchResult referenceResult(Dog dog, int referenceIndex, double score) {
        return new QdrantVectorSearchResult(
                "reference-point-" + referenceIndex,
                dog.getId(),
                score,
                "REFERENCE",
                (long) referenceIndex + 1,
                referenceIndex,
                MODEL,
                VECTOR_DIMENSION,
                "test-preprocess"
        );
    }

    private QdrantVectorSearchResult centroidResult(Dog dog, double score) {
        return new QdrantVectorSearchResult(
                "centroid-point",
                dog.getId(),
                score,
                "CENTROID",
                null,
                null,
                MODEL,
                VECTOR_DIMENSION,
                "test-preprocess"
        );
    }

    private QdrantVectorSearchResult foreignReferenceResult(String pointId, String dogId, double score) {
        return new QdrantVectorSearchResult(
                pointId,
                dogId,
                score,
                "REFERENCE",
                999L,
                0,
                MODEL,
                VECTOR_DIMENSION,
                "private-preprocess"
        );
    }

    private QdrantVectorSearchResult foreignCentroidResult(String pointId, String dogId, double score) {
        return new QdrantVectorSearchResult(
                pointId,
                dogId,
                score,
                "CENTROID",
                null,
                null,
                MODEL,
                VECTOR_DIMENSION,
                "private-preprocess"
        );
    }

    private ResultActions handoverRequest(String token, Long postId) throws Exception {
        return handoverRequestWithAuthorization(token == null ? null : "Bearer " + token, postId, noseImage());
    }

    private ResultActions handoverRequestWithFile(String token, Long postId, MockMultipartFile file) throws Exception {
        return handoverRequestWithAuthorization(token == null ? null : "Bearer " + token, postId, file);
    }

    private ResultActions handoverRequestWithAuthorization(String authorizationHeader, Long postId) throws Exception {
        return handoverRequestWithAuthorization(authorizationHeader, postId, noseImage());
    }

    private ResultActions handoverRequestWithAuthorization(
            String authorizationHeader,
            Long postId,
            MockMultipartFile file
    ) throws Exception {
        var request = multipart("/api/adoption-posts/{post_id}/handover-verifications", postId);
        if (file != null) {
            request.file(file);
        }
        if (authorizationHeader != null) {
            request.header(HttpHeaders.AUTHORIZATION, authorizationHeader);
        }
        return mockMvc.perform(request);
    }

    private MockMultipartFile noseImage() {
        return new MockMultipartFile(
                "nose_image",
                "handover.png",
                "image/png",
                new byte[]{1, 2, 3}
        );
    }

    private MockMultipartFile emptyNoseImage() {
        return new MockMultipartFile(
                "nose_image",
                "empty.png",
                "image/png",
                new byte[0]
        );
    }

    private MockMultipartFile textFileNoseImage() {
        return new MockMultipartFile(
                "nose_image",
                "not-a-nose.txt",
                "text/plain",
                "not an image".getBytes(StandardCharsets.UTF_8)
        );
    }

    private MockMultipartFile unreadableNoseImage() {
        return new MockMultipartFile(
                "nose_image",
                "handover.png",
                "image/png",
                new byte[]{1, 2, 3}
        ) {
            @Override
            public byte[] getBytes() throws IOException {
                throw new IOException("cannot read multipart bytes");
            }
        };
    }

    private User saveUser(boolean active) {
        User user = new User();
        user.setEmail("handover-%d@example.com".formatted(++sequence));
        user.setPasswordHash("hash");
        user.setRole(UserRole.USER);
        user.setDisplayName("Handover User");
        user.setContactPhone("01012341234");
        user.setRegion("Seoul");
        user.setActive(active);
        return userRepository.saveAndFlush(user);
    }

    private Dog saveDog(User owner, DogStatus status) {
        Dog dog = new Dog();
        dog.setId(UUID.randomUUID().toString());
        dog.setOwnerUserId(owner.getId());
        dog.setName("Choco");
        dog.setBreed("Maltese");
        dog.setGender(DogGender.MALE);
        dog.setBirthDate(LocalDate.of(2023, 1, 1));
        dog.setDescription("Handover verification test dog.");
        dog.setStatus(status);
        return dogRepository.saveAndFlush(dog);
    }

    private AdoptionPost savePost(User author, Dog dog, AdoptionPostStatus status) {
        return savePost(author, dog.getId(), status);
    }

    private AdoptionPost savePost(User author, String dogId, AdoptionPostStatus status) {
        AdoptionPost post = new AdoptionPost();
        post.setAuthorUserId(author.getId());
        post.setDogId(dogId);
        post.setTitle("Handover post");
        post.setContent("Handover verification content.");
        post.setStatus(status);
        if (status == AdoptionPostStatus.OPEN || status == AdoptionPostStatus.RESERVED || status == AdoptionPostStatus.COMPLETED) {
            post.setPublishedAt(LocalDateTime.now());
        }
        if (status == AdoptionPostStatus.CLOSED || status == AdoptionPostStatus.COMPLETED) {
            post.setClosedAt(LocalDateTime.now());
        }
        return adoptionPostRepository.saveAndFlush(post);
    }

    private void assertResponseIsSafe(MvcResult result) throws Exception {
        JsonNode body = objectMapper.readTree(responseBody(result));
        assertThat(fieldNames(body)).containsExactlyInAnyOrderElementsOf(RESPONSE_FIELDS);
        assertThat(fieldNames(body)).allMatch(name -> name.matches("[a-z0-9_]+"));
        JsonNode scoreBreakdown = body.get("score_breakdown");
        assertThat(scoreBreakdown).isNotNull();
        assertThat(fieldNames(scoreBreakdown)).containsExactlyInAnyOrderElementsOf(SCORE_BREAKDOWN_FIELDS);
        assertThat(fieldNames(scoreBreakdown)).allMatch(name -> name.matches("[a-z0-9_]+"));
        assertThat(responseBody(result)).doesNotContain(
                "nose_image_url",
                "nose_image_path",
                "top_matched_dog_id",
                "qdrant_point_id",
                "point_id",
                "dog_image_id",
                "reference_index",
                "payload",
                "author_user_id",
                "postId",
                "expectedDogId",
                "similarityScore",
                "topMatchIsExpected"
        );
    }

    private PersistenceSnapshot snapshot(AdoptionPost post, Dog dog) {
        AdoptionPost persistedPost = adoptionPostRepository.findById(post.getId()).orElseThrow();
        Dog persistedDog = dogRepository.findById(dog.getId()).orElseThrow();
        return new PersistenceSnapshot(
                adoptionPostRepository.count(),
                dogRepository.count(),
                dogImageRepository.count(),
                verificationLogRepository.count(),
                persistedPost.getStatus(),
                persistedPost.getDogId(),
                persistedPost.getAuthorUserId(),
                persistedDog.getStatus()
        );
    }

    private void assertNoPersistenceOrStatusMutation(PersistenceSnapshot before, AdoptionPost post, Dog dog) {
        assertThat(adoptionPostRepository.count()).isEqualTo(before.postCount());
        assertThat(dogRepository.count()).isEqualTo(before.dogCount());
        assertThat(dogImageRepository.count()).isEqualTo(before.dogImageCount());
        assertThat(verificationLogRepository.count()).isEqualTo(before.verificationLogCount());

        AdoptionPost reloadedPost = adoptionPostRepository.findById(post.getId()).orElseThrow();
        Dog reloadedDog = dogRepository.findById(dog.getId()).orElseThrow();
        assertThat(reloadedPost.getStatus()).isEqualTo(before.postStatus());
        assertThat(reloadedPost.getDogId()).isEqualTo(before.postDogId());
        assertThat(reloadedPost.getAuthorUserId()).isEqualTo(before.authorUserId());
        assertThat(reloadedDog.getStatus()).isEqualTo(before.dogStatus());
    }

    private String tokenFor(User user) throws Exception {
        return signedToken(user.getId(), Instant.now().plusSeconds(3600).getEpochSecond());
    }

    private String signedToken(Long userId, long expiresAt) throws Exception {
        String header = encodeJson(Map.of("alg", "HS256", "typ", "JWT"));
        String payload = encodeJson(Map.of(
                "sub", userId.toString(),
                "exp", expiresAt
        ));
        String signingInput = header + "." + payload;
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(JWT_SECRET.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
        String signature = Base64.getUrlEncoder().withoutPadding()
                .encodeToString(mac.doFinal(signingInput.getBytes(StandardCharsets.UTF_8)));
        return signingInput + "." + signature;
    }

    private String encodeJson(Map<String, Object> value) throws Exception {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(objectMapper.writeValueAsBytes(value));
    }

    private String responseBody(MvcResult result) {
        return new String(result.getResponse().getContentAsByteArray(), StandardCharsets.UTF_8);
    }

    private Set<String> fieldNames(JsonNode node) {
        Set<String> names = new LinkedHashSet<>();
        node.fieldNames().forEachRemaining(names::add);
        return names;
    }

    private record PersistenceSnapshot(
            long postCount,
            long dogCount,
            long dogImageCount,
            long verificationLogCount,
            AdoptionPostStatus postStatus,
            String postDogId,
            Long authorUserId,
            DogStatus dogStatus
    ) {
    }
}
