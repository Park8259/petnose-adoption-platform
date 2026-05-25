package com.petnose.api.service;

import com.petnose.api.client.EmbedClient;
import com.petnose.api.client.QdrantDogVectorClient;
import com.petnose.api.domain.entity.Dog;
import com.petnose.api.domain.entity.DogImage;
import com.petnose.api.domain.entity.User;
import com.petnose.api.domain.entity.VerificationLog;
import com.petnose.api.domain.enums.*;
import com.petnose.api.dto.registration.DogRegisterRequest;
import com.petnose.api.dto.registration.DogRegisterResponse;
import com.petnose.api.dto.registration.DuplicateCandidateResponse;
import com.petnose.api.dto.registration.QdrantSearchResult;
import com.petnose.api.exception.ApiException;
import com.petnose.api.repository.DogImageRepository;
import com.petnose.api.repository.DogRepository;
import com.petnose.api.repository.UserRepository;
import com.petnose.api.repository.VerificationLogRepository;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;

import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.Instant;
import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

@Slf4j
@Service
@RequiredArgsConstructor
public class DogRegistrationService {

    private final UserRepository userRepository;
    private final DogRepository dogRepository;
    private final DogImageRepository dogImageRepository;
    private final VerificationLogRepository verificationLogRepository;
    private final FileStorageService fileStorageService;
    private final EmbedClient embedClient;
    private final QdrantDogVectorClient qdrantDogVectorClient;
    private final NoseVerificationPolicy noseVerificationPolicy;
    private final TransactionTemplate transactionTemplate;

    @Value("${qdrant.vector-dimension}")
    private int expectedVectorDimension;

