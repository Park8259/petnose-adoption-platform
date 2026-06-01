package com.petnose.api.service;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.petnose.api.client.EmbedClient;
import com.petnose.api.client.QdrantDogVectorClient;
import com.petnose.api.config.NoseRegistrationProperties;
import com.petnose.api.domain.entity.Dog;
import com.petnose.api.domain.entity.DogImage;
import com.petnose.api.domain.entity.DogNoseReference;
import com.petnose.api.domain.entity.User;
import com.petnose.api.domain.entity.VerificationLog;
import com.petnose.api.domain.enums.DogNoseEmbeddingKind;
import com.petnose.api.domain.enums.DogStatus;
import com.petnose.api.domain.enums.VerificationResult;
import com.petnose.api.dto.registration.DogRegisterRequest;
import com.petnose.api.dto.registration.DogRegisterResponse;
import com.petnose.api.exception.ApiException;
import com.petnose.api.repository.DogImageRepository;
import com.petnose.api.repository.DogNoseReferenceRepository;
import com.petnose.api.repository.DogRepository;
import com.petnose.api.repository.UserRepository;
import com.petnose.api.repository.VerificationLogRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.mockito.junit.jupiter.MockitoSettings;
import org.mockito.quality.Strictness;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.TransactionStatus;
import org.springframework.transaction.support.SimpleTransactionStatus;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.assertj.core.api.Assertions.within;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyDouble;
import static org.mockito.ArgumentMatchers.anyInt;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.Mockito.doAnswer;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
@MockitoSettings(strictness = Strictness.LENIENT)
class DogRegistrationServiceTest {

    private static final String MODEL = "dog-nose-identification2:s101_224";

    @Mock
    private UserRepository userRepository;
    @Mock
    private DogRepository dogRepository;
    @Mock
    private DogImageRepository dogImageRepository;
    @Mock
    private DogNoseReferenceRepository dogNoseReferenceRepository;
    @Mock
    private VerificationLogRepository verificationLogRepository;
    @Mock
    private FileStorageService fileStorageService;
    @Mock
    private EmbedClient embedClient;
    @Mock
    private QdrantDogVectorClient qdrantDogVectorClient;

    private final Map<String, Dog> dogs = new HashMap<>();
    private final Map<Long, DogImage> dogImages = new HashMap<>();
    private final Map<Long, VerificationLog> verificationLogs = new HashMap<>();
    private final List<DogNoseReference> dogNoseReferences = new ArrayList<>();
    private final AtomicLong dogImageIds = new AtomicLong(1);
    private final AtomicLong verificationLogIds = new AtomicLong(1);
    private final AtomicInteger storedFileIndex = new AtomicInteger(1);

    private DogRegistrationService service;

    @BeforeEach
    void setUp() {
        NoseRegistrationProperties properties = new NoseRegistrationProperties();
        service = new DogRegistrationService(
                userRepository,
                dogRepository,
                dogImageRepository,
                dogNoseReferenceRepository,
                verificationLogRepository,
                fileStorageService,
                embedClient,
                qdrantDogVectorClient,
                properties,
                new ObjectMapper(),
                transactionTemplate()
        );
        ReflectionTestUtils.setField(service, "expectedVectorDimension", 3);
        ReflectionTestUtils.setField(service, "qdrantSearchTopK", 5);
        ReflectionTestUtils.setField(service, "qdrantSearchScoreThreshold", 0.55);

        User user = new User();
        user.setId(1L);
        user.setEmail("user@example.com");
        user.setPasswordHash("hash");
        when(userRepository.findById(1L)).thenReturn(Optional.of(user));

        when(dogRepository.save(any(Dog.class))).thenAnswer(invocation -> {
            Dog dog = invocation.getArgument(0);
            dogs.put(dog.getId(), dog);
            return dog;
        });
        when(dogRepository.findById(anyString())).thenAnswer(invocation ->
                Optional.ofNullable(dogs.get(invocation.getArgument(0)))
        );

        when(dogImageRepository.save(any(DogImage.class))).thenAnswer(invocation -> {
            DogImage image = invocation.getArgument(0);
            if (image.getId() == null) {
                image.setId(dogImageIds.getAndIncrement());
            }
            dogImages.put(image.getId(), image);
            return image;
        });

        when(verificationLogRepository.save(any(VerificationLog.class))).thenAnswer(invocation -> {
            VerificationLog log = invocation.getArgument(0);
            if (log.getId() == null) {
                log.setId(verificationLogIds.getAndIncrement());
            }
            verificationLogs.put(log.getId(), log);
            return log;
        });
        when(verificationLogRepository.findById(any())).thenAnswer(invocation ->
                Optional.ofNullable(verificationLogs.get(invocation.getArgument(0)))
        );

        when(fileStorageService.storeNoseImage(anyString(), any()))
                .thenAnswer(invocation -> storedFile(
                        "dogs/%s/nose/nose_%d.jpg".formatted(
                                invocation.getArgument(0),
                                storedFileIndex.getAndIncrement()
                        )
                ));
        when(fileStorageService.toPublicUrl(anyString())).thenAnswer(invocation -> "/files/" + invocation.getArgument(0));

        doAnswer(invocation -> {
            Iterable<DogNoseReference> references = invocation.getArgument(0);
            references.forEach(dogNoseReferences::add);
            return references;
        }).when(dogNoseReferenceRepository).saveAll(any());

        when(qdrantDogVectorClient.searchReferencePoints(anyList(), anyInt(), anyDouble())).thenReturn(List.of());
        when(qdrantDogVectorClient.searchCentroidPoints(anyList(), anyInt(), anyDouble())).thenReturn(List.of());
    }

