package com.petnose.api.service;

import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.petnose.api.client.EmbedClient;
import com.petnose.api.client.QdrantDogVectorClient;
import com.petnose.api.config.NoseRegistrationProperties;
import com.petnose.api.config.ProfileNoseMatchProperties;
import com.petnose.api.domain.entity.Dog;
import com.petnose.api.domain.entity.DogImage;
import com.petnose.api.domain.entity.DogNoseReference;
import com.petnose.api.domain.entity.User;
import com.petnose.api.domain.entity.VerificationLog;
import com.petnose.api.domain.enums.DogGender;
import com.petnose.api.domain.enums.DogImageType;
import com.petnose.api.domain.enums.DogNoseEmbeddingKind;
import com.petnose.api.domain.enums.DogStatus;
import com.petnose.api.domain.enums.NoseReferenceQualityStatus;
import com.petnose.api.domain.enums.VerificationPurpose;
import com.petnose.api.domain.enums.VerificationResult;
import com.petnose.api.dto.registration.DogNoseVerificationResponse;
import com.petnose.api.dto.registration.DogProfileDraftRequest;
import com.petnose.api.dto.registration.DogProfileDraftResponse;
import com.petnose.api.dto.registration.DogRegisterRequest;
import com.petnose.api.dto.registration.DogRegisterResponse;
import com.petnose.api.dto.registration.DuplicateCandidateResponse;
import com.petnose.api.dto.registration.ProfileMatchScoreResponse;
import com.petnose.api.dto.registration.ProfileNosePreviewResponse;
import com.petnose.api.dto.registration.ScoreBreakdownResponse;
import com.petnose.api.exception.ApiException;
import com.petnose.api.repository.DogImageRepository;
import com.petnose.api.repository.DogNoseReferenceRepository;
import com.petnose.api.repository.DogRepository;
import com.petnose.api.repository.UserRepository;
import com.petnose.api.repository.VerificationLogRepository;
import com.petnose.api.service.nose.DogNoseCandidateAggregator;
import com.petnose.api.service.nose.DogNoseCandidateAggregator.DogNoseAggregationResult;
import com.petnose.api.service.nose.DogNoseCandidateAggregator.DogNoseCandidateScore;
import com.petnose.api.service.nose.DogNoseDecisionPolicy;
import com.petnose.api.service.nose.DogNoseDecisionPolicy.DogNoseDecision;
import com.petnose.api.service.nose.DogNoseScoreBreakdown;
import com.petnose.api.service.nose.NoseReferenceQualityAnalyzer;
import com.petnose.api.service.nose.NoseReferenceQualityAnalyzer.LeaveOneOutSubset;
import com.petnose.api.service.nose.NoseReferenceQualityAnalyzer.PairwiseScore;
import com.petnose.api.service.nose.NoseReferenceQualityAnalyzer.PerImageQuality;
import com.petnose.api.service.nose.NoseReferenceQualityAnalyzer.ReferenceQualityReport;
import com.petnose.api.service.nose.NoseReferenceQualityAnalyzer.ReferenceQualityVerdict;
import com.petnose.api.service.nose.NoseVectorMath;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.support.TransactionTemplate;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.math.BigDecimal;
import java.math.RoundingMode;
import java.time.Instant;
import java.time.LocalDate;
import java.time.format.DateTimeParseException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;

@Slf4j
@Service
@RequiredArgsConstructor
public class DogRegistrationService {

    private static final String EMBEDDING_MODE_MULTI_REFERENCE = "MULTI_REFERENCE";
    private static final String SCORE_POLICY = DogNoseScoreBreakdown.MAX_REFERENCE_OR_CENTROID_POLICY;
    private static final String PROFILE_NOSE_MISMATCH = "PROFILE_NOSE_MISMATCH";
    private static final String PROFILE_FIRST_DISABLED = "PROFILE_FIRST_DISABLED";
    private static final String DETECTOR_UNAVAILABLE = "DETECTOR_UNAVAILABLE";
    private static final String MEDIAN_AGGREGATE = "median";

    private final UserRepository userRepository;
    private final DogRepository dogRepository;
    private final DogImageRepository dogImageRepository;
    private final DogNoseReferenceRepository dogNoseReferenceRepository;
    private final VerificationLogRepository verificationLogRepository;
    private final FileStorageService fileStorageService;
    private final EmbedClient embedClient;
    private final QdrantDogVectorClient qdrantDogVectorClient;
    private final NoseRegistrationProperties noseRegistrationProperties;
    private final ProfileNoseMatchProperties profileNoseMatchProperties;
    private final ObjectMapper objectMapper;
    private final TransactionTemplate transactionTemplate;

    private final DogNoseCandidateAggregator dogNoseCandidateAggregator = new DogNoseCandidateAggregator();
    private final DogNoseDecisionPolicy dogNoseDecisionPolicy = new DogNoseDecisionPolicy();
    private final NoseReferenceQualityAnalyzer noseReferenceQualityAnalyzer = new NoseReferenceQualityAnalyzer();

    @Value("${qdrant.vector-dimension}")
    private int expectedVectorDimension;

    @Value("${qdrant.search-top-k:5}")
    private int qdrantSearchTopK;

    @Value("${qdrant.search-score-threshold:0.55}")
    private double qdrantSearchScoreThreshold;

    @Value("${petnose.profile-first.enabled:false}")
    private boolean profileFirstEnabled;

    @Value("${petnose.registration-timing-log-enabled:true}")
    private boolean registrationTimingLogEnabled;

    public DogProfileDraftResponse createProfileDraft(DogProfileDraftRequest request) {
        requireProfileFirstEnabled();
        validateRequiredFields(new DogRegisterRequest(
                request.userId(),
                request.name(),
                request.breed(),
                request.gender(),
                request.birthDate(),
                null,
                null,
                request.description(),
                null,
                null
        ));
        LocalDate birthDate = parseBirthDate(request.birthDate());
        User user = loadActiveUserOrThrow(request.userId());
        String dogId = UUID.randomUUID().toString();

        FileStorageService.StoredFile storedProfile = fileStorageService.storeProfileImage(dogId, request.profileImage());
        try {
            Boolean created = transactionTemplate.execute(status -> {
                createProfileDraftRows(user.getId(), dogId, request, birthDate, storedProfile);
                return Boolean.TRUE;
            });
            if (!Boolean.TRUE.equals(created)) {
                fileStorageService.deleteStoredFileQuietly(storedProfile);
                throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "PROFILE_DRAFT_CREATE_FAILED", "프로필 임시 등록에 실패했습니다.");
            }
        } catch (RuntimeException e) {
            fileStorageService.deleteStoredFileQuietly(storedProfile);
            throw e;
        }

