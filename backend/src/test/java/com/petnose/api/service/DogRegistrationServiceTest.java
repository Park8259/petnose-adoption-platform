package com.petnose.api.service;

import com.petnose.api.client.EmbedClient;
import com.petnose.api.client.QdrantDogVectorClient;
import com.petnose.api.domain.entity.Dog;
import com.petnose.api.domain.entity.DogImage;
import com.petnose.api.domain.entity.User;
import com.petnose.api.domain.entity.VerificationLog;
import com.petnose.api.domain.enums.DogStatus;
import com.petnose.api.domain.enums.VerificationResult;
import com.petnose.api.dto.registration.DogRegisterRequest;
import com.petnose.api.dto.registration.DogRegisterResponse;
import com.petnose.api.dto.registration.QdrantSearchResult;
import com.petnose.api.repository.DogImageRepository;
import com.petnose.api.repository.DogRepository;
import com.petnose.api.repository.UserRepository;
import com.petnose.api.repository.VerificationLogRepository;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.PlatformTransactionManager;
import org.springframework.transaction.TransactionDefinition;
import org.springframework.transaction.TransactionStatus;
import org.springframework.transaction.support.SimpleTransactionStatus;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicLong;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.lenient;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class DogRegistrationServiceTest {

    @Mock
    private UserRepository userRepository;
    @Mock
    private DogRepository dogRepository;
    @Mock
    private DogImageRepository dogImageRepository;
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
    private final AtomicLong dogImageIds = new AtomicLong(1);
    private final AtomicLong verificationLogIds = new AtomicLong(1);

    private DogRegistrationService service;

    @BeforeEach
    void setUp() {
        service = new DogRegistrationService(
                userRepository,
                dogRepository,
                dogImageRepository,
                verificationLogRepository,
                fileStorageService,
                embedClient,
                qdrantDogVectorClient,
                new NoseVerificationPolicy(0.70),
                transactionTemplate()
        );
        ReflectionTestUtils.setField(service, "expectedVectorDimension", 2048);

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
        lenient().when(dogImageRepository.findById(any())).thenAnswer(invocation ->
                Optional.ofNullable(dogImages.get(invocation.getArgument(0)))
        );

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
                .thenReturn(storedFile("dogs/dog-1/nose/nose.jpg"));
        when(fileStorageService.toPublicUrl(anyString())).thenAnswer(invocation -> "/files/" + invocation.getArgument(0));
    }

    @Test
    void registerStoresNormalResultInVerificationLogAndCalculatesResponseFields() {
        List<Double> vector = List.of(0.1, 0.2, 0.3);
        when(embedClient.embed(any(byte[].class), anyString(), anyString()))
                .thenReturn(new EmbedClient.EmbedResponse(vector, 2048, "dog-nose-identification2:s101_224"));
        when(qdrantDogVectorClient.search(vector))
                .thenReturn(List.of(new QdrantSearchResult("other-point", "other-dog", 0.12345, "Jindo", "dogs/other/nose.jpg")));

        DogRegisterResponse response = service.register(request());

        Dog dog = dogs.get(response.dogId());
        VerificationLog log = onlyVerificationLog();

        assertThat(dog.getStatus()).isEqualTo(DogStatus.REGISTERED);
        assertThat(log.getResult()).isEqualTo(VerificationResult.PASSED);
        assertThat(log.getSimilarityScore()).isEqualByComparingTo(new BigDecimal("0.12345"));
        assertThat(log.getCandidateDogId()).isNull();
        assertThat(log.getModel()).isEqualTo("dog-nose-identification2:s101_224");
        assertThat(log.getDimension()).isEqualTo(2048);
        assertThat(log.getSubmittedImagePath()).isEqualTo("dogs/dog-1/nose/nose.jpg");

        assertThat(response.registrationAllowed()).isTrue();
        assertThat(response.status()).isEqualTo("REGISTERED");
        assertThat(response.verificationStatus()).isEqualTo("VERIFIED");
        assertThat(response.embeddingStatus()).isEqualTo("COMPLETED");
        assertThat(response.qdrantPointId()).isEqualTo(response.dogId());
        assertThat(response.profileImageUrl()).isNull();

        verify(qdrantDogVectorClient).upsert(eq(response.dogId()), eq(vector), anyMap());
    }

    @Test
    void registerStoresDuplicateResultInVerificationLogAndSkipsQdrantUpsert() {
        List<Double> vector = List.of(0.4, 0.5, 0.6);
        when(embedClient.embed(any(byte[].class), anyString(), anyString()))
                .thenReturn(new EmbedClient.EmbedResponse(vector, 2048, "dog-nose-identification2:s101_224"));
        when(qdrantDogVectorClient.search(vector))
                .thenReturn(List.of(new QdrantSearchResult("candidate-point", "candidate-dog", 0.98765, "Maltese", "dogs/candidate/nose.jpg")));

        DogRegisterResponse response = service.register(request());

        Dog dog = dogs.get(response.dogId());
        VerificationLog log = onlyVerificationLog();

        assertThat(dog.getStatus()).isEqualTo(DogStatus.DUPLICATE_SUSPECTED);
        assertThat(log.getResult()).isEqualTo(VerificationResult.DUPLICATE_SUSPECTED);
        assertThat(log.getSimilarityScore()).isEqualByComparingTo(new BigDecimal("0.98765"));
        assertThat(log.getCandidateDogId()).isEqualTo("candidate-dog");
        assertThat(log.getModel()).isEqualTo("dog-nose-identification2:s101_224");
        assertThat(log.getDimension()).isEqualTo(2048);
        assertThat(log.getSubmittedImagePath()).isEqualTo("dogs/dog-1/nose/nose.jpg");

        assertThat(response.registrationAllowed()).isFalse();
        assertThat(response.status()).isEqualTo("DUPLICATE_SUSPECTED");
        assertThat(response.verificationStatus()).isEqualTo("DUPLICATE_SUSPECTED");
        assertThat(response.embeddingStatus()).isEqualTo("SKIPPED_DUPLICATE");
        assertThat(response.qdrantPointId()).isNull();
        assertThat(response.profileImageUrl()).isNull();
        assertThat(response.topMatch().dogId()).isEqualTo("candidate-dog");
        assertThat(response.topMatch().similarityScore()).isEqualTo(0.98765);
        assertThat(response.topMatch().breed()).isEqualTo("Maltese");

        verify(qdrantDogVectorClient, never()).upsert(anyString(), anyList(), anyMap());
    }

    @Test
    void registerTreatsScoreAtZeroPointSevenAsDuplicateAndSkipsQdrantUpsert() {
        List<Double> vector = List.of(0.4, 0.5, 0.6);
        when(embedClient.embed(any(byte[].class), anyString(), anyString()))
                .thenReturn(new EmbedClient.EmbedResponse(vector, 2048, "dog-nose-identification2:s101_224"));
        when(qdrantDogVectorClient.search(vector))
                .thenReturn(List.of(new QdrantSearchResult("candidate-point", "candidate-dog", 0.70, "Maltese", "dogs/candidate/nose.jpg")));

        DogRegisterResponse response = service.register(request());

        assertThat(response.registrationAllowed()).isFalse();
        assertThat(response.status()).isEqualTo("DUPLICATE_SUSPECTED");
        assertThat(response.verificationStatus()).isEqualTo("DUPLICATE_SUSPECTED");
        assertThat(response.embeddingStatus()).isEqualTo("SKIPPED_DUPLICATE");
        assertThat(response.qdrantPointId()).isNull();
        assertThat(response.topMatch().similarityScore()).isEqualTo(0.70);
        assertThat(onlyVerificationLog().getSimilarityScore()).isEqualByComparingTo(new BigDecimal("0.70000"));

        verify(qdrantDogVectorClient, never()).upsert(anyString(), anyList(), anyMap());
    }

    @Test
    void registerTreatsScoreBelowZeroPointSevenAsNormalAndUpsertsQdrantPoint() {
        List<Double> vector = List.of(0.4, 0.5, 0.6);
        when(embedClient.embed(any(byte[].class), anyString(), anyString()))
                .thenReturn(new EmbedClient.EmbedResponse(vector, 2048, "dog-nose-identification2:s101_224"));
        when(qdrantDogVectorClient.search(vector))
                .thenReturn(List.of(new QdrantSearchResult("candidate-point", "candidate-dog", 0.69999, "Maltese", "dogs/candidate/nose.jpg")));

        DogRegisterResponse response = service.register(request());

        assertThat(response.registrationAllowed()).isTrue();
        assertThat(response.status()).isEqualTo("REGISTERED");
        assertThat(response.verificationStatus()).isEqualTo("VERIFIED");
        assertThat(response.embeddingStatus()).isEqualTo("COMPLETED");
        assertThat(response.qdrantPointId()).isEqualTo(response.dogId());
        assertThat(response.topMatch()).isNull();
        assertThat(onlyVerificationLog().getSimilarityScore()).isEqualByComparingTo(new BigDecimal("0.69999"));

        verify(qdrantDogVectorClient).upsert(eq(response.dogId()), eq(vector), anyMap());
    }

    private VerificationLog onlyVerificationLog() {
        assertThat(verificationLogs).hasSize(1);
        return verificationLogs.values().iterator().next();
    }

    private DogRegisterRequest request() {
        return new DogRegisterRequest(
                1L,
                "Bori",
                "Jindo",
                "MALE",
                "2024-01-01",
                "friendly",
                multipart("nose_image", "nose.jpg")
        );
    }

    private static MockMultipartFile multipart(String name, String filename) {
        return new MockMultipartFile(name, filename, "image/jpeg", new byte[]{1, 2, 3});
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