    @Test
    void registerWithFiveNoseImagesCreatesReferencesAndUpsertsReferenceAndCentroidPoints() {
        when(embedClient.embedBatch(anyList())).thenReturn(batchResponse(consistentVectors()));

        DogRegisterResponse response = service.register(request(noseImages(5)));

        Dog dog = dogs.get(response.dogId());
        VerificationLog log = onlyVerificationLog();

        assertThat(dog.getStatus()).isEqualTo(DogStatus.REGISTERED);
        assertThat(dogImages).hasSize(5);
        assertThat(log.getResult()).isEqualTo(VerificationResult.PASSED);
        assertThat(log.getSimilarityScore()).isEqualByComparingTo(new BigDecimal("0.00000"));
        assertThat(log.getScoreBreakdownJson()).contains("\"policy\":\"max_reference_or_centroid_v1\"");
        assertThat(log.getScoreBreakdownJson()).contains("\"reference_quality\":{\"verdict\":\"ACCEPTED\"");

        assertThat(response.registrationAllowed()).isTrue();
        assertThat(response.status()).isEqualTo("REGISTERED");
        assertThat(response.embeddingStatus()).isEqualTo("COMPLETED");
        assertThat(response.qdrantPointId()).isNull();
        assertThat(response.embeddingMode()).isEqualTo("MULTI_REFERENCE");
        assertThat(response.referenceCount()).isEqualTo(5);
        assertThat(response.noseImageUrls()).hasSize(5);
        assertThat(response.noseImageUrl()).isEqualTo(response.noseImageUrls().get(0));
        assertThat(response.scoreBreakdown().referenceConsistencyScore()).isGreaterThanOrEqualTo(0.55);

        ArgumentCaptor<List<QdrantDogVectorClient.QdrantPointUpsertRequest>> upsertCaptor = ArgumentCaptor.forClass(List.class);
        verify(qdrantDogVectorClient).upsertAll(upsertCaptor.capture());
        assertThat(upsertCaptor.getValue()).hasSize(6);
        assertThat(upsertCaptor.getValue())
                .extracting(point -> point.payload().get("embedding_kind"))
                .containsExactly("REFERENCE", "REFERENCE", "REFERENCE", "REFERENCE", "REFERENCE", "CENTROID");

        assertThat(dogNoseReferences).hasSize(6);
        assertThat(dogNoseReferences)
                .extracting(DogNoseReference::getEmbeddingKind)
                .containsExactly(
                        DogNoseEmbeddingKind.REFERENCE,
                        DogNoseEmbeddingKind.REFERENCE,
                        DogNoseEmbeddingKind.REFERENCE,
                        DogNoseEmbeddingKind.REFERENCE,
                        DogNoseEmbeddingKind.REFERENCE,
                        DogNoseEmbeddingKind.CENTROID
                );
    }

    @Test
    void registerRejectsMissingNoseImagesBeforeEmbedAndRows() {
        assertThatThrownBy(() -> service.register(request(null)))
                .isInstanceOfSatisfying(ApiException.class, e ->
                        assertThat(e.getErrorCode()).isEqualTo("NOSE_IMAGES_REQUIRED"));

        assertNoPipelineRows();
        verify(embedClient, never()).embedBatch(anyList());
        verify(qdrantDogVectorClient, never()).upsertAll(anyList());
    }