    public DogRegisterResponse register(DogRegisterRequest request) {
        validateRequiredFields(request);

        User user = userRepository.findById(request.userId())
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "USER_NOT_FOUND", "존재하지 않는 user_id 입니다."));

        String dogId = UUID.randomUUID().toString();
        LocalDate birthDate = parseBirthDate(request.birthDate());

        FileStorageService.StoredFile noseStored = fileStorageService.storeNoseImage(dogId, request.noseImage());

        PendingRegistration pending = transactionTemplate.execute(status ->
                createPendingRows(user.getId(), dogId, request, birthDate, noseStored)
        );
        if (pending == null) {
            throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "REGISTRATION_INIT_FAILED", "등록 초기화에 실패했습니다.");
        }

        EmbedClient.EmbedResponse embedResponse = requestEmbeddingOrFail(pending, noseStored);
        validateEmbeddingDimensionOrFail(pending, embedResponse);

        List<QdrantSearchResult> searchResults = searchFromQdrantOrFail(pending, embedResponse);
        NoseVerificationPolicy.VerificationDecision decision = noseVerificationPolicy.evaluate(searchResults);

        if (decision.duplicate()) {
            transactionTemplate.executeWithoutResult(status ->
                    markAsDuplicateSuspected(pending, embedResponse, decision)
            );
            return buildDuplicateResponse(pending, embedResponse, decision);
        }

        upsertToQdrantOrFail(pending, request, embedResponse, noseStored.relativePath());

        transactionTemplate.executeWithoutResult(status ->
                markAsRegistered(pending, embedResponse, decision.maxScore())
        );
        return buildRegisteredResponse(
                pending,
                embedResponse,
                decision.maxScore(),
                noseStored.relativePath()
        );
    }

    private PendingRegistration createPendingRows(
            Long userId,
            String dogId,
            DogRegisterRequest request,
            LocalDate birthDate,
            FileStorageService.StoredFile noseStored
    ) {
        Dog dog = new Dog();
        dog.setId(dogId);
        dog.setOwnerUserId(userId);
        dog.setName(request.name().trim());
        dog.setBreed(request.breed().trim());
        dog.setGender(DogGender.from(request.gender()));
        dog.setBirthDate(birthDate);
        dog.setDescription(blankToNull(request.description()));
        dog.setStatus(DogStatus.PENDING);
        dogRepository.save(dog);

        DogImage noseImage = buildDogImage(dogId, DogImageType.NOSE, noseStored);
        dogImageRepository.save(noseImage);

        VerificationLog verificationLog = new VerificationLog();
        verificationLog.setDogId(dogId);
        verificationLog.setDogImageId(noseImage.getId());
        verificationLog.setRequestedByUserId(userId);
        verificationLog.setSubmittedImagePath(noseStored.relativePath());
        verificationLog.setSubmittedImageMimeType(noseStored.mimeType());
        verificationLog.setSubmittedImageFileSize(noseStored.fileSize());
        verificationLog.setSubmittedImageSha256(noseStored.sha256());
        verificationLog.setPurpose(VerificationPurpose.DOG_REGISTRATION);
        verificationLog.setResult(VerificationResult.PENDING);
        verificationLogRepository.save(verificationLog);

        return new PendingRegistration(dogId, noseImage.getId(), verificationLog.getId());
    }

    private DogImage buildDogImage(String dogId, DogImageType imageType, FileStorageService.StoredFile storedFile) {
        DogImage image = new DogImage();
        image.setDogId(dogId);
        image.setImageType(imageType);
        image.setFilePath(storedFile.relativePath());
        image.setMimeType(storedFile.mimeType());
        image.setFileSize(storedFile.fileSize());
        image.setSha256(storedFile.sha256());
        return image;
    }

    private EmbedClient.EmbedResponse requestEmbeddingOrFail(PendingRegistration pending, FileStorageService.StoredFile noseStored) {
        try {
            return embedClient.embed(noseStored.bytes(), noseStored.originalFilename(), noseStored.mimeType());
        } catch (EmbedClient.EmbedClientException e) {
            log.warn("[DogRegistration] embed 실패: dogId={}, upstreamStatus={}, message={}",
                    pending.dogId(), e.getUpstreamStatus(), e.getMessage());
            transactionTemplate.executeWithoutResult(status ->
                    markAsFailed(
                            pending,
                            VerificationResult.EMBED_FAILED,
                            null,
                            null,
                            "embed 실패: " + e.getMessage()
                    )
            );

            if (e.getUpstreamStatus() != null && e.getUpstreamStatus() == 400) {
                throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "INVALID_NOSE_IMAGE", "비문 이미지 처리에 실패했습니다.");
            }
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "EMBED_SERVICE_UNAVAILABLE", "임베딩 서비스를 사용할 수 없습니다.");
        }
    }

    private void validateEmbeddingDimensionOrFail(PendingRegistration pending, EmbedClient.EmbedResponse embedResponse) {
        if (embedResponse.vector() == null || embedResponse.vector().isEmpty()) {
            transactionTemplate.executeWithoutResult(status ->
                    markAsFailed(
                            pending,
                            VerificationResult.EMBED_FAILED,
                            null,
                            null,
                            "embed vector가 비어 있습니다."
                    )
            );
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "EMPTY_EMBEDDING", "임베딩 결과가 비어 있습니다.");
        }
        if (embedResponse.dimension() != expectedVectorDimension) {
            transactionTemplate.executeWithoutResult(status ->
                    markAsFailed(
                            pending,
                            VerificationResult.EMBED_FAILED,
                            embedResponse.model(),
                            embedResponse.dimension(),
                            "dimension mismatch: expected=%d actual=%d".formatted(expectedVectorDimension, embedResponse.dimension())
                    )
            );
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "EMBEDDING_DIMENSION_MISMATCH", "임베딩 차원이 시스템 설정과 일치하지 않습니다.");
        }
    }

    private List<QdrantSearchResult> searchFromQdrantOrFail(PendingRegistration pending, EmbedClient.EmbedResponse embedResponse) {
        try {
            return qdrantDogVectorClient.search(embedResponse.vector());
        } catch (QdrantDogVectorClient.QdrantClientException e) {
            log.warn("[DogRegistration] qdrant search 실패: dogId={}, status={}, message={}",
                    pending.dogId(), e.getUpstreamStatus(), e.getMessage());
            transactionTemplate.executeWithoutResult(status ->
                    markAsFailed(
                            pending,
                            VerificationResult.QDRANT_SEARCH_FAILED,
                            embedResponse.model(),
                            embedResponse.dimension(),
                            "qdrant search 실패: " + e.getMessage()
                    )
            );
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "QDRANT_SEARCH_FAILED", "중복 검증 검색에 실패했습니다.");
        }
    }

    private void upsertToQdrantOrFail(
            PendingRegistration pending,
            DogRegisterRequest request,
            EmbedClient.EmbedResponse embedResponse,
            String noseImagePath
    ) {
        Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("dog_id", pending.dogId());
        payload.put("user_id", request.userId());
        payload.put("breed", request.breed());
        payload.put("nose_image_path", noseImagePath);
        payload.put("registered_at", Instant.now().toString());
        payload.put("is_active", true);

        try {
            qdrantDogVectorClient.upsert(pending.dogId(), embedResponse.vector(), payload);
        } catch (QdrantDogVectorClient.QdrantClientException e) {
            log.warn("[DogRegistration] qdrant upsert 실패: dogId={}, status={}, message={}",
                    pending.dogId(), e.getUpstreamStatus(), e.getMessage());
            transactionTemplate.executeWithoutResult(status -> {
                markAsFailed(
                        pending,
                        VerificationResult.QDRANT_UPSERT_FAILED,
                        embedResponse.model(),
                        embedResponse.dimension(),
                        "qdrant upsert 실패: " + e.getMessage()
                );
            });
            // TODO: 재처리 배치(qdrant_sync_jobs 등) 도입 시 QDRANT_SYNC_FAILED 건을 자동 재시도하도록 확장.
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "QDRANT_UPSERT_FAILED", "벡터 인덱스 동기화에 실패했습니다.");
        }
    }

    private void markAsDuplicateSuspected(
            PendingRegistration pending,
            EmbedClient.EmbedResponse embedResponse,
            NoseVerificationPolicy.VerificationDecision decision
    ) {
        Dog dog = getDogOrThrow(pending.dogId());
        dog.setStatus(DogStatus.DUPLICATE_SUSPECTED);
        dogRepository.save(dog);

        VerificationLog logEntity = getVerificationLogOrThrow(pending.verificationLogId());
        logEntity.setResult(VerificationResult.DUPLICATE_SUSPECTED);
        logEntity.setSimilarityScore(toScore(decision.maxScore()));
        logEntity.setCandidateDogId(decision.topMatch() != null ? decision.topMatch().dogId() : null);
        logEntity.setModel(embedResponse.model());
        logEntity.setDimension(embedResponse.dimension());
        verificationLogRepository.save(logEntity);
    }

    private void markAsRegistered(PendingRegistration pending, EmbedClient.EmbedResponse embedResponse, double maxScore) {
        Dog dog = getDogOrThrow(pending.dogId());
        dog.setStatus(DogStatus.REGISTERED);
        dogRepository.save(dog);

        VerificationLog logEntity = getVerificationLogOrThrow(pending.verificationLogId());
        logEntity.setResult(VerificationResult.PASSED);
        logEntity.setSimilarityScore(toScore(maxScore));
        logEntity.setModel(embedResponse.model());
        logEntity.setDimension(embedResponse.dimension());
        verificationLogRepository.save(logEntity);
    }

    private void markAsFailed(
            PendingRegistration pending,
            VerificationResult verificationResult,
            String model,
            Integer dimension,
            String failureReason
    ) {
        Dog dog = getDogOrThrow(pending.dogId());
        dog.setStatus(DogStatus.REJECTED);
        dogRepository.save(dog);

        VerificationLog logEntity = getVerificationLogOrThrow(pending.verificationLogId());
        logEntity.setResult(verificationResult);
        logEntity.setModel(model);
        logEntity.setDimension(dimension);
        logEntity.setFailureReason(failureReason);
        verificationLogRepository.save(logEntity);
    }

    private DogRegisterResponse buildRegisteredResponse(
            PendingRegistration pending,
            EmbedClient.EmbedResponse embedResponse,
            double maxScore,
            String noseImageRelativePath
    ) {
        VerificationResult result = VerificationResult.PASSED;
        return new DogRegisterResponse(
                pending.dogId(),
                true,
                DogStatus.REGISTERED.name(),
                toVerificationStatus(result),
                toEmbeddingStatus(result),
                pending.dogId(),
                embedResponse.model(),
                embedResponse.dimension(),
                maxScore,
                fileStorageService.toPublicUrl(noseImageRelativePath),
                null,
                null,
                "중복 의심 개체가 없어 등록이 완료되었습니다."
        );
    }

    private DogRegisterResponse buildDuplicateResponse(
            PendingRegistration pending,
            EmbedClient.EmbedResponse embedResponse,
            NoseVerificationPolicy.VerificationDecision decision
    ) {
        DuplicateCandidateResponse topMatch = null;
        if (decision.topMatch() != null) {
            QdrantSearchResult t = decision.topMatch();
            topMatch = new DuplicateCandidateResponse(
                    t.dogId(),
                    t.score(),
                    t.breed()
            );
        }

        VerificationResult result = VerificationResult.DUPLICATE_SUSPECTED;
        return new DogRegisterResponse(
                pending.dogId(),
                false,
                DogStatus.DUPLICATE_SUSPECTED.name(),
                toVerificationStatus(result),
                toEmbeddingStatus(result),
                null,
                embedResponse.model(),
                embedResponse.dimension(),
                decision.maxScore(),
                fileStorageService.toPublicUrl(getNoseImagePath(pending.noseImageId())),
                null,
                topMatch,
                "기존 등록견과 동일 개체로 의심되어 등록이 제한됩니다."
        );
    }

    private String toVerificationStatus(VerificationResult result) {
        return switch (result) {
            case PASSED -> "VERIFIED";
            case DUPLICATE_SUSPECTED -> "DUPLICATE_SUSPECTED";
            case REVIEW_REQUIRED -> "REVIEW_REQUIRED";
            case PENDING -> "PENDING";
            case EMBED_FAILED, QDRANT_SEARCH_FAILED, QDRANT_UPSERT_FAILED -> "FAILED";
        };
    }

    private String toEmbeddingStatus(VerificationResult result) {
        return switch (result) {
            case PASSED -> "COMPLETED";
            case DUPLICATE_SUSPECTED -> "SKIPPED_DUPLICATE";
            case REVIEW_REQUIRED -> "SKIPPED_REVIEW";
            case PENDING -> "PENDING";
            case EMBED_FAILED, QDRANT_SEARCH_FAILED -> "FAILED";
            case QDRANT_UPSERT_FAILED -> "QDRANT_SYNC_FAILED";
        };
    }

    private String getNoseImagePath(Long noseImageId) {
        return dogImageRepository.findById(noseImageId)
                .map(DogImage::getFilePath)
                .orElseThrow(() -> new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "DOG_IMAGE_NOT_FOUND", "비문 이미지 정보를 찾을 수 없습니다."));
    }

    private Dog getDogOrThrow(String dogId) {
        return dogRepository.findById(dogId)
                .orElseThrow(() -> new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "DOG_NOT_FOUND", "강아지 정보를 찾을 수 없습니다."));
    }

    private VerificationLog getVerificationLogOrThrow(Long verificationLogId) {
        return verificationLogRepository.findById(verificationLogId)
                .orElseThrow(() -> new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "VERIFICATION_LOG_NOT_FOUND", "검증 로그를 찾을 수 없습니다."));
    }

    private void validateRequiredFields(DogRegisterRequest request) {
        if (request.userId() == null) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "USER_ID_REQUIRED", "user_id는 필수입니다.");
        }
        if (request.name() == null || request.name().isBlank()) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "NAME_REQUIRED", "name은 필수입니다.");
        }
        if (request.breed() == null || request.breed().isBlank()) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "BREED_REQUIRED", "breed는 필수입니다.");
        }
        DogGender.from(request.gender());
        if (request.noseImage() == null || request.noseImage().isEmpty()) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "NOSE_IMAGE_REQUIRED", "nose_image는 필수입니다.");
        }
    }

    private LocalDate parseBirthDate(String birthDate) {
        if (birthDate == null || birthDate.isBlank()) {
            return null;
        }
        try {
            return LocalDate.parse(birthDate);
        } catch (DateTimeParseException e) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "INVALID_BIRTH_DATE", "birth_date는 YYYY-MM-DD 형식이어야 합니다.");
        }
    }

    private String blankToNull(String value) {
        if (value == null || value.isBlank()) {
            return null;
        }
        return value.trim();
    }

    private BigDecimal toScore(double score) {
        return BigDecimal.valueOf(score).setScale(5, RoundingMode.HALF_UP);
    }

    private record PendingRegistration(
            String dogId,
            Long noseImageId,
            Long verificationLogId
    ) {
    }
}