        ProfileNosePreviewResponse preview = previewProfileNose(storedProfile);
        return new DogProfileDraftResponse(
                dogId,
                DogStatus.PENDING.name(),
                fileStorageService.toPublicUrl(storedProfile.relativePath()),
                preview,
                "강아지 프로필 정보가 임시 등록되었습니다. 비문 5장을 업로드해 인증을 완료하세요."
        );
    }

    public DogNoseVerificationResponse verifyPendingDogWithNoseImages(
            String dogId,
            Long userId,
            List<? extends MultipartFile> noseImages
    ) {
        requireProfileFirstEnabled();
        User user = loadActiveUserOrThrow(userId);
        Dog dog = dogRepository.findById(dogId)
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "DOG_NOT_FOUND", "강아지 정보를 찾을 수 없습니다."));
        if (!user.getId().equals(dog.getOwnerUserId())) {
            throw new ApiException(HttpStatus.FORBIDDEN, "DOG_OWNER_MISMATCH", "해당 강아지에 접근할 수 없습니다.");
        }
        if (dog.getStatus() != DogStatus.PENDING) {
            throw new ApiException(HttpStatus.CONFLICT, "DOG_STATUS_NOT_PENDING", "PENDING 상태의 강아지만 비문 인증을 완료할 수 있습니다.");
        }

        DogImage profileImage = dogImageRepository.findFirstByDogIdAndImageTypeOrderByUploadedAtDescIdDesc(
                        dogId,
                        DogImageType.PROFILE
                )
                .orElseThrow(() -> new ApiException(HttpStatus.CONFLICT, "PROFILE_IMAGE_NOT_FOUND", "저장된 프로필 이미지가 없습니다."));
        FileStorageService.StoredFile profileFile = fileStorageService.readStoredImage(
                profileImage.getFilePath(),
                profileImage.getMimeType(),
                profileImage.getFileSize(),
                profileImage.getSha256()
        );
        List<NoseImageUpload> uploads = readNoseImages(noseImages);

        ProfileConsistencyDecision profileDecision = requestProfileConsistency(dogId, profileFile, uploads);
        if (!profileDecision.allowed()) {
            log.info("[DogRegistration] profile nose mismatch: dogId={}, passCount={}, median={}, reason={}",
                    dogId, profileDecision.passCount(), profileDecision.medianScore(), profileDecision.failureReason());
            return buildProfileMismatchResponse(dogId, profileDecision);
        }

        DogRegisterResponse registrationResponse = verifyExistingPendingDogWithNoseImages(dog, user, uploads);
        return buildProfilePassedResponse(registrationResponse, profileDecision);
    }

    private void requireProfileFirstEnabled() {
        if (!profileFirstEnabled) {
            throw new ApiException(
                    HttpStatus.NOT_FOUND,
                    PROFILE_FIRST_DISABLED,
                    "프로필 우선 강아지 인증 기능은 현재 비활성화되어 있습니다."
            );
        }
    }

    public DogRegisterResponse register(DogRegisterRequest request) {
        RegistrationTiming timing = new RegistrationTiming();
        boolean completed = false;
        try {
            validateRequiredFields(request);
            LocalDate birthDate = parseBirthDate(request.birthDate());
            Integer age = parseAge(request.age());
            Long price = parsePrice(request.price());
            timing.mark("validate_and_parse_request");

            List<NoseImageUpload> uploads = readNoseImages(request.noseImages());
            timing.mark("read_nose_images");

            User user = userRepository.findById(request.userId())
                    .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "USER_NOT_FOUND", "존재하지 않는 user_id 입니다."));
            timing.mark("load_user");

            String dogId = UUID.randomUUID().toString();
            timing.setDogId(dogId);

            EmbedClient.BatchEmbedResponse embedResponse = requestBatchEmbeddingOrFail(dogId, uploads);
            timing.mark("embed_batch");

            validateBatchEmbeddingDimensionOrFail(dogId, embedResponse, uploads.size());
            timing.mark("validate_embedding_dimension");

            List<List<Double>> referenceVectors = embedResponse.items().stream()
                    .map(EmbedClient.BatchEmbedItem::vector)
                    .toList();
            List<String> referenceFilenames = uploads.stream()
                    .map(NoseImageUpload::filename)
                    .toList();
            timing.mark("build_reference_vectors");

            ReferenceQualityReport qualityReport = checkReferenceQualityOrFail(referenceVectors, referenceFilenames);
            timing.mark("reference_quality_check");

            List<Double> centroidVector = NoseVectorMath.centroid(referenceVectors);
            timing.mark("centroid_build");

            DogNoseAggregationResult aggregationResult = searchExistingDogsOrFail(dogId, referenceVectors, centroidVector);
            timing.mark("qdrant_search");

            DogNoseDecision decision = dogNoseDecisionPolicy.evaluate(
                    aggregationResult.topCandidate(),
                    noseRegistrationProperties.getDuplicateThreshold(),
                    noseRegistrationProperties.getReviewLowerBound()
            );
            timing.setDecisionResult(decision.result());
            timing.mark("decision_policy");

            ScoreBreakdownResponse scoreBreakdown = buildScoreBreakdown(decision, qualityReport);
            String scoreBreakdownJson = toScoreBreakdownJson(scoreBreakdown, qualityReport);
            timing.mark("score_breakdown");

            List<FileStorageService.StoredFile> storedFiles = storeNoseImages(dogId, uploads);
            timing.mark("file_store");

            PendingRegistration pending;
            try {
                pending = transactionTemplate.execute(status ->
                        createPendingRows(user.getId(), dogId, request, birthDate, age, price, storedFiles)
                );
                timing.mark("db_create_pending_rows");
            } catch (RuntimeException e) {
                fileStorageService.deleteStoredFilesQuietly(storedFiles);
                throw e;
            }
            if (pending == null) {
                fileStorageService.deleteStoredFilesQuietly(storedFiles);
                throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "REGISTRATION_INIT_FAILED", "등록 초기화에 실패했습니다.");
            }

            DogRegisterResponse response = switch (decision.result()) {
                case DUPLICATE_SUSPECTED, REVIEW_REQUIRED ->
                        completeRegistrationWithoutQdrant(pending, embedResponse, decision, scoreBreakdown, scoreBreakdownJson, timing);
                case PASSED ->
                        completePassedRegistration(pending, embedResponse, referenceVectors, centroidVector, decision, scoreBreakdown, scoreBreakdownJson, timing);
                default -> throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "REGISTRATION_DECISION_FAILED", "등록 판정 결과가 올바르지 않습니다.");
            };
            completed = true;
            return response;
        } finally {
            logRegistrationTiming(timing, completed);
        }
    }

    private DogRegisterResponse verifyExistingPendingDogWithNoseImages(
            Dog dog,
            User user,
            List<NoseImageUpload> uploads
    ) {
        RegistrationTiming timing = new RegistrationTiming();
        timing.setDogId(dog.getId());
        boolean completed = false;
        try {
            EmbedClient.BatchEmbedResponse embedResponse = requestBatchEmbeddingOrFail(dog.getId(), uploads);
            timing.mark("embed_batch");

            validateBatchEmbeddingDimensionOrFail(dog.getId(), embedResponse, uploads.size());
            timing.mark("validate_embedding_dimension");

            List<List<Double>> referenceVectors = embedResponse.items().stream()
                    .map(EmbedClient.BatchEmbedItem::vector)
                    .toList();
            List<String> referenceFilenames = uploads.stream()
                    .map(NoseImageUpload::filename)
                    .toList();
            timing.mark("build_reference_vectors");

            ReferenceQualityReport qualityReport = checkReferenceQualityOrFail(referenceVectors, referenceFilenames);
            timing.mark("reference_quality_check");

            List<Double> centroidVector = NoseVectorMath.centroid(referenceVectors);
            timing.mark("centroid_build");

            DogNoseAggregationResult aggregationResult = searchExistingDogsOrFail(dog.getId(), referenceVectors, centroidVector);
            timing.mark("qdrant_search");

            DogNoseDecision decision = dogNoseDecisionPolicy.evaluate(
                    aggregationResult.topCandidate(),
                    noseRegistrationProperties.getDuplicateThreshold(),
                    noseRegistrationProperties.getReviewLowerBound()
            );
            timing.setDecisionResult(decision.result());
            timing.mark("decision_policy");

            ScoreBreakdownResponse scoreBreakdown = buildScoreBreakdown(decision, qualityReport);
            String scoreBreakdownJson = toScoreBreakdownJson(scoreBreakdown, qualityReport);
            timing.mark("score_breakdown");

            List<FileStorageService.StoredFile> storedFiles = storeNoseImages(dog.getId(), uploads);
            timing.mark("file_store");

            PendingRegistration pending;
            try {
                pending = transactionTemplate.execute(status ->
                        createVerificationRowsForExistingDog(user.getId(), dog.getId(), storedFiles)
                );
                timing.mark("db_create_verification_rows");
            } catch (RuntimeException e) {
                fileStorageService.deleteStoredFilesQuietly(storedFiles);
                throw e;
            }
            if (pending == null) {
                fileStorageService.deleteStoredFilesQuietly(storedFiles);
                throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "REGISTRATION_INIT_FAILED", "등록 초기화에 실패했습니다.");
            }

            DogRegisterResponse response = switch (decision.result()) {
                case DUPLICATE_SUSPECTED, REVIEW_REQUIRED ->
                        completeRegistrationWithoutQdrant(pending, embedResponse, decision, scoreBreakdown, scoreBreakdownJson, timing);
                case PASSED ->
                        completePassedRegistration(pending, embedResponse, referenceVectors, centroidVector, decision, scoreBreakdown, scoreBreakdownJson, timing);
                default -> throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "REGISTRATION_DECISION_FAILED", "등록 판정 결과가 올바르지 않습니다.");
            };
            completed = true;
            return response;
        } finally {
            logRegistrationTiming(timing, completed);
        }
    }

    private void createProfileDraftRows(
            Long userId,
            String dogId,
            DogProfileDraftRequest request,
            LocalDate birthDate,
            FileStorageService.StoredFile storedProfile
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

        DogImage profileImage = buildDogImage(dogId, DogImageType.PROFILE, storedProfile);
        dogImageRepository.save(profileImage);
    }

    private PendingRegistration createVerificationRowsForExistingDog(
            Long userId,
            String dogId,
            List<FileStorageService.StoredFile> storedFiles
    ) {
        List<StoredNoseImage> noseImages = new ArrayList<>();
        for (FileStorageService.StoredFile storedFile : storedFiles) {
            DogImage noseImage = buildDogImage(dogId, DogImageType.NOSE, storedFile);
            dogImageRepository.save(noseImage);
            noseImages.add(new StoredNoseImage(noseImage.getId(), storedFile));
        }

        StoredNoseImage representative = noseImages.get(0);
        VerificationLog verificationLog = new VerificationLog();
        verificationLog.setDogId(dogId);
        verificationLog.setDogImageId(representative.dogImageId());
        verificationLog.setRequestedByUserId(userId);
        verificationLog.setSubmittedImagePath(representative.storedFile().relativePath());
        verificationLog.setSubmittedImageMimeType(representative.storedFile().mimeType());
        verificationLog.setSubmittedImageFileSize(representative.storedFile().fileSize());
        verificationLog.setSubmittedImageSha256(representative.storedFile().sha256());
        verificationLog.setPurpose(VerificationPurpose.DOG_REGISTRATION);
        verificationLog.setResult(VerificationResult.PENDING);
        verificationLogRepository.save(verificationLog);

        return new PendingRegistration(dogId, List.copyOf(noseImages), verificationLog.getId());
    }

    private ProfileNosePreviewResponse previewProfileNose(FileStorageService.StoredFile storedProfile) {
        try {
            Map<String, Object> response = embedClient.extractProfileNose(
                    storedProfile.bytes(),
                    storedProfile.originalFilename(),
                    storedProfile.mimeType()
            );
            return new ProfileNosePreviewResponse(
                    booleanValue(response.get("extracted")),
                    numberAsDouble(response.get("confidence")),
                    numberAsInteger(response.get("crop_width")),
                    numberAsInteger(response.get("crop_height")),
                    valueOrNull(response.get("failure_reason"))
            );
        } catch (EmbedClient.EmbedClientException e) {
            log.warn("[DogRegistration] profile preview extraction skipped: message={}", e.getMessage());
            return new ProfileNosePreviewResponse(false, null, null, null, DETECTOR_UNAVAILABLE);
        }
    }

    private ProfileConsistencyDecision requestProfileConsistency(
            String dogId,
            FileStorageService.StoredFile profileFile,
            List<NoseImageUpload> uploads
    ) {
        List<EmbedClient.BatchImageInput> noseInputs = uploads.stream()
                .map(upload -> new EmbedClient.BatchImageInput(upload.bytes(), upload.filename(), upload.contentType()))
                .toList();

        EmbedClient.ProfileNoseMatchBatchResponse response;
        try {
            response = embedClient.profileNoseMatchBatch(
                    profileFile.bytes(),
                    profileFile.originalFilename(),
                    profileFile.mimeType(),
                    noseInputs
            );
        } catch (EmbedClient.EmbedClientException e) {
            log.warn("[DogRegistration] profile nose match batch 실패: dogId={}, upstreamStatus={}, message={}",
                    dogId, e.getUpstreamStatus(), e.getMessage());
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "PROFILE_MATCH_SERVICE_UNAVAILABLE", "프로필-비문 일치 검증 서비스를 사용할 수 없습니다.");
        }

        return evaluateProfileConsistency(response);
    }

    private ProfileConsistencyDecision evaluateProfileConsistency(EmbedClient.ProfileNoseMatchBatchResponse response) {
        double threshold = profileNoseMatchProperties.getThreshold();
        int minPassCount = profileNoseMatchProperties.getMinPassCount();
        String aggregate = normalizedProfileAggregate();

        List<ProfileMatchScoreResponse> scores = new ArrayList<>();
        for (int i = 0; i < response.scores().size(); i++) {
            EmbedClient.ProfileNoseMatchBatchScore score = response.scores().get(i);
            Double value = score.similarityScore();
            scores.add(new ProfileMatchScoreResponse(
                    score.index() <= 0 ? i + 1 : score.index(),
                    value,
                    value != null && value >= threshold
            ));
        }

        int passCount = (int) scores.stream().filter(ProfileMatchScoreResponse::passed).count();
        Double medianScore = median(scores.stream()
                .map(ProfileMatchScoreResponse::score)
                .filter(value -> value != null)
                .toList());

        String failureReason = valueOrNull(response.failureReason());
        int expectedCount = noseRegistrationProperties.getReferenceMaxCount();
        boolean scoreCountValid = scores.size() == expectedCount;
        boolean allowed = response.profileNoseExtracted()
                && scoreCountValid
                && failureReason == null
                && medianScore != null
                && passCount >= minPassCount
                && medianScore >= threshold;
        if (!allowed && failureReason == null) {
            failureReason = scoreCountValid ? PROFILE_NOSE_MISMATCH : "PROFILE_MATCH_SCORE_COUNT_INVALID";
        }

        return new ProfileConsistencyDecision(
                allowed,
                threshold,
                minPassCount,
                passCount,
                medianScore,
                aggregate,
                List.copyOf(scores),
                false,
                response.model(),
                response.dimension(),
                failureReason
        );
    }

    private DogNoseVerificationResponse buildProfileMismatchResponse(
            String dogId,
            ProfileConsistencyDecision profileDecision
    ) {
        return new DogNoseVerificationResponse(
                dogId,
                false,
                "FAILED",
                profileDecision.threshold(),
                profileDecision.minPassCount(),
                profileDecision.passCount(),
                profileDecision.medianScore(),
                profileDecision.aggregate(),
                profileDecision.scores(),
                profileDecision.thresholdCalibrated(),
                false,
                DogStatus.PENDING.name(),
                "PENDING",
                "PENDING",
                null,
                profileDecision.model(),
                profileDecision.dimension(),
                null,
                null,
                null,
                null,
                null,
                List.of(),
                profileDecision.failureReason(),
                "프로필 사진 속 강아지와 비문 이미지가 충분히 일치하지 않아 인증을 완료할 수 없습니다."
        );
    }

    private DogNoseVerificationResponse buildProfilePassedResponse(
            DogRegisterResponse registrationResponse,
            ProfileConsistencyDecision profileDecision
    ) {
        String message = registrationResponse.registrationAllowed()
                ? "프로필 사진과 비문 이미지가 같은 강아지로 판단되어 등록이 완료되었습니다."
                : registrationResponse.message();
        return new DogNoseVerificationResponse(
                registrationResponse.dogId(),
                true,
                "PASSED",
                profileDecision.threshold(),
                profileDecision.minPassCount(),
                profileDecision.passCount(),
                profileDecision.medianScore(),
                profileDecision.aggregate(),
                profileDecision.scores(),
                profileDecision.thresholdCalibrated(),
                registrationResponse.registrationAllowed(),
                registrationResponse.status(),
                registrationResponse.verificationStatus(),
                registrationResponse.embeddingStatus(),
                registrationResponse.qdrantPointId(),
                registrationResponse.model(),
                registrationResponse.dimension(),
                registrationResponse.maxSimilarityScore(),
                registrationResponse.topMatch(),
                registrationResponse.embeddingMode(),
                registrationResponse.referenceCount(),
                registrationResponse.scoreBreakdown(),
                registrationResponse.noseImageUrls(),
                null,
                message
        );
    }

    private List<NoseImageUpload> readNoseImages(List<? extends MultipartFile> noseImages) {
        if (noseImages == null || noseImages.stream().noneMatch(file -> file != null && !file.isEmpty())) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "NOSE_IMAGES_REQUIRED", "nose_images는 필수입니다.");
        }

        List<? extends MultipartFile> presentImages = noseImages.stream()
                .filter(file -> file != null && !file.isEmpty())
                .toList();

        int count = presentImages.size();
        int expectedCount = noseRegistrationProperties.getReferenceMaxCount();
        if (count != expectedCount) {
            throw new ApiException(
                    HttpStatus.BAD_REQUEST,
                    "NOSE_IMAGES_COUNT_INVALID",
                    "비문 기준 이미지는 정확히 %d장이 필요합니다.".formatted(expectedCount),
                    Map.of(
                            "expected_count", expectedCount,
                            "actual_count", count
                    )
            );
        }

        List<NoseImageUpload> uploads = new ArrayList<>();
        for (int i = 0; i < presentImages.size(); i++) {
            MultipartFile file = presentImages.get(i);
            try {
                String filename = filenameOrDefault(file.getOriginalFilename(), i + 1);
                String contentType = file.getContentType();
                if (contentType == null || contentType.isBlank()) {
                    throw new ApiException(HttpStatus.BAD_REQUEST, "INVALID_CONTENT_TYPE", "이미지 Content-Type이 누락되었습니다.");
                }
                uploads.add(new NoseImageUpload(file, file.getBytes(), filename, contentType));
            } catch (IOException e) {
                throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "INVALID_NOSE_IMAGE", "비문 이미지 처리에 실패했습니다.");
            }
        }
        return List.copyOf(uploads);
    }

    private EmbedClient.BatchEmbedResponse requestBatchEmbeddingOrFail(String dogId, List<NoseImageUpload> uploads) {
        List<EmbedClient.BatchImageInput> inputs = uploads.stream()
                .map(upload -> new EmbedClient.BatchImageInput(upload.bytes(), upload.filename(), upload.contentType()))
                .toList();

        try {
            return embedClient.embedBatch(inputs);
        } catch (EmbedClient.EmbedClientException e) {
            log.warn("[DogRegistration] embed batch 실패: dogId={}, upstreamStatus={}, message={}",
                    dogId, e.getUpstreamStatus(), e.getMessage());
            if (e.getUpstreamStatus() != null && e.getUpstreamStatus() == 400) {
                throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "INVALID_NOSE_IMAGE", "비문 이미지 처리에 실패했습니다.");
            }
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "EMBED_SERVICE_UNAVAILABLE", "임베딩 서비스를 사용할 수 없습니다.");
        }
    }

    private void validateBatchEmbeddingDimensionOrFail(
            String dogId,
            EmbedClient.BatchEmbedResponse embedResponse,
            int expectedCount
    ) {
        if (embedResponse.items() == null || embedResponse.items().isEmpty()) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "EMPTY_EMBEDDING", "임베딩 결과가 비어 있습니다.");
        }
        if (embedResponse.items().size() != expectedCount) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "EMBEDDING_COUNT_MISMATCH", "임베딩 결과 개수가 요청 이미지 개수와 일치하지 않습니다.");
        }
        if (embedResponse.dimension() != expectedVectorDimension) {
            log.warn("[DogRegistration] embed dimension mismatch: dogId={}, expected={}, actual={}",
                    dogId, expectedVectorDimension, embedResponse.dimension());
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "EMBEDDING_DIMENSION_MISMATCH", "임베딩 차원이 시스템 설정과 일치하지 않습니다.");
        }
        for (EmbedClient.BatchEmbedItem item : embedResponse.items()) {
            if (item.vector() == null || item.vector().isEmpty()) {
                throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "EMPTY_EMBEDDING", "임베딩 결과가 비어 있습니다.");
            }
            if (item.vector().size() != expectedVectorDimension) {
                throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "EMBEDDING_DIMENSION_MISMATCH", "임베딩 차원이 시스템 설정과 일치하지 않습니다.");
            }
        }
    }

    private ReferenceQualityReport checkReferenceQualityOrFail(List<List<Double>> referenceVectors, List<String> filenames) {
        ReferenceQualityReport report = noseReferenceQualityAnalyzer.analyze(
                referenceVectors,
                filenames,
                noseRegistrationProperties.getReferenceConsistencyThreshold(),
                noseRegistrationProperties.getReferenceOutlierImprovementThreshold(),
                noseRegistrationProperties.isReferenceQualityWarningEnabled()
        );
        if (report.verdict() == ReferenceQualityVerdict.RETAKE_ONE
                || report.verdict() == ReferenceQualityVerdict.RETAKE_ALL) {
            throw new ApiException(
                    HttpStatus.BAD_REQUEST,
                    "NOSE_REFERENCE_INCONSISTENT",
                    report.recommendation(),
                    referenceQualityErrorDetails(report)
            );
        }
        return report;
    }

    private DogNoseAggregationResult searchExistingDogsOrFail(
            String dogId,
            List<List<Double>> referenceVectors,
            List<Double> centroidVector
    ) {
        try {
            List<QdrantDogVectorClient.QdrantVectorSearchResult> referenceResults = new ArrayList<>();
            for (List<Double> referenceVector : referenceVectors) {
                referenceResults.addAll(qdrantDogVectorClient.searchReferencePoints(
                        referenceVector,
                        qdrantSearchTopK,
                        qdrantSearchScoreThreshold
                ));
            }
            List<QdrantDogVectorClient.QdrantVectorSearchResult> centroidResults =
                    qdrantDogVectorClient.searchCentroidPoints(
                            centroidVector,
                            qdrantSearchTopK,
                            qdrantSearchScoreThreshold
                    );
            return dogNoseCandidateAggregator.aggregate(
                    referenceResults,
                    centroidResults,
                    noseRegistrationProperties.getReviewLowerBound()
            );
        } catch (QdrantDogVectorClient.QdrantClientException e) {
            log.warn("[DogRegistration] qdrant v2 search 실패: dogId={}, status={}, message={}",
                    dogId, e.getUpstreamStatus(), e.getMessage());
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "QDRANT_SEARCH_FAILED", "중복 검증 검색에 실패했습니다.");
        }
    }

    private List<FileStorageService.StoredFile> storeNoseImages(String dogId, List<NoseImageUpload> uploads) {
        List<FileStorageService.StoredFile> storedFiles = new ArrayList<>();
        try {
            for (NoseImageUpload upload : uploads) {
                storedFiles.add(fileStorageService.storeNoseImage(dogId, upload.file()));
            }
        } catch (RuntimeException e) {
            fileStorageService.deleteStoredFilesQuietly(storedFiles);
            throw e;
        }
        return List.copyOf(storedFiles);
    }

    private PendingRegistration createPendingRows(
            Long userId,
            String dogId,
            DogRegisterRequest request,
            LocalDate birthDate,
            Integer age,
            Long price,
            List<FileStorageService.StoredFile> storedFiles
    ) {
        Dog dog = new Dog();
        dog.setId(dogId);
        dog.setOwnerUserId(userId);
        dog.setName(request.name().trim());
        dog.setBreed(request.breed().trim());
        dog.setGender(DogGender.from(request.gender()));
        dog.setBirthDate(birthDate);
        dog.setAge(age);
        dog.setDescription(blankToNull(request.description()));
        dog.setHealth(blankToNull(request.health()));
        dog.setPrice(price);
        dog.setStatus(DogStatus.PENDING);
        dogRepository.save(dog);

        List<StoredNoseImage> noseImages = new ArrayList<>();
        for (FileStorageService.StoredFile storedFile : storedFiles) {
            DogImage noseImage = buildDogImage(dogId, DogImageType.NOSE, storedFile);
            dogImageRepository.save(noseImage);
            noseImages.add(new StoredNoseImage(noseImage.getId(), storedFile));
        }

        StoredNoseImage representative = noseImages.get(0);
        VerificationLog verificationLog = new VerificationLog();
        verificationLog.setDogId(dogId);
        verificationLog.setDogImageId(representative.dogImageId());
        verificationLog.setRequestedByUserId(userId);
        verificationLog.setSubmittedImagePath(representative.storedFile().relativePath());
        verificationLog.setSubmittedImageMimeType(representative.storedFile().mimeType());
        verificationLog.setSubmittedImageFileSize(representative.storedFile().fileSize());
        verificationLog.setSubmittedImageSha256(representative.storedFile().sha256());
        verificationLog.setPurpose(VerificationPurpose.DOG_REGISTRATION);
        verificationLog.setResult(VerificationResult.PENDING);
        verificationLogRepository.save(verificationLog);

        return new PendingRegistration(dogId, List.copyOf(noseImages), verificationLog.getId());
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

    private DogRegisterResponse completeRegistrationWithoutQdrant(
            PendingRegistration pending,
            EmbedClient.BatchEmbedResponse embedResponse,
            DogNoseDecision decision,
            ScoreBreakdownResponse scoreBreakdown,
            String scoreBreakdownJson,
            RegistrationTiming timing
    ) {
        transactionTemplate.executeWithoutResult(status ->
                markAsDecision(pending, embedResponse, decision, scoreBreakdownJson)
        );
        timing.mark("db_mark_decision");

        DogRegisterResponse response = buildResponse(pending, embedResponse, decision, scoreBreakdown, messageFor(decision.result()));
        timing.mark("build_response");
        return response;
    }

    private DogRegisterResponse completePassedRegistration(
            PendingRegistration pending,
            EmbedClient.BatchEmbedResponse embedResponse,
            List<List<Double>> referenceVectors,
            List<Double> centroidVector,
            DogNoseDecision decision,
            ScoreBreakdownResponse scoreBreakdown,
            String scoreBreakdownJson,
            RegistrationTiming timing
    ) {
        List<PreparedQdrantPoint> preparedPoints = prepareQdrantPoints(pending, embedResponse, referenceVectors, centroidVector);
        List<QdrantDogVectorClient.QdrantPointUpsertRequest> upsertRequests = preparedPoints.stream()
                .map(point -> new QdrantDogVectorClient.QdrantPointUpsertRequest(
                        point.pointId(),
                        point.vector(),
                        point.payload()
                ))
                .toList();
        timing.mark("qdrant_prepare_points");

        try {
            qdrantDogVectorClient.upsertAll(upsertRequests);
            timing.mark("qdrant_upsert");
        } catch (QdrantDogVectorClient.QdrantClientException e) {
            timing.mark("qdrant_upsert_failed");
            log.warn("[DogRegistration] qdrant v2 upsert 실패: dogId={}, status={}, message={}",
                    pending.dogId(), e.getUpstreamStatus(), e.getMessage());
            transactionTemplate.executeWithoutResult(status ->
                    markAsFailed(
                            pending,
                            embedResponse,
                            decision.finalScore(),
                            scoreBreakdownJson,
                            "qdrant upsert 실패: " + e.getMessage()
                    )
            );
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "QDRANT_UPSERT_FAILED", "벡터 인덱스 동기화에 실패했습니다.");
        }

        try {
            transactionTemplate.executeWithoutResult(status ->
                    createReferencesAndMarkRegistered(pending, embedResponse, decision.finalScore(), scoreBreakdownJson, preparedPoints)
            );
            timing.mark("db_create_references_mark_registered");
        } catch (RuntimeException e) {
            deleteQdrantPointsBestEffort(preparedPoints.stream().map(PreparedQdrantPoint::pointId).toList());
            try {
                transactionTemplate.executeWithoutResult(status ->
                        markAsFailed(
                                pending,
                                embedResponse,
                                decision.finalScore(),
                                scoreBreakdownJson,
                                "qdrant upsert 이후 DB 반영 실패: " + e.getMessage()
                        )
                );
            } catch (RuntimeException markFailure) {
                log.warn("[DogRegistration] qdrant 보상 후 실패 상태 저장 실패: dogId={}, message={}",
                        pending.dogId(), markFailure.getMessage());
            }
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "QDRANT_UPSERT_FAILED", "벡터 인덱스 동기화에 실패했습니다.");
        }

        DogRegisterResponse response = buildResponse(pending, embedResponse, decision, scoreBreakdown, messageFor(decision.result()));
        timing.mark("build_response");
        return response;
    }

    private List<PreparedQdrantPoint> prepareQdrantPoints(
            PendingRegistration pending,
            EmbedClient.BatchEmbedResponse embedResponse,
            List<List<Double>> referenceVectors,
            List<Double> centroidVector
    ) {
        Instant createdAt = Instant.now();
        String createdAtText = createdAt.toString();
        List<PreparedQdrantPoint> points = new ArrayList<>();

        for (int i = 0; i < referenceVectors.size(); i++) {
            StoredNoseImage noseImage = pending.noseImages().get(i);
            int referenceIndex = i + 1;
            String pointId = UUID.randomUUID().toString();
            Map<String, Object> payload = new LinkedHashMap<>();
            payload.put("dog_id", pending.dogId());
            payload.put("dog_image_id", noseImage.dogImageId());
            payload.put("embedding_kind", DogNoseEmbeddingKind.REFERENCE.name());
            payload.put("reference_index", referenceIndex);
            payload.put("model", embedResponse.model());
            payload.put("dimension", embedResponse.dimension());
            payload.put("preprocess_version", noseRegistrationProperties.getPreprocessVersion());
            payload.put("is_active", true);
            payload.put("created_at", createdAtText);
            points.add(new PreparedQdrantPoint(
                    pointId,
                    referenceVectors.get(i),
                    payload,
                    DogNoseEmbeddingKind.REFERENCE,
                    noseImage.dogImageId(),
                    referenceIndex
            ));
        }

        String centroidPointId = UUID.randomUUID().toString();
        Map<String, Object> centroidPayload = new LinkedHashMap<>();
        centroidPayload.put("dog_id", pending.dogId());
        centroidPayload.put("embedding_kind", DogNoseEmbeddingKind.CENTROID.name());
        centroidPayload.put("reference_count", referenceVectors.size());
        centroidPayload.put("model", embedResponse.model());
        centroidPayload.put("dimension", embedResponse.dimension());
        centroidPayload.put("preprocess_version", noseRegistrationProperties.getPreprocessVersion());
        centroidPayload.put("is_active", true);
        centroidPayload.put("created_at", createdAtText);
        points.add(new PreparedQdrantPoint(
                centroidPointId,
                centroidVector,
                centroidPayload,
                DogNoseEmbeddingKind.CENTROID,
                null,
                null
        ));

        return List.copyOf(points);
    }

    private void createReferencesAndMarkRegistered(
            PendingRegistration pending,
            EmbedClient.BatchEmbedResponse embedResponse,
            double finalScore,
            String scoreBreakdownJson,
            List<PreparedQdrantPoint> preparedPoints
    ) {
        List<DogNoseReference> references = new ArrayList<>();
        for (PreparedQdrantPoint preparedPoint : preparedPoints) {
            DogNoseReference reference = new DogNoseReference();
            reference.setId(UUID.randomUUID().toString());
            reference.setDogId(pending.dogId());
            reference.setDogImageId(preparedPoint.dogImageId());
            reference.setQdrantPointId(preparedPoint.pointId());
            reference.setEmbeddingKind(preparedPoint.embeddingKind());
            reference.setReferenceIndex(preparedPoint.referenceIndex());
            reference.setModel(embedResponse.model());
            reference.setDimension(embedResponse.dimension());
            reference.setPreprocessVersion(noseRegistrationProperties.getPreprocessVersion());
            reference.setQualityStatus(NoseReferenceQualityStatus.ACCEPTED);
            reference.setQualityScore(null);
            reference.setActive(true);
            references.add(reference);
        }
        dogNoseReferenceRepository.saveAll(references);

        Dog dog = getDogOrThrow(pending.dogId());
        dog.setStatus(DogStatus.REGISTERED);
        dogRepository.save(dog);

        VerificationLog logEntity = getVerificationLogOrThrow(pending.verificationLogId());
        logEntity.setResult(VerificationResult.PASSED);
        logEntity.setSimilarityScore(toScore(finalScore));
        logEntity.setModel(embedResponse.model());
        logEntity.setDimension(embedResponse.dimension());
        logEntity.setScoreBreakdownJson(scoreBreakdownJson);
        verificationLogRepository.save(logEntity);
    }

    private void markAsDecision(
            PendingRegistration pending,
            EmbedClient.BatchEmbedResponse embedResponse,
            DogNoseDecision decision,
            String scoreBreakdownJson
    ) {
        VerificationResult result = decision.result();
        Dog dog = getDogOrThrow(pending.dogId());
        dog.setStatus(result == VerificationResult.REVIEW_REQUIRED
                ? DogStatus.REVIEW_REQUIRED
                : DogStatus.DUPLICATE_SUSPECTED);
        dogRepository.save(dog);

        VerificationLog logEntity = getVerificationLogOrThrow(pending.verificationLogId());
        logEntity.setResult(result);
        logEntity.setSimilarityScore(toScore(decision.finalScore()));
        logEntity.setCandidateDogId(decision.topCandidate() != null ? decision.topCandidate().dogId() : null);
        logEntity.setModel(embedResponse.model());
        logEntity.setDimension(embedResponse.dimension());
        logEntity.setScoreBreakdownJson(scoreBreakdownJson);
        verificationLogRepository.save(logEntity);
    }

    private void markAsFailed(
            PendingRegistration pending,
            EmbedClient.BatchEmbedResponse embedResponse,
            double finalScore,
            String scoreBreakdownJson,
            String failureReason
    ) {
        Dog dog = getDogOrThrow(pending.dogId());
        dog.setStatus(DogStatus.REJECTED);
        dogRepository.save(dog);

        VerificationLog logEntity = getVerificationLogOrThrow(pending.verificationLogId());
        logEntity.setResult(VerificationResult.QDRANT_UPSERT_FAILED);
        logEntity.setSimilarityScore(toScore(finalScore));
        logEntity.setModel(embedResponse.model());
        logEntity.setDimension(embedResponse.dimension());
        logEntity.setScoreBreakdownJson(scoreBreakdownJson);
        logEntity.setFailureReason(failureReason);
        verificationLogRepository.save(logEntity);
    }

    private void deleteQdrantPointsBestEffort(List<String> pointIds) {
        try {
            qdrantDogVectorClient.deletePoints(pointIds);
        } catch (RuntimeException e) {
            log.warn("[DogRegistration] qdrant 보상 delete 실패: pointIds={}, message={}", pointIds, e.getMessage());
        }
    }

    private ScoreBreakdownResponse buildScoreBreakdown(
            DogNoseDecision decision,
            ReferenceQualityReport qualityReport
    ) {
        DogNoseCandidateScore topCandidate = decision.topCandidate();
        return new ScoreBreakdownResponse(
                decision.finalScore(),
                topCandidate == null ? null : topCandidate.maxReferenceScore(),
                topCandidate == null ? null : topCandidate.top2AverageScore(),
                topCandidate == null ? null : topCandidate.centroidScore(),
                topCandidate == null ? 0 : topCandidate.hitCount(),
                qualityReport.averagePairwiseScore()
        );
    }

    private String toScoreBreakdownJson(ScoreBreakdownResponse scoreBreakdown, ReferenceQualityReport qualityReport) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("final_score", scoreBreakdown.finalScore());
        body.put("max_reference_score", scoreBreakdown.maxReferenceScore());
        body.put("top2_average_score", scoreBreakdown.top2AverageScore());
        body.put("centroid_score", scoreBreakdown.centroidScore());
        body.put("hit_count", scoreBreakdown.hitCount());
        body.put("reference_consistency_score", scoreBreakdown.referenceConsistencyScore());
        body.put("reference_quality", referenceQualityScoreBreakdown(qualityReport));
        body.put("policy", SCORE_POLICY);
        try {
            return objectMapper.writeValueAsString(body);
        } catch (JsonProcessingException e) {
            throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "SCORE_BREAKDOWN_SERIALIZE_FAILED", "검증 점수 상세 저장에 실패했습니다.");
        }
    }

    private Map<String, Object> referenceQualityScoreBreakdown(ReferenceQualityReport report) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("verdict", report.verdict().name());
        body.put("weakest_image_index", report.weakestImageIndex());
        body.put("weakest_image_average_score", report.weakestImageAverageScore());
        body.put("best_subset_indexes", report.bestSubsetIndexes());
        body.put("best_subset_average_score", report.bestSubsetAverageScore());
        body.put("best_subset_improvement", report.bestSubsetImprovement());
        body.put("recommendation", report.recommendation());
        return body;
    }

    private Map<String, Object> referenceQualityErrorDetails(ReferenceQualityReport report) {
        Map<String, Object> details = new LinkedHashMap<>();
        details.put("quality_verdict", report.verdict().name());
        details.put("average_pairwise_score", report.averagePairwiseScore());
        details.put("threshold", report.threshold());
        details.put("min_pairwise_score", report.minPairwiseScore());
        details.put("max_pairwise_score", report.maxPairwiseScore());
        details.put("weakest_image_index", report.weakestImageIndex());
        details.put("weakest_image_filename", report.weakestImageFilename());
        details.put("weakest_image_average_score", report.weakestImageAverageScore());
        details.put("best_subset_indexes", report.bestSubsetIndexes());
        details.put("best_subset_average_score", report.bestSubsetAverageScore());
        details.put("best_subset_improvement", report.bestSubsetImprovement());
        details.put("recommendation", report.recommendation());
        details.put("pairwise_scores", report.pairwiseScores().stream()
                .map(this::pairwiseScoreDetails)
                .toList());
        details.put("per_image_qualities", report.perImageQualities().stream()
                .map(this::perImageQualityDetails)
                .toList());
        details.put("leave_one_out_subsets", report.leaveOneOutSubsets().stream()
                .map(this::leaveOneOutSubsetDetails)
                .toList());
        return details;
    }

    private Map<String, Object> pairwiseScoreDetails(PairwiseScore score) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("image_a", score.imageA());
        body.put("image_b", score.imageB());
        body.put("score", score.score());
        return body;
    }

    private Map<String, Object> perImageQualityDetails(PerImageQuality quality) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("image_index", quality.imageIndex());
        body.put("filename", quality.filename());
        body.put("average_score_to_others", quality.averageScoreToOthers());
        body.put("min_score_to_others", quality.minScoreToOthers());
        body.put("max_score_to_others", quality.maxScoreToOthers());
        body.put("below_threshold_pairs_count", quality.belowThresholdPairsCount());
        return body;
    }

    private Map<String, Object> leaveOneOutSubsetDetails(LeaveOneOutSubset subset) {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("excluded_image_index", subset.excludedImageIndex());
        body.put("excluded_filename", subset.excludedFilename());
        body.put("subset_indexes", subset.subsetIndexes());
        body.put("average_pairwise_score", subset.averagePairwiseScore());
        body.put("min_pairwise_score", subset.minPairwiseScore());
        body.put("max_pairwise_score", subset.maxPairwiseScore());
        body.put("accepted", subset.accepted());
        body.put("improvement_vs_full_average", subset.improvementVsFullAverage());
        return body;
    }

    private DogRegisterResponse buildResponse(
            PendingRegistration pending,
            EmbedClient.BatchEmbedResponse embedResponse,
            DogNoseDecision decision,
            ScoreBreakdownResponse scoreBreakdown,
            String message
    ) {
        StoredNoseImage representative = pending.representativeNoseImage();
        List<String> noseImageUrls = pending.noseImages().stream()
                .map(image -> fileStorageService.toPublicUrl(image.storedFile().relativePath()))
                .toList();

        return new DogRegisterResponse(
                pending.dogId(),
                decision.registrationAllowed(),
                toDogStatus(decision.result()).name(),
                toVerificationStatus(decision.result()),
                toEmbeddingStatus(decision.result()),
                null,
                embedResponse.model(),
                embedResponse.dimension(),
                decision.finalScore(),
                fileStorageService.toPublicUrl(representative.storedFile().relativePath()),
                null,
                buildTopMatch(decision.topCandidate()),
                EMBEDDING_MODE_MULTI_REFERENCE,
                pending.noseImages().size(),
                scoreBreakdown,
                noseImageUrls,
                message
        );
    }

    private DuplicateCandidateResponse buildTopMatch(DogNoseCandidateScore topCandidate) {
        if (topCandidate == null) {
            return null;
        }
        String breed = dogRepository.findById(topCandidate.dogId())
                .map(Dog::getBreed)
                .orElse(null);
        return new DuplicateCandidateResponse(
                topCandidate.dogId(),
                topCandidate.finalScore(),
                breed
        );
    }

    private DogStatus toDogStatus(VerificationResult result) {
        return switch (result) {
            case PASSED -> DogStatus.REGISTERED;
            case DUPLICATE_SUSPECTED -> DogStatus.DUPLICATE_SUSPECTED;
            case REVIEW_REQUIRED -> DogStatus.REVIEW_REQUIRED;
            case PENDING, EMBED_FAILED, QDRANT_SEARCH_FAILED, QDRANT_UPSERT_FAILED -> DogStatus.REJECTED;
        };
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

    private String messageFor(VerificationResult result) {
        return switch (result) {
            case PASSED -> "중복 의심 개체가 없어 등록이 완료되었습니다.";
            case DUPLICATE_SUSPECTED -> "기존 등록견과 동일 개체로 의심되어 등록이 제한됩니다.";
            case REVIEW_REQUIRED -> "기존 등록견과 유사도가 애매해 검토가 필요합니다.";
            default -> "등록 상태를 확인할 수 없습니다.";
        };
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

    private Integer parseAge(String age) {
        if (age == null || age.isBlank()) {
            return null;
        }
        try {
            int parsed = Integer.parseInt(age.trim());
            if (parsed < 0) {
                throw validationFailed("age는 0 이상이어야 합니다.");
            }
            return parsed;
        } catch (NumberFormatException e) {
            throw validationFailed("age는 숫자여야 합니다.");
        }
    }

    private Long parsePrice(String price) {
        if (price == null || price.isBlank()) {
            return null;
        }
        try {
            long parsed = Long.parseLong(price.trim());
            if (parsed < 0) {
                throw validationFailed("price는 0 이상이어야 합니다.");
            }
            return parsed;
        } catch (NumberFormatException e) {
            throw validationFailed("price는 숫자여야 합니다.");
        }
    }

    private ApiException validationFailed(String message) {
        return new ApiException(HttpStatus.BAD_REQUEST, "VALIDATION_FAILED", message);
    }

    private String blankToNull(String value) {
        if (value == null || value.isBlank()) {
            return null;
        }
        return value.trim();
    }

    private User loadActiveUserOrThrow(Long userId) {
        if (userId == null) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "USER_ID_REQUIRED", "user_id는 필수입니다.");
        }
        User user = userRepository.findById(userId)
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "USER_NOT_FOUND", "존재하지 않는 user_id 입니다."));
        if (!user.isActive()) {
            throw new ApiException(HttpStatus.FORBIDDEN, "USER_INACTIVE", "비활성화된 사용자입니다.");
        }
        return user;
    }

    private String normalizedProfileAggregate() {
        String aggregate = profileNoseMatchProperties.getAggregate();
        if (aggregate == null || aggregate.isBlank()) {
            return MEDIAN_AGGREGATE;
        }
        return MEDIAN_AGGREGATE.equalsIgnoreCase(aggregate.trim()) ? MEDIAN_AGGREGATE : MEDIAN_AGGREGATE;
    }

    private Double median(List<Double> values) {
        if (values == null || values.isEmpty()) {
            return null;
        }
        List<Double> sorted = values.stream().sorted().toList();
        int size = sorted.size();
        int middle = size / 2;
        if (size % 2 == 1) {
            return sorted.get(middle);
        }
        return (sorted.get(middle - 1) + sorted.get(middle)) / 2.0;
    }

    private static String valueOrNull(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static Double numberAsDouble(Object value) {
        return value instanceof Number number ? number.doubleValue() : null;
    }

    private static Integer numberAsInteger(Object value) {
        return value instanceof Number number ? number.intValue() : null;
    }

    private static boolean booleanValue(Object value) {
        return value instanceof Boolean bool && bool;
    }

    private String filenameOrDefault(String filename, int referenceIndex) {
        return filename == null || filename.isBlank() ? "nose_image_%d.jpg".formatted(referenceIndex) : filename;
    }

    private BigDecimal toScore(double score) {
        return BigDecimal.valueOf(score).setScale(5, RoundingMode.HALF_UP);
    }

    private void logRegistrationTiming(RegistrationTiming timing, boolean completed) {
        if (!registrationTimingLogEnabled) {
            return;
        }
        log.info(
                "[DogRegistrationTiming] completed={}, dogId={}, result={}, totalMs={}, stagesMs={}",
                completed,
                timing.dogId(),
                timing.decisionResult(),
                timing.totalMillis(),
                timing.stages()
        );
    }

    private static final class RegistrationTiming {
        private final long startedNanos = System.nanoTime();
        private final Map<String, Long> stages = new LinkedHashMap<>();
        private long lastNanos = startedNanos;
        private String dogId;
        private VerificationResult decisionResult;

        void setDogId(String dogId) {
            this.dogId = dogId;
        }

        void setDecisionResult(VerificationResult decisionResult) {
            this.decisionResult = decisionResult;
        }

        void mark(String stageName) {
            long now = System.nanoTime();
            stages.put(stageName, nanosToMillis(now - lastNanos));
            lastNanos = now;
        }

        String dogId() {
            return dogId;
        }

        VerificationResult decisionResult() {
            return decisionResult;
        }

        long totalMillis() {
            return nanosToMillis(System.nanoTime() - startedNanos);
        }

        Map<String, Long> stages() {
            return new LinkedHashMap<>(stages);
        }

        private static long nanosToMillis(long nanos) {
            return Math.round(nanos / 1_000_000.0);
        }
    }

    private record NoseImageUpload(
            MultipartFile file,
            byte[] bytes,
            String filename,
            String contentType
    ) {
    }

    private record StoredNoseImage(
            Long dogImageId,
            FileStorageService.StoredFile storedFile
    ) {
    }

    private record PendingRegistration(
            String dogId,
            List<StoredNoseImage> noseImages,
            Long verificationLogId
    ) {

        private StoredNoseImage representativeNoseImage() {
            return noseImages.get(0);
        }
    }

    private record PreparedQdrantPoint(
            String pointId,
            List<Double> vector,
            Map<String, Object> payload,
            DogNoseEmbeddingKind embeddingKind,
            Long dogImageId,
            Integer referenceIndex
    ) {
    }

    private record ProfileConsistencyDecision(
            boolean allowed,
            double threshold,
            int minPassCount,
            int passCount,
            Double medianScore,
            String aggregate,
            List<ProfileMatchScoreResponse> scores,
            boolean thresholdCalibrated,
            String model,
            Integer dimension,
            String failureReason
    ) {
    }
}