    @Test
    void registerRejectsNonFiveNoseImageCountsBeforeEmbedAndRows() {
        for (int actualCount : List.of(2, 3, 4, 6)) {
            assertThatThrownBy(() -> service.register(request(noseImages(actualCount))))
                    .isInstanceOfSatisfying(ApiException.class, e -> {
                        assertThat(e.getErrorCode()).isEqualTo("NOSE_IMAGES_COUNT_INVALID");
                        assertThat(e.getMessage()).isEqualTo("비문 기준 이미지는 정확히 5장이 필요합니다.");
                        assertThat(e.getDetails()).containsEntry("expected_count", 5);
                        assertThat(e.getDetails()).containsEntry("actual_count", actualCount);
                    });
        }

        assertNoPipelineRows();
        verify(embedClient, never()).embedBatch(anyList());
        verify(qdrantDogVectorClient, never()).upsertAll(anyList());
    }

    @Test
    void registerRejectsInconsistentReferencesWithRetakeAllBeforeFileDbAndQdrantSideEffects() {
        when(embedClient.embedBatch(anyList())).thenReturn(batchResponse(List.of(
                List.of(1.0, 0.0, 0.0),
                List.of(-1.0, 0.0, 0.0),
                List.of(0.0, -1.0, 0.0),
                List.of(0.0, 0.0, -1.0),
                List.of(-0.5, -0.5, 0.0)
        )));

        assertThatThrownBy(() -> service.register(request(noseImages(5))))
                .isInstanceOfSatisfying(ApiException.class, e -> {
                    assertThat(e.getErrorCode()).isEqualTo("NOSE_REFERENCE_INCONSISTENT");
                    assertThat(e.getDetails()).containsEntry("quality_verdict", "RETAKE_ALL");
                    assertThat(e.getDetails()).containsKey("weakest_image_index");
                    assertThat(e.getDetails()).containsKey("pairwise_scores");
                    assertThat(e.getMessage()).contains("5장을 같은 거리와 각도로 다시 촬영");
                });

        assertNoPipelineRows();
        verify(fileStorageService, never()).storeNoseImage(anyString(), any());
        verify(qdrantDogVectorClient, never()).searchReferencePoints(anyList(), anyInt(), anyDouble());
        verify(qdrantDogVectorClient, never()).upsertAll(anyList());
    }

    @Test
    void warnAcceptedReferencesDoNotBlockRegistrationAndPersistQualitySummary() {
        when(embedClient.embedBatch(anyList())).thenReturn(batchResponse(vectorsWithAveragePairwiseScore(0.56)));

        DogRegisterResponse response = service.register(request(noseImages(5)));

        assertThat(response.status()).isEqualTo("REGISTERED");
        assertThat(response.scoreBreakdown().referenceConsistencyScore()).isCloseTo(0.56, within(1.0e-12));
        assertThat(onlyVerificationLog().getResult()).isEqualTo(VerificationResult.PASSED);
        assertThat(onlyVerificationLog().getScoreBreakdownJson()).contains("\"reference_quality\":{\"verdict\":\"WARN_ACCEPTED\"");
    }

    @Test
    void registerRejectsReferencesWithRetakeOneDetailsBelowCalibratedConsistencyThreshold() {
        when(embedClient.embedBatch(anyList())).thenReturn(batchResponse(vectorsWithAveragePairwiseScore(0.54)));

        assertThatThrownBy(() -> service.register(request(noseImages(5))))
                .isInstanceOfSatisfying(ApiException.class, e -> {
                    assertThat(e.getErrorCode()).isEqualTo("NOSE_REFERENCE_INCONSISTENT");
                    assertThat(e.getDetails()).containsEntry("quality_verdict", "RETAKE_ONE");
                    assertThat(e.getDetails()).containsEntry("weakest_image_index", 5);
                    assertThat(e.getDetails()).containsEntry("best_subset_indexes", List.of(1, 2, 3, 4));
                    assertThat(e.getDetails()).containsKey("pairwise_scores");
                    assertThat(e.getMessage()).contains("5번째 비문 이미지");
                });

        assertNoPipelineRows();
        verify(fileStorageService, never()).storeNoseImage(anyString(), any());
        verify(dogRepository, never()).save(any(Dog.class));
        verify(qdrantDogVectorClient, never()).upsertAll(anyList());
        verify(qdrantDogVectorClient, never()).searchReferencePoints(anyList(), anyInt(), anyDouble());
    }

    @Test
    void registerDuplicateSuspectedStoresRowsAndSkipsQdrantUpsert() {
        Dog candidate = candidateDog("candidate-dog", "Maltese");
        dogs.put(candidate.getId(), candidate);
        when(embedClient.embedBatch(anyList())).thenReturn(batchResponse(consistentVectors()));
        when(qdrantDogVectorClient.searchReferencePoints(anyList(), anyInt(), anyDouble()))
                .thenReturn(List.of(vectorResult("candidate-dog", 0.80)));

        DogRegisterResponse response = service.register(request(noseImages(5)));

        Dog dog = dogs.get(response.dogId());
        VerificationLog log = onlyVerificationLog();

        assertThat(dog.getStatus()).isEqualTo(DogStatus.DUPLICATE_SUSPECTED);
        assertThat(dogImages).hasSize(5);
        assertThat(dogNoseReferences).isEmpty();
        assertThat(log.getResult()).isEqualTo(VerificationResult.DUPLICATE_SUSPECTED);
        assertThat(log.getSimilarityScore()).isEqualByComparingTo(new BigDecimal("0.80000"));
        assertThat(log.getCandidateDogId()).isEqualTo("candidate-dog");

        assertThat(response.registrationAllowed()).isFalse();
        assertThat(response.status()).isEqualTo("DUPLICATE_SUSPECTED");
        assertThat(response.embeddingStatus()).isEqualTo("SKIPPED_DUPLICATE");
        assertThat(response.topMatch().dogId()).isEqualTo("candidate-dog");
        assertThat(response.topMatch().similarityScore()).isEqualTo(0.80);
        assertThat(response.topMatch().breed()).isEqualTo("Maltese");

        verify(qdrantDogVectorClient, never()).upsertAll(anyList());
    }

    @Test
    void registerBelowDuplicateThresholdRegistersAndUpsertsQdrant() {
        Dog candidate = candidateDog("candidate-dog", "Jindo");
        dogs.put(candidate.getId(), candidate);
        when(embedClient.embedBatch(anyList())).thenReturn(batchResponse(consistentVectors()));
        when(qdrantDogVectorClient.searchReferencePoints(anyList(), anyInt(), anyDouble()))
                .thenReturn(List.of(vectorResult("candidate-dog", 0.649999)));

        DogRegisterResponse response = service.register(request(noseImages(5)));

        Dog dog = dogs.get(response.dogId());
        VerificationLog log = onlyVerificationLog();

        assertThat(dog.getStatus()).isEqualTo(DogStatus.REGISTERED);
        assertThat(dogImages).hasSize(5);
        assertThat(dogNoseReferences).hasSize(6);
        assertThat(log.getResult()).isEqualTo(VerificationResult.PASSED);
        assertThat(log.getSimilarityScore()).isEqualByComparingTo(new BigDecimal("0.65000"));

        assertThat(response.registrationAllowed()).isTrue();
        assertThat(response.status()).isEqualTo("REGISTERED");
        assertThat(response.embeddingStatus()).isEqualTo("COMPLETED");
        assertThat(response.topMatch().dogId()).isEqualTo("candidate-dog");
        assertThat(response.topMatch().breed()).isEqualTo("Jindo");

        verify(qdrantDogVectorClient).upsertAll(anyList());
    }

    @Test
    void registerDuplicateDecisionUsesCentroidWhenHigherThanMaxReferenceScore() {
        Dog candidate = candidateDog("candidate-dog", "Maltese");
        dogs.put(candidate.getId(), candidate);
        when(embedClient.embedBatch(anyList())).thenReturn(batchResponse(consistentVectors()));
        when(qdrantDogVectorClient.searchReferencePoints(anyList(), anyInt(), anyDouble()))
                .thenReturn(List.of(vectorResult("candidate-dog", 0.58)));
        when(qdrantDogVectorClient.searchCentroidPoints(anyList(), anyInt(), anyDouble()))
                .thenReturn(List.of(centroidResult("candidate-dog", 0.66)));

        DogRegisterResponse response = service.register(request(noseImages(5)));

        assertThat(response.status()).isEqualTo("DUPLICATE_SUSPECTED");
        assertThat(response.scoreBreakdown().finalScore()).isEqualTo(0.66);
        assertThat(response.scoreBreakdown().maxReferenceScore()).isEqualTo(0.58);
        assertThat(response.scoreBreakdown().centroidScore()).isEqualTo(0.66);
        assertThat(onlyVerificationLog().getSimilarityScore()).isEqualByComparingTo(new BigDecimal("0.66000"));
        verify(qdrantDogVectorClient, never()).upsertAll(anyList());
    }

    @Test
    void registerPassesWhenCentroidScoreIsBelowDuplicateThreshold() {
        Dog candidate = candidateDog("candidate-dog", "Jindo");
        dogs.put(candidate.getId(), candidate);
        when(embedClient.embedBatch(anyList())).thenReturn(batchResponse(consistentVectors()));
        when(qdrantDogVectorClient.searchReferencePoints(anyList(), anyInt(), anyDouble()))
                .thenReturn(List.of(vectorResult("candidate-dog", 0.58)));
        when(qdrantDogVectorClient.searchCentroidPoints(anyList(), anyInt(), anyDouble()))
                .thenReturn(List.of(centroidResult("candidate-dog", 0.62)));

        DogRegisterResponse response = service.register(request(noseImages(5)));

        assertThat(response.status()).isEqualTo("REGISTERED");
        assertThat(response.registrationAllowed()).isTrue();
        assertThat(response.embeddingStatus()).isEqualTo("COMPLETED");
        assertThat(response.scoreBreakdown().finalScore()).isEqualTo(0.62);
        assertThat(response.scoreBreakdown().maxReferenceScore()).isEqualTo(0.58);
        assertThat(response.scoreBreakdown().centroidScore()).isEqualTo(0.62);
        assertThat(onlyVerificationLog().getSimilarityScore()).isEqualByComparingTo(new BigDecimal("0.62000"));
        assertThat(onlyVerificationLog().getResult()).isEqualTo(VerificationResult.PASSED);
        verify(qdrantDogVectorClient).upsertAll(anyList());
    }

    @Test
    void registerPassesWhenCompositeScoreIsWellBelowDuplicateThreshold() {
        Dog candidate = candidateDog("candidate-dog", "Poodle");
        dogs.put(candidate.getId(), candidate);
        when(embedClient.embedBatch(anyList())).thenReturn(batchResponse(consistentVectors()));
        when(qdrantDogVectorClient.searchReferencePoints(anyList(), anyInt(), anyDouble()))
                .thenReturn(List.of(vectorResult("candidate-dog", 0.50)));
        when(qdrantDogVectorClient.searchCentroidPoints(anyList(), anyInt(), anyDouble()))
                .thenReturn(List.of(centroidResult("candidate-dog", 0.59)));

        DogRegisterResponse response = service.register(request(noseImages(5)));

        assertThat(response.status()).isEqualTo("REGISTERED");
        assertThat(response.scoreBreakdown().finalScore()).isEqualTo(0.59);
        assertThat(response.scoreBreakdown().maxReferenceScore()).isEqualTo(0.50);
        assertThat(response.scoreBreakdown().centroidScore()).isEqualTo(0.59);
        assertThat(onlyVerificationLog().getSimilarityScore()).isEqualByComparingTo(new BigDecimal("0.59000"));
        verify(qdrantDogVectorClient).upsertAll(anyList());
    }

    @Test
    void registerDeletesQdrantPointsWhenReferenceRowsFailAfterUpsert() {
        when(embedClient.embedBatch(anyList())).thenReturn(batchResponse(consistentVectors()));
        doThrow(new RuntimeException("db down"))
                .when(dogNoseReferenceRepository).saveAll(any());

        assertThatThrownBy(() -> service.register(request(noseImages(5))))
                .isInstanceOfSatisfying(ApiException.class, e ->
                        assertThat(e.getErrorCode()).isEqualTo("QDRANT_UPSERT_FAILED"));

        verify(qdrantDogVectorClient).upsertAll(anyList());
        ArgumentCaptor<List<String>> deleteCaptor = ArgumentCaptor.forClass(List.class);
        verify(qdrantDogVectorClient).deletePoints(deleteCaptor.capture());
        assertThat(deleteCaptor.getValue()).hasSize(6);
        assertThat(onlyVerificationLog().getResult()).isEqualTo(VerificationResult.QDRANT_UPSERT_FAILED);
    }

    private VerificationLog onlyVerificationLog() {
        assertThat(verificationLogs).hasSize(1);
        return verificationLogs.values().iterator().next();
    }

    private void assertNoPipelineRows() {
        assertThat(dogs).isEmpty();
        assertThat(dogImages).isEmpty();
        assertThat(verificationLogs).isEmpty();
        assertThat(dogNoseReferences).isEmpty();
    }

    private DogRegisterRequest request(List<MockMultipartFile> noseImages) {
        return new DogRegisterRequest(
                1L,
                "Bori",
                "Jindo",
                "MALE",
                "2024-01-01",
                "friendly",
                noseImages == null ? null : List.copyOf(noseImages)
        );
    }

    private static List<MockMultipartFile> noseImages(int count) {
        List<MockMultipartFile> images = new ArrayList<>();
        for (int i = 1; i <= count; i++) {
            images.add(new MockMultipartFile(
                    "nose_images",
                    "nose_%d.jpg".formatted(i),
                    "image/jpeg",
                    new byte[]{1, 2, 3}
            ));
        }
        return images;
    }

    private static EmbedClient.BatchEmbedResponse batchResponse(List<List<Double>> vectors) {
        List<EmbedClient.BatchEmbedItem> items = new ArrayList<>();
        for (int i = 0; i < vectors.size(); i++) {
            items.add(new EmbedClient.BatchEmbedItem(i, "nose_%d.jpg".formatted(i + 1), vectors.get(i)));
        }
        return new EmbedClient.BatchEmbedResponse(items, 3, MODEL);
    }

    private static List<List<Double>> consistentVectors() {
        return List.of(
                List.of(1.0, 0.0, 0.0),
                List.of(0.9, 0.1, 0.0),
                List.of(0.85, 0.15, 0.0),
                List.of(0.95, 0.05, 0.0),
                List.of(0.88, 0.12, 0.0)
        );
    }

    private static List<List<Double>> vectorsWithAveragePairwiseScore(double averagePairwiseScore) {
        double fifthVectorDot = ((10.0 * averagePairwiseScore) - 6.0) / 4.0;
        double fifthVectorY = Math.sqrt(1.0 - (fifthVectorDot * fifthVectorDot));
        return List.of(
                List.of(1.0, 0.0, 0.0),
                List.of(1.0, 0.0, 0.0),
                List.of(1.0, 0.0, 0.0),
                List.of(1.0, 0.0, 0.0),
                List.of(fifthVectorDot, fifthVectorY, 0.0)
        );
    }

    private static QdrantDogVectorClient.QdrantVectorSearchResult vectorResult(String dogId, double score) {
        return new QdrantDogVectorClient.QdrantVectorSearchResult(
                "point-%s".formatted(dogId),
                dogId,
                score,
                "REFERENCE",
                99L,
                1,
                MODEL,
                3,
                "rgb_resize224_bicubic_imagenet_l2_v1"
        );
    }

    private static QdrantDogVectorClient.QdrantVectorSearchResult centroidResult(String dogId, double score) {
        return new QdrantDogVectorClient.QdrantVectorSearchResult(
                "centroid-%s".formatted(dogId),
                dogId,
                score,
                "CENTROID",
                null,
                null,
                MODEL,
                3,
                "rgb_resize224_bicubic_imagenet_l2_v1"
        );
    }

    private static Dog candidateDog(String dogId, String breed) {
        Dog dog = new Dog();
        dog.setId(dogId);
        dog.setOwnerUserId(99L);
        dog.setName("Candidate");
        dog.setBreed(breed);
        dog.setStatus(DogStatus.REGISTERED);
        return dog;
    }

    private static FileStorageService.StoredFile storedFile(String relativePath) {
        return new FileStorageService.StoredFile(
                relativePath,
                "image/jpeg",
                3L,
                "hash",
                "image.jpg",
                new byte[]{1, 2, 3}
        );
    }

    private static TransactionTemplate transactionTemplate() {
        return new TransactionTemplate(new PlatformTransactionManager() {
            @Override
            public TransactionStatus getTransaction(TransactionDefinition definition) {
                return new SimpleTransactionStatus();
            }

            @Override
            public void commit(TransactionStatus status) {
            }

            @Override
            public void rollback(TransactionStatus status) {
            }
        });
    }
}
