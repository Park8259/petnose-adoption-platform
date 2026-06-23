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
import java.util.Comparator;
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
    private static final String PROFILE_CENTROID_MISMATCH = "PROFILE_CENTROID_MISMATCH";
    private static final String PROFILE_FACE_EMBED_FAILED = "PROFILE_FACE_EMBED_FAILED";
    private static final String PROFILE_FACE_EMBEDDING_DIMENSION_MISMATCH = "PROFILE_FACE_EMBEDDING_DIMENSION_MISMATCH";
    private static final String FACE_CHECK_IMAGE_REQUIRED = "FACE_CHECK_IMAGE_REQUIRED";
    private static final String DETECTOR_UNAVAILABLE = "DETECTOR_UNAVAILABLE";
    private static final String MEDIAN_AGGREGATE = "median";
    private static final String DEMO_TRACE_PREFIX = "[DEMO_TRACE]";
    private static final String DEMO_SUMMARY_PREFIX = "[DEMO_SUMMARY]";

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

    @Value("${qdrant.collection}")
    private String qdrantCollection;

    @Value("${petnose.registration-timing-log-enabled:true}")
    private boolean registrationTimingLogEnabled;

    @Value("${demo-trace.enabled:false}")
    private boolean demoTraceEnabled;

    @Value("${demo-trace.profile-compare.enabled:false}")
    private boolean demoTraceProfileCompareEnabled;

    @Value("${demo-trace.profile-compare.threshold:0.65}")
    private double demoTraceProfileCompareThreshold;

    @Value("${demo-trace.profile-compare.min-pass-count:4}")
    private int demoTraceProfileCompareMinPassCount;

    @Value("${demo-trace.profile-compare.log-per-image:true}")
    private boolean demoTraceProfileCompareLogPerImage;

    @Value("${demo-trace.reference-log-pairs:false}")
    private boolean demoTraceReferenceLogPairs;

    @Value("${demo-trace.profile-compare.fail-open:true}")
    private boolean demoTraceProfileCompareFailOpen;

    @Value("${demo-summary.enabled:false}")
    private boolean demoSummaryEnabled;

    @Value("${demo-summary.include-request-id:false}")
    private boolean demoSummaryIncludeRequestId;

    @Value("${demo-summary.include-timing:false}")
    private boolean demoSummaryIncludeTiming;

    @Value("${profile-centroid-gate.enabled:false}")
    private boolean profileCentroidGateEnabled;

    @Value("${profile-centroid-gate.threshold:0.65}")
    private double profileCentroidGateThreshold;

    @Value("${profile-centroid-gate.require-face-image:false}")
    private boolean profileCentroidGateRequireFaceImage;

    @Value("${profile-centroid-gate.fail-open:false}")
    private boolean profileCentroidGateFailOpen;

    public DogProfileDraftResponse createProfileDraft(DogProfileDraftRequest request) {
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

    public DogRegisterResponse register(DogRegisterRequest request) {
        return register(request, null, null, null);
    }

    public DogRegisterResponse register(
            DogRegisterRequest request,
            MultipartFile faceCheckImage,
            String requestId
    ) {
        return register(request, null, faceCheckImage, requestId);
    }

    public DogRegisterResponse register(
            DogRegisterRequest request,
            MultipartFile profileImage,
            MultipartFile faceCheckImage,
            String requestId
    ) {
        String traceRequestId = requestIdForTrace(requestId);
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

            logDemoRegisterRequest(request, uploads.size(), hasPresentFile(profileImage), hasPresentFile(faceCheckImage), traceRequestId);
            rejectMissingRequiredFaceCheckImageBeforePipeline(faceCheckImage, traceRequestId);
            timing.mark("require_face_check_image");

            runDemoProfileNoseCompare(request, faceCheckImage, uploads, traceRequestId);
            timing.mark("demo_profile_nose_compare");

            User user = userRepository.findById(request.userId())
                    .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "USER_NOT_FOUND", "존재하지 않는 user_id 입니다."));
            timing.mark("load_user");

            String dogId = UUID.randomUUID().toString();
            timing.setDogId(dogId);

            EmbedClient.BatchEmbedResponse embedResponse = requestBatchEmbeddingOrFail(dogId, uploads, traceRequestId);
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

            logDemoNoseReferenceTrace(qualityReport, referenceVectors, centroidVector, traceRequestId);

            ProfileNoseMatchResult profileNoseMatchResult =
                    enforceProfileCentroidGateOrFail(faceCheckImage, centroidVector, embedResponse, traceRequestId);
            timing.mark("profile_centroid_gate");
            logDemoSummaryNoseReference(qualityReport, referenceVectors, centroidVector, traceRequestId);

            DogNoseAggregationResult aggregationResult = searchExistingDogsOrFail(dogId, referenceVectors, centroidVector, traceRequestId);
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

            StoredRegistrationImages storedImages = storeRegistrationImages(dogId, profileImage, uploads);
            timing.mark("file_store");

            PendingRegistration pending;
            try {
                pending = transactionTemplate.execute(status ->
                        createPendingRows(user.getId(), dogId, request, birthDate, age, price, storedImages.profileImage(), storedImages.noseImages())
                );
                timing.mark("db_create_pending_rows");
            } catch (RuntimeException e) {
                deleteStoredRegistrationImagesQuietly(storedImages);
                throw e;
            }
            if (pending == null) {
                deleteStoredRegistrationImagesQuietly(storedImages);
                throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "REGISTRATION_INIT_FAILED", "등록 초기화에 실패했습니다.");
            }

            DogRegisterResponse response = switch (decision.result()) {
                case DUPLICATE_SUSPECTED, REVIEW_REQUIRED ->
                        completeRegistrationWithoutQdrant(pending, embedResponse, decision, scoreBreakdown, scoreBreakdownJson, timing, traceRequestId, profileNoseMatchResult);
                case PASSED ->
                        completePassedRegistration(pending, embedResponse, referenceVectors, centroidVector, decision, scoreBreakdown, scoreBreakdownJson, timing, traceRequestId, profileNoseMatchResult);
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
            EmbedClient.BatchEmbedResponse embedResponse = requestBatchEmbeddingOrFail(dog.getId(), uploads, null);
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

            logDemoNoseReferenceTrace(qualityReport, referenceVectors, centroidVector, null);
            logDemoSummaryNoseReference(qualityReport, referenceVectors, centroidVector, null);
            ProfileNoseMatchResult profileNoseMatchResult = ProfileNoseMatchResult.empty();

            DogNoseAggregationResult aggregationResult = searchExistingDogsOrFail(dog.getId(), referenceVectors, centroidVector, null);
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
                        completeRegistrationWithoutQdrant(pending, embedResponse, decision, scoreBreakdown, scoreBreakdownJson, timing, null, profileNoseMatchResult);
                case PASSED ->
                        completePassedRegistration(pending, embedResponse, referenceVectors, centroidVector, decision, scoreBreakdown, scoreBreakdownJson, timing, null, profileNoseMatchResult);
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

        return new PendingRegistration(dogId, null, List.copyOf(noseImages), verificationLog.getId());
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

    private void runDemoProfileNoseCompare(
            DogRegisterRequest request,
            MultipartFile faceCheckImage,
            List<NoseImageUpload> uploads,
            String requestId
    ) {
        if (!demoTraceEnabled || !demoTraceProfileCompareEnabled || !hasPresentFile(faceCheckImage)) {
            return;
        }

        long startedNanos = System.nanoTime();
        log.info("{} flow=profile_nose_compare step=start request_id={} user_id={} dog_name={} breed={} face_image_present=true nose_count={} threshold={} required_pass={}",
                DEMO_TRACE_PREFIX,
                safe(requestId),
                request.userId(),
                safe(request.name()),
                safe(request.breed()),
                uploads.size(),
                formatScore(demoTraceProfileCompareThreshold),
                demoTraceProfileCompareMinPassCount);

        try {
            List<EmbedClient.BatchImageInput> noseInputs = uploads.stream()
                    .map(upload -> new EmbedClient.BatchImageInput(upload.bytes(), upload.filename(), upload.contentType()))
                    .toList();

            EmbedClient.ProfileNoseMatchBatchResponse response = embedClient.profileNoseMatchBatch(
                    faceCheckImage.getBytes(),
                    filenameOrDefault(faceCheckImage.getOriginalFilename(), 0),
                    contentTypeOrDefault(faceCheckImage),
                    noseInputs,
                    requestId
            );
            DemoProfileCompareStats stats = demoProfileCompareStats(response);
            String decision = stats.passed() ? "PASS" : "FAIL";
            int failCount = Math.max(0, stats.total() - stats.passCount());
            log.info("{} flow=profile_nose_compare step=summary request_id={} model={} dimension={} threshold={} threshold_calibrated={} total={} pass={} fail={} min={} max={} mean={} median={} min_percent={} max_percent={} median_percent={} decision={} elapsed_ms={}",
                    DEMO_TRACE_PREFIX,
                    safe(requestId),
                    safe(response.model()),
                    response.dimension(),
                    formatScore(demoTraceProfileCompareThreshold),
                    response.thresholdCalibrated(),
                    stats.total(),
                    stats.passCount(),
                    failCount,
                    formatNullableScore(stats.minScore()),
                    formatNullableScore(stats.maxScore()),
                    formatNullableScore(stats.meanScore()),
                    formatNullableScore(stats.medianScore()),
                    formatNullablePercent(stats.minScore()),
                    formatNullablePercent(stats.maxScore()),
                    formatNullablePercent(stats.medianScore()),
                    decision,
                    elapsedMillis(startedNanos));

            logDemoProfileCentroidCompare(response, requestId);

            if (demoTraceProfileCompareLogPerImage) {
                for (ProfileMatchScoreResponse score : stats.scores()) {
                    log.info("{} flow=profile_nose_compare step=per_image request_id={} index={} score={} percent={} passed={}",
                            DEMO_TRACE_PREFIX,
                            safe(requestId),
                            score.index(),
                            formatNullableScore(score.score()),
                            formatNullablePercent(score.score()),
                            score.passed());
                }
            }

            if (response.failureReason() != null) {
                log.info("{} flow=profile_nose_compare step=failed request_id={} failure_reason={} action={}",
                        DEMO_TRACE_PREFIX,
                        safe(requestId),
                        safe(response.failureReason()),
                        demoTraceProfileCompareFailOpen ? "ignored_fail_open" : "ignored_trace_only");
            }
        } catch (Exception e) {
            log.info("{} flow=profile_nose_compare step=failed request_id={} failure_reason={} action={} elapsed_ms={}",
                    DEMO_TRACE_PREFIX,
                    safe(requestId),
                    safe(e.getClass().getSimpleName()),
                    demoTraceProfileCompareFailOpen ? "ignored_fail_open" : "ignored_trace_only",
                    elapsedMillis(startedNanos));
        }
    }

    private ProfileNoseMatchResult enforceProfileCentroidGateOrFail(
            MultipartFile faceCheckImage,
            List<Double> centroidVector,
            EmbedClient.BatchEmbedResponse embedResponse,
            String requestId
    ) {
        boolean faceImagePresent = hasPresentFile(faceCheckImage);
        if (!profileCentroidGateEnabled) {
            logProfileCentroidGateSkipped(requestId, "GATE_DISABLED", faceImagePresent);
            return ProfileNoseMatchResult.empty();
        }
        if (!faceImagePresent) {
            if (!profileCentroidGateRequireFaceImage) {
                logProfileCentroidGateSkipped(requestId, "FACE_CHECK_IMAGE_ABSENT", false);
                return ProfileNoseMatchResult.empty();
            }
            handleProfileCentroidGateFailure(
                    FACE_CHECK_IMAGE_REQUIRED,
                    "얼굴·코 확인용 정면 사진이 필요합니다.",
                    "FACE_CHECK_IMAGE_ABSENT",
                    null,
                    embedResponse.model(),
                    embedResponse.dimension(),
                    requestId
            );
            return ProfileNoseMatchResult.empty();
        }

        long startedNanos = System.nanoTime();
        if (demoTraceEnabled) {
            log.info("{} flow=profile_centroid_gate step=start request_id={} face_image_present=true threshold={} fail_open={} expected_dimension={}",
                    DEMO_TRACE_PREFIX,
                    safe(requestId),
                    formatScore(profileCentroidGateThreshold),
                    profileCentroidGateFailOpen,
                    expectedVectorDimension);
        }

        EmbedClient.FaceNoseEmbeddingResponse response;
        try {
            response = embedClient.extractNoseEmbeddingFromFaceImage(
                    faceCheckImage.getBytes(),
                    filenameOrDefault(faceCheckImage.getOriginalFilename(), 0),
                    contentTypeOrDefault(faceCheckImage),
                    requestId
            );
        } catch (IOException e) {
            handleProfileCentroidGateFailure(
                    PROFILE_FACE_EMBED_FAILED,
                    "얼굴·코 확인용 정면 사진을 읽지 못했습니다.",
                    "FACE_IMAGE_READ_FAILED",
                    null,
                    embedResponse.model(),
                    embedResponse.dimension(),
                    requestId
            );
            return ProfileNoseMatchResult.empty();
        } catch (EmbedClient.EmbedClientException e) {
            handleProfileCentroidGateFailure(
                    PROFILE_FACE_EMBED_FAILED,
                    "얼굴·코 확인용 정면 사진에서 코 임베딩을 만들지 못했습니다.",
                    "EMBED_SERVICE_UNAVAILABLE",
                    null,
                    embedResponse.model(),
                    embedResponse.dimension(),
                    requestId
            );
            return ProfileNoseMatchResult.empty();
        }

        if (demoTraceEnabled) {
            log.info("{} flow=profile_centroid_gate step=face_embed_done request_id={} extracted={} confidence={} crop={} model={} dimension={} failure_reason={} elapsed_ms={}",
                    DEMO_TRACE_PREFIX,
                    safe(requestId),
                    response.extracted(),
                    formatNullableScore(response.confidence()),
                    cropText(response.cropWidth(), response.cropHeight()),
                    safe(response.model()),
                    response.dimension(),
                    safe(response.failureReason()),
                    elapsedMillis(startedNanos));
        }
        logProfileCentroidGateQuality(response.quality(), requestId);
        logDemoSummaryFaceCheck(response, requestId);

        List<Double> faceEmbedding = response.embedding();
        if (!response.extracted() || faceEmbedding == null || faceEmbedding.isEmpty()) {
            String failureReason = response.failureReason() == null ? "NO_FACE_NOSE_EMBEDDING" : response.failureReason();
            handleProfileCentroidGateFailure(
                    PROFILE_FACE_EMBED_FAILED,
                    profileFaceFailureMessage(failureReason),
                    failureReason,
                    null,
                    response.model(),
                    response.dimension(),
                    requestId,
                    response.quality()
            );
            return ProfileNoseMatchResult.empty();
        }

        if (!isGateDimensionValid(response, faceEmbedding, centroidVector, embedResponse)) {
            handleProfileCentroidGateFailure(
                    PROFILE_FACE_EMBEDDING_DIMENSION_MISMATCH,
                    "얼굴·코 확인용 정면 사진 임베딩 차원이 비문 임베딩 차원과 일치하지 않습니다.",
                    "EMBEDDING_DIMENSION_MISMATCH",
                    null,
                    response.model(),
                    response.dimension(),
                    requestId,
                    response.quality()
            );
            return ProfileNoseMatchResult.empty();
        }

        double score = NoseVectorMath.dot(faceEmbedding, centroidVector);
        boolean passed = score >= profileCentroidGateThreshold;
        logDemoSummaryProfileCentroid(passed, score, requestId);
        if (demoTraceEnabled) {
            log.info("{} flow=profile_centroid_gate step=compare request_id={} profile_vs_centroid={} profile_vs_centroid_percent={} threshold={} passed={} face_dimension={} centroid_dimension={} model={}",
                    DEMO_TRACE_PREFIX,
                    safe(requestId),
                    formatScore(score),
                    formatPercent(score),
                    formatScore(profileCentroidGateThreshold),
                    passed,
                    faceEmbedding.size(),
                    centroidVector.size(),
                    safe(response.model()));
        }

        if (!passed) {
            String message = "얼굴·코 확인 사진과 비문 5장이 같은 강아지로 확인되지 않았습니다. 일치도 %s%%, 기준 %s%%"
                    .formatted(formatPercent(score), formatPercent(profileCentroidGateThreshold));
            logProfileCentroidGateDecision(requestId, "FAIL", "PROFILE_CENTROID_MISMATCH", score, response.model(), response.dimension());
            handleProfileCentroidGateFailure(
                    PROFILE_CENTROID_MISMATCH,
                    message,
                    "PROFILE_CENTROID_MISMATCH",
                    score,
                    response.model(),
                    response.dimension(),
                    requestId,
                    response.quality()
            );
            return new ProfileNoseMatchResult(score);
        }

        logProfileCentroidGateDecision(requestId, "PASS", null, score, response.model(), response.dimension());
        return new ProfileNoseMatchResult(score);
    }

    private void rejectMissingRequiredFaceCheckImageBeforePipeline(
            MultipartFile faceCheckImage,
            String requestId
    ) {
        if (!profileCentroidGateEnabled
                || !profileCentroidGateRequireFaceImage
                || hasPresentFile(faceCheckImage)) {
            return;
        }
        logProfileCentroidGateMissingFaceDecision(requestId);
        logDemoSummary(
                "[2] face-vs-centroid",
                "FAIL",
                List.of("reason=FACE_CHECK_IMAGE_REQUIRED"),
                requestId
        );
        logDemoSummaryFinalRejected("FACE_CHECK_IMAGE_REQUIRED", requestId);
        throw new ApiException(
                HttpStatus.UNPROCESSABLE_ENTITY,
                FACE_CHECK_IMAGE_REQUIRED,
                "얼굴·코 확인용 정면 사진이 필요합니다.",
                profileCentroidGateDetails("FACE_CHECK_IMAGE_ABSENT", null, null, null, null)
        );
    }

    private boolean isGateDimensionValid(
            EmbedClient.FaceNoseEmbeddingResponse response,
            List<Double> faceEmbedding,
            List<Double> centroidVector,
            EmbedClient.BatchEmbedResponse embedResponse
    ) {
        return response.dimension() != null
                && response.dimension() == expectedVectorDimension
                && response.dimension() == embedResponse.dimension()
                && faceEmbedding.size() == expectedVectorDimension
                && centroidVector != null
                && centroidVector.size() == expectedVectorDimension
                && vectorFinite(faceEmbedding)
                && vectorFinite(centroidVector);
    }

    private void handleProfileCentroidGateFailure(
            String errorCode,
            String message,
            String failureReason,
            Double score,
            String model,
            Integer dimension,
            String requestId
    ) {
        handleProfileCentroidGateFailure(errorCode, message, failureReason, score, model, dimension, requestId, null);
    }

    private void handleProfileCentroidGateFailure(
            String errorCode,
            String message,
            String failureReason,
            Double score,
            String model,
            Integer dimension,
            String requestId,
            EmbedClient.FaceCheckQualityResponse quality
    ) {
        String action = profileCentroidGateFailOpen ? "continue_fail_open" : "reject";
        if (demoTraceEnabled) {
            log.info("{} flow=profile_centroid_gate step=failed request_id={} failure_reason={} action={} score={} score_percent={} threshold={} model={} dimension={}",
                    DEMO_TRACE_PREFIX,
                    safe(requestId),
                    safe(failureReason),
                    action,
                    formatNullableScore(score),
                    formatNullablePercent(score),
                    formatScore(profileCentroidGateThreshold),
                    safe(model),
                    dimension);
        }
        if (profileCentroidGateFailOpen) {
            return;
        }
        logDemoSummaryFinalRejected(failureReason, requestId);
        throw new ApiException(
                HttpStatus.UNPROCESSABLE_ENTITY,
                errorCode,
                message,
                profileCentroidGateDetails(failureReason, score, model, dimension, quality)
        );
    }

    private void logProfileCentroidGateQuality(EmbedClient.FaceCheckQualityResponse quality, String requestId) {
        if (!demoTraceEnabled || quality == null) {
            return;
        }
        String action = quality.passed()
                ? "continue"
                : (profileCentroidGateFailOpen ? "continue_fail_open" : "reject_before_qdrant");
        log.info("{} flow=profile_centroid_gate step=face_quality request_id={} purpose={} passed={} failure_reason={} nose_area_ratio={} nose_width_ratio={} nose_height_ratio={} edge_margin_ratio={} center_x={} center_y={} action={}",
                DEMO_TRACE_PREFIX,
                safe(requestId),
                safe(quality.purpose()),
                quality.passed(),
                safe(quality.failureReason()),
                formatNullableScore(quality.noseAreaRatio()),
                formatNullableScore(quality.noseWidthRatio()),
                formatNullableScore(quality.noseHeightRatio()),
                formatNullableScore(quality.edgeMarginRatio()),
                formatNullableScore(quality.centerX()),
                formatNullableScore(quality.centerY()),
                action);
    }

    private void logProfileCentroidGateSkipped(String requestId, String reason, boolean faceImagePresent) {
        if (!demoTraceEnabled) {
            return;
        }
        log.info("{} flow=profile_centroid_gate step=skipped request_id={} reason={} gate_enabled={} face_image_present={} threshold={}",
                DEMO_TRACE_PREFIX,
                safe(requestId),
                safe(reason),
                profileCentroidGateEnabled,
                faceImagePresent,
                formatScore(profileCentroidGateThreshold));
    }

    private void logProfileCentroidGateMissingFaceDecision(String requestId) {
        if (!demoTraceEnabled) {
            return;
        }
        log.info("{} flow=profile_centroid_gate step=decision request_id={} decision=FAIL reason=FACE_CHECK_IMAGE_ABSENT action=reject_before_qdrant qdrant_search=skipped qdrant_upsert=skipped db_write=skipped",
                DEMO_TRACE_PREFIX,
                safe(requestId));
    }

    private void logProfileCentroidGateDecision(
            String requestId,
            String decision,
            String failureReason,
            Double score,
            String model,
            Integer dimension
    ) {
        if (!demoTraceEnabled) {
            return;
        }
        log.info("{} flow=profile_centroid_gate step=decision request_id={} decision={} action={} failure_reason={} score={} score_percent={} threshold={} model={} dimension={}",
                DEMO_TRACE_PREFIX,
                safe(requestId),
                safe(decision),
                "FAIL".equals(decision) && profileCentroidGateFailOpen ? "continue_fail_open" : ("FAIL".equals(decision) ? "reject" : "continue"),
                safe(failureReason),
                formatNullableScore(score),
                formatNullablePercent(score),
                formatScore(profileCentroidGateThreshold),
                safe(model),
                dimension);
    }

    private Map<String, Object> profileCentroidGateDetails(
            String failureReason,
            Double score,
            String model,
            Integer dimension,
            EmbedClient.FaceCheckQualityResponse quality
    ) {
        Map<String, Object> details = new LinkedHashMap<>();
        details.put("failure_reason", failureReason);
        details.put("similarity_score", score);
        details.put("similarity_percent", score == null ? null : formatPercent(score));
        details.put("threshold", profileCentroidGateThreshold);
        details.put("threshold_percent", formatPercent(profileCentroidGateThreshold));
        details.put("model", model);
        details.put("dimension", dimension);
        if (quality != null) {
            details.put("quality", faceCheckQualityDetails(quality));
        }
        return details;
    }

    private Map<String, Object> faceCheckQualityDetails(EmbedClient.FaceCheckQualityResponse quality) {
        Map<String, Object> details = new LinkedHashMap<>();
        details.put("purpose", quality.purpose());
        details.put("passed", quality.passed());
        details.put("nose_area_ratio", quality.noseAreaRatio());
        details.put("nose_width_ratio", quality.noseWidthRatio());
        details.put("nose_height_ratio", quality.noseHeightRatio());
        details.put("edge_margin_ratio", quality.edgeMarginRatio());
        details.put("center_x", quality.centerX());
        details.put("center_y", quality.centerY());
        details.put("failure_reason", quality.failureReason());
        return details;
    }

    private String profileFaceFailureMessage(String failureReason) {
        return switch (failureReason) {
            case "NOSE_TOO_LARGE_FOR_FACE_CHECK" -> "코만 너무 크게 나온 사진입니다. 얼굴이 조금 더 보이는 정면 사진을 선택해주세요.";
            case "NOSE_TOO_SMALL_FOR_FACE_CHECK" -> "코가 너무 작게 보입니다. 얼굴과 코가 더 잘 보이는 사진을 선택해주세요.";
            case "NOSE_TOUCHES_IMAGE_EDGE" -> "코가 사진 가장자리에 너무 가깝거나 잘렸습니다.";
            case "NOSE_OFF_CENTER" -> "코가 사진 중앙에서 너무 벗어났습니다. 정면 사진을 선택해주세요.";
            case "MULTIPLE_NOSES_DETECTED" -> "여러 개의 코 후보가 감지되었습니다. 한 마리만 나온 사진을 선택해주세요.";
            case "NO_NOSE_DETECTED" -> "코 영역을 찾지 못했습니다. 더 선명한 정면 사진을 선택해주세요.";
            default -> "얼굴·코 확인용 정면 사진에서 코 영역 임베딩을 만들지 못했습니다.";
        };
    }

    private static String cropText(Integer width, Integer height) {
        if (width == null || height == null) {
            return "null";
        }
        return "%dx%d".formatted(width, height);
    }

    private DemoProfileCompareStats demoProfileCompareStats(EmbedClient.ProfileNoseMatchBatchResponse response) {
        List<ProfileMatchScoreResponse> scores = new ArrayList<>();
        for (int i = 0; i < response.scores().size(); i++) {
            EmbedClient.ProfileNoseMatchBatchScore score = response.scores().get(i);
            Double value = score.similarityScore();
            scores.add(new ProfileMatchScoreResponse(
                    score.index() <= 0 ? i + 1 : score.index(),
                    value,
                    value != null && value >= demoTraceProfileCompareThreshold
            ));
        }
        List<Double> values = scores.stream()
                .map(ProfileMatchScoreResponse::score)
                .filter(value -> value != null)
                .toList();
        Double min = values.stream().min(Comparator.naturalOrder()).orElse(null);
        Double max = values.stream().max(Comparator.naturalOrder()).orElse(null);
        Double mean = values.isEmpty() ? null : values.stream().mapToDouble(Double::doubleValue).average().orElse(0.0);
        Double median = median(values);
        int passCount = (int) scores.stream().filter(ProfileMatchScoreResponse::passed).count();
        boolean passed = response.profileNoseExtracted()
                && response.failureReason() == null
                && scores.size() == noseRegistrationProperties.getReferenceMaxCount()
                && passCount >= demoTraceProfileCompareMinPassCount
                && median != null
                && median >= demoTraceProfileCompareThreshold;

        return new DemoProfileCompareStats(
                scores.size(),
                passCount,
                min,
                max,
                mean,
                median,
                List.copyOf(scores),
                passed
        );
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

    private EmbedClient.BatchEmbedResponse requestBatchEmbeddingOrFail(
            String dogId,
            List<NoseImageUpload> uploads,
            String requestId
    ) {
        List<EmbedClient.BatchImageInput> inputs = uploads.stream()
                .map(upload -> new EmbedClient.BatchImageInput(upload.bytes(), upload.filename(), upload.contentType()))
                .toList();

        long startedNanos = System.nanoTime();
        if (demoTraceEnabled) {
            log.info("{} flow=embed_batch step=start request_id={} dog_id={} image_count={}",
                    DEMO_TRACE_PREFIX, safe(requestId), safe(dogId), uploads.size());
        }
        try {
            EmbedClient.BatchEmbedResponse response = requestId == null || requestId.isBlank()
                    ? embedClient.embedBatch(inputs)
                    : embedClient.embedBatch(inputs, requestId);
            if (demoTraceEnabled) {
                log.info("{} flow=embed_batch step=done request_id={} dog_id={} image_count={} model={} dimension={} elapsed_ms={}",
                        DEMO_TRACE_PREFIX,
                        safe(requestId),
                        safe(dogId),
                        uploads.size(),
                        safe(response.model()),
                        response.dimension(),
                        elapsedMillis(startedNanos));
            }
            return response;
        } catch (EmbedClient.EmbedClientException e) {
            if (demoTraceEnabled) {
                log.info("{} flow=dog_register step=failed request_id={} dog_id={} failure_reason=EMBED_SERVICE_UNAVAILABLE elapsed_ms={}",
                        DEMO_TRACE_PREFIX, safe(requestId), safe(dogId), elapsedMillis(startedNanos));
            }
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
            List<Double> centroidVector,
            String requestId
    ) {
        long startedNanos = System.nanoTime();
        if (demoTraceEnabled) {
            log.info("{} flow=dog_register step=qdrant_search_start request_id={} dog_id={} collection={} dimension={}",
                    DEMO_TRACE_PREFIX,
                    safe(requestId),
                    safe(dogId),
                    safe(qdrantCollection),
                    expectedVectorDimension);
        }
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
            DogNoseAggregationResult result = dogNoseCandidateAggregator.aggregate(
                    referenceResults,
                    centroidResults,
                    noseRegistrationProperties.getReviewLowerBound()
            );
            result = filterExistingDogCandidates(result, requestId, dogId);
            DogNoseCandidateScore topCandidate = result.topCandidate();
            Double topScore = topCandidate == null ? null : topCandidate.finalScore();
            logDemoSummaryQdrant(topScore, noseRegistrationProperties.getDuplicateThreshold(), requestId);
            if (demoTraceEnabled) {
                log.info("{} flow=dog_register step=qdrant_search_done request_id={} dog_id={} candidate_count={} top_score={} top_score_percent={} duplicate_threshold={} duplicate={} elapsed_ms={}",
                        DEMO_TRACE_PREFIX,
                        safe(requestId),
                        safe(dogId),
                        result.candidates().size(),
                        formatNullableScore(topScore),
                        formatNullablePercent(topScore),
                        formatScore(noseRegistrationProperties.getDuplicateThreshold()),
                        topScore != null && topScore >= noseRegistrationProperties.getDuplicateThreshold(),
                        elapsedMillis(startedNanos));
            }
            return result;
        } catch (QdrantDogVectorClient.QdrantClientException e) {
            log.warn("[DogRegistration] qdrant v2 search 실패: dogId={}, status={}, message={}",
                    dogId, e.getUpstreamStatus(), e.getMessage());
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "QDRANT_SEARCH_FAILED", "중복 검증 검색에 실패했습니다.");
        }
    }

    private DogNoseAggregationResult filterExistingDogCandidates(
            DogNoseAggregationResult result,
            String requestId,
            String dogId
    ) {
        if (result == null) {
            return new DogNoseAggregationResult(List.of(), null);
        }
        if (result.candidates().isEmpty()) {
            return result;
        }

        List<DogNoseCandidateScore> existingCandidates = new ArrayList<>();
        int staleCandidateCount = 0;
        for (DogNoseCandidateScore candidate : result.candidates()) {
            if (dogRepository.findById(candidate.dogId()).isPresent()) {
                existingCandidates.add(candidate);
                continue;
            }
            staleCandidateCount++;
            log.warn("[DogRegistration] stale qdrant candidate ignored: requestId={}, dogId={}, candidateDogId={}",
                    safe(requestId), safe(dogId), safe(candidate.dogId()));
        }

        if (staleCandidateCount > 0 && demoTraceEnabled) {
            log.info("{} flow=dog_register step=qdrant_stale_candidates_ignored request_id={} dog_id={} stale_count={} remaining_count={}",
                    DEMO_TRACE_PREFIX,
                    safe(requestId),
                    safe(dogId),
                    staleCandidateCount,
                    existingCandidates.size());
        }
        if (staleCandidateCount == 0) {
            return result;
        }
        return new DogNoseAggregationResult(
                List.copyOf(existingCandidates),
                existingCandidates.isEmpty() ? null : existingCandidates.get(0)
        );
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

    private StoredRegistrationImages storeRegistrationImages(
            String dogId,
            MultipartFile profileImage,
            List<NoseImageUpload> uploads
    ) {
        FileStorageService.StoredFile storedProfile = null;
        List<FileStorageService.StoredFile> storedNoseFiles = new ArrayList<>();
        try {
            if (hasPresentFile(profileImage)) {
                storedProfile = fileStorageService.storeProfileImage(dogId, profileImage);
            }
            for (NoseImageUpload upload : uploads) {
                storedNoseFiles.add(fileStorageService.storeNoseImage(dogId, upload.file()));
            }
            return new StoredRegistrationImages(storedProfile, List.copyOf(storedNoseFiles));
        } catch (RuntimeException e) {
            fileStorageService.deleteStoredFileQuietly(storedProfile);
            fileStorageService.deleteStoredFilesQuietly(storedNoseFiles);
            throw e;
        }
    }

    private void deleteStoredRegistrationImagesQuietly(StoredRegistrationImages storedImages) {
        if (storedImages == null) {
            return;
        }
        fileStorageService.deleteStoredFileQuietly(storedImages.profileImage());
        fileStorageService.deleteStoredFilesQuietly(storedImages.noseImages());
    }

    private PendingRegistration createPendingRows(
            Long userId,
            String dogId,
            DogRegisterRequest request,
            LocalDate birthDate,
            Integer age,
            Long price,
            FileStorageService.StoredFile storedProfile,
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

        if (storedProfile != null) {
            dogImageRepository.save(buildDogImage(dogId, DogImageType.PROFILE, storedProfile));
        }

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

        return new PendingRegistration(dogId, storedProfile, List.copyOf(noseImages), verificationLog.getId());
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
            RegistrationTiming timing,
            String requestId,
            ProfileNoseMatchResult profileNoseMatchResult
    ) {
        transactionTemplate.executeWithoutResult(status ->
                markAsDecision(pending, embedResponse, decision, scoreBreakdownJson)
        );
        timing.mark("db_mark_decision");

        DogRegisterResponse response = buildResponse(pending, embedResponse, decision, scoreBreakdown, profileNoseMatchResult, messageFor(decision.result()));
        timing.mark("build_response");
        logDemoFinalDecision(pending, embedResponse, decision, response, "skipped", requestId);
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
            RegistrationTiming timing,
            String requestId,
            ProfileNoseMatchResult profileNoseMatchResult
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

        DogRegisterResponse response = buildResponse(pending, embedResponse, decision, scoreBreakdown, profileNoseMatchResult, messageFor(decision.result()));
        timing.mark("build_response");
        logDemoFinalDecision(pending, embedResponse, decision, response, "done", requestId);
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
            ProfileNoseMatchResult profileNoseMatchResult,
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
                profileNoseMatchResult == null ? null : profileNoseMatchResult.score(),
                fileStorageService.toPublicUrl(representative.storedFile().relativePath()),
                pending.profileImage() == null
                        ? null
                        : fileStorageService.toPublicUrl(pending.profileImage().relativePath()),
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

    private void logDemoRegisterRequest(
            DogRegisterRequest request,
            int noseCount,
            boolean profileImagePresent,
            boolean faceCheckImagePresent,
            String requestId
    ) {
        if (!demoTraceEnabled) {
            return;
        }
        log.info("{} flow=dog_register step=request_received request_id={} user_id={} dog_name={} breed={} gender={} nose_count={} profile_image_present={} face_check_image_present={}",
                DEMO_TRACE_PREFIX,
                safe(requestId),
                request.userId(),
                safe(request.name()),
                safe(request.breed()),
                safe(request.gender()),
                noseCount,
                profileImagePresent,
                faceCheckImagePresent);
    }

    private void logDemoNoseReferenceTrace(
            ReferenceQualityReport qualityReport,
            List<List<Double>> referenceVectors,
            List<Double> centroidVector,
            String requestId
    ) {
        if (!demoTraceEnabled) {
            return;
        }
        try {
            List<Double> pairwiseValues = qualityReport.pairwiseScores().stream()
                    .map(PairwiseScore::score)
                    .toList();
            DemoScoreStats pairwiseStats = demoScoreStats(pairwiseValues, qualityReport.threshold());
            String decision = referenceQualityPassed(qualityReport) ? "PASS" : "FAIL";
            log.info("{} flow=nose_reference step=pairwise_summary request_id={} pair_count={} min={} max={} mean={} median={} threshold={} pass={} fail={} decision={}",
                    DEMO_TRACE_PREFIX,
                    safe(requestId),
                    qualityReport.pairwiseScores().size(),
                    formatNullableScore(pairwiseStats.min()),
                    formatNullableScore(pairwiseStats.max()),
                    formatNullableScore(pairwiseStats.mean()),
                    formatNullableScore(pairwiseStats.median()),
                    formatScore(qualityReport.threshold()),
                    pairwiseStats.passCount(),
                    pairwiseStats.failCount(),
                    decision);

            if (demoTraceReferenceLogPairs) {
                for (PairwiseScore pair : qualityReport.pairwiseScores()) {
                    log.info("{} flow=nose_reference step=pair request_id={} pair={}-{} score={} percent={} passed={}",
                            DEMO_TRACE_PREFIX,
                            safe(requestId),
                            pair.imageA(),
                            pair.imageB(),
                            formatScore(pair.score()),
                            formatPercent(pair.score()),
                            pair.score() >= qualityReport.threshold());
                }
            }

            long outlierCount = qualityReport.perImageQualities().stream()
                    .filter(quality -> quality.belowThresholdPairsCount() > 0)
                    .count();
            log.info("{} flow=nose_reference step=quality_check request_id={} passed={} verdict={} reason={} min_pairwise={} median_pairwise={} average_pairwise={} weakest_image_index={} weakest_image_average={} outlier_count={}",
                    DEMO_TRACE_PREFIX,
                    safe(requestId),
                    referenceQualityPassed(qualityReport),
                    qualityReport.verdict(),
                    referenceQualityPassed(qualityReport) ? null : qualityReport.verdict(),
                    formatScore(qualityReport.minPairwiseScore()),
                    formatNullableScore(pairwiseStats.median()),
                    formatScore(qualityReport.averagePairwiseScore()),
                    qualityReport.weakestImageIndex(),
                    formatNullableScore(qualityReport.weakestImageAverageScore()),
                    outlierCount);

            log.info("{} flow=nose_reference step=centroid_built request_id={} source_count={} dimension={} norm={} finite={}",
                    DEMO_TRACE_PREFIX,
                    safe(requestId),
                    referenceVectors.size(),
                    centroidVector == null ? null : centroidVector.size(),
                    formatNullableScore(vectorNorm(centroidVector)),
                    vectorFinite(centroidVector));

            List<Double> centroidSimilarities = new ArrayList<>();
            for (int i = 0; i < referenceVectors.size(); i++) {
                double score = NoseVectorMath.dot(referenceVectors.get(i), centroidVector);
                centroidSimilarities.add(score);
                log.info("{} flow=nose_reference step=to_centroid request_id={} index={} score={} percent={} passed={}",
                        DEMO_TRACE_PREFIX,
                        safe(requestId),
                        i + 1,
                        formatScore(score),
                        formatPercent(score),
                        score >= qualityReport.threshold());
            }
            DemoScoreStats centroidStats = demoScoreStats(centroidSimilarities, qualityReport.threshold());
            log.info("{} flow=nose_reference step=centroid_similarity_summary request_id={} min={} max={} mean={} median={} threshold={} pass={} fail={}",
                    DEMO_TRACE_PREFIX,
                    safe(requestId),
                    formatNullableScore(centroidStats.min()),
                    formatNullableScore(centroidStats.max()),
                    formatNullableScore(centroidStats.mean()),
                    formatNullableScore(centroidStats.median()),
                    formatScore(qualityReport.threshold()),
                    centroidStats.passCount(),
                    centroidStats.failCount());
        } catch (Exception e) {
            log.info("{} flow=nose_reference step=trace_failed request_id={} failure_reason={} action=ignored_fail_open",
                    DEMO_TRACE_PREFIX,
                    safe(requestId),
                    safe(e.getClass().getSimpleName()));
        }
    }

    private void logDemoProfileCentroidCompare(
            EmbedClient.ProfileNoseMatchBatchResponse response,
            String requestId
    ) {
        Double score = response.profileVsCentroidScore();
        if (score == null) {
            return;
        }
        boolean passed = response.profileVsCentroidPassed() != null
                ? response.profileVsCentroidPassed()
                : score >= demoTraceProfileCompareThreshold;
        log.info("{} flow=profile_nose_compare step=centroid_compare request_id={} profile_vs_centroid={} profile_vs_centroid_percent={} threshold={} passed={} centroid_dimension={}",
                DEMO_TRACE_PREFIX,
                safe(requestId),
                formatScore(score),
                formatPercent(score),
                formatScore(demoTraceProfileCompareThreshold),
                passed,
                response.centroidDimension());
    }

    private void logDemoFinalDecision(
            PendingRegistration pending,
            EmbedClient.BatchEmbedResponse embedResponse,
            DogNoseDecision decision,
            DogRegisterResponse response,
            String qdrantUpsert,
            String requestId
    ) {
        DogNoseCandidateScore topCandidate = decision.topCandidate();
        if (demoTraceEnabled) {
            log.info("{} flow=dog_register step=decision request_id={} dog_id={} decision={} registration_allowed={} max_similarity={} max_similarity_percent={} candidate_dog_id={} qdrant_upsert={} dog_status={} verification_result={} model={} dimension={}",
                    DEMO_TRACE_PREFIX,
                    safe(requestId),
                    safe(pending.dogId()),
                    safe(response.status()),
                    response.registrationAllowed(),
                    formatScore(decision.finalScore()),
                    formatPercent(decision.finalScore()),
                    topCandidate == null ? null : safe(topCandidate.dogId()),
                    qdrantUpsert,
                    safe(response.status()),
                    safe(response.verificationStatus()),
                    safe(embedResponse.model()),
                    embedResponse.dimension());
        }
        logDemoSummaryFinal(response.status(), qdrantUpsert, response.registrationAllowed(), requestId);
    }

    private void logDemoSummaryFaceCheck(EmbedClient.FaceNoseEmbeddingResponse response, String requestId) {
        if (!demoSummaryEnabled || response == null) {
            return;
        }
        EmbedClient.FaceCheckQualityResponse quality = response.quality();
        boolean qualityPassed = quality == null || quality.passed();
        boolean passed = response.extracted() && qualityPassed;
        if (passed) {
            logDemoSummary(
                    "[1] face-check",
                    "PASS",
                    List.of(
                            "confidence=" + summaryPercent(response.confidence()),
                            "crop=" + summaryCrop(response.cropWidth(), response.cropHeight())
                    ),
                    requestId
            );
            return;
        }

        String reason = quality != null && quality.failureReason() != null
                ? quality.failureReason()
                : response.failureReason();
        logDemoSummary(
                "[1] face-check",
                "FAIL",
                List.of("reason=" + summaryText(reason)),
                requestId
        );
    }

    private void logDemoSummaryProfileCentroid(boolean passed, double score, String requestId) {
        logDemoSummary(
                "[2] face-vs-centroid",
                passed ? "PASS" : "FAIL",
                List.of(
                        "similarity=" + summaryPercent(score),
                        "threshold=" + summaryPercent(profileCentroidGateThreshold)
                ),
                requestId
        );
    }

    private void logDemoSummaryNoseReference(
            ReferenceQualityReport qualityReport,
            List<List<Double>> referenceVectors,
            List<Double> centroidVector,
            String requestId
    ) {
        if (!demoSummaryEnabled || qualityReport == null) {
            return;
        }
        List<Double> centroidSimilarities = new ArrayList<>();
        if (referenceVectors != null && centroidVector != null) {
            for (List<Double> referenceVector : referenceVectors) {
                centroidSimilarities.add(NoseVectorMath.dot(referenceVector, centroidVector));
            }
        }
        DemoScoreStats stats = demoScoreStats(centroidSimilarities, qualityReport.threshold());
        String status = switch (qualityReport.verdict()) {
            case ACCEPTED -> "PASS";
            case WARN_ACCEPTED -> "WARN";
            case RETAKE_ONE, RETAKE_ALL -> "FAIL";
        };
        int total = referenceVectors == null ? 0 : referenceVectors.size();
        logDemoSummary(
                "[3] nose-reference",
                status,
                List.of(
                        "median=" + summaryPercent(stats.median()),
                        "min=" + summaryPercent(stats.min()),
                        "pass=" + stats.passCount() + "/" + total
                ),
                requestId
        );
    }

    private void logDemoSummaryQdrant(Double topScore, double duplicateThreshold, String requestId) {
        if (topScore == null) {
            logDemoSummary(
                    "[4] qdrant-duplicate",
                    "PASS",
                    List.of("top_match=none"),
                    requestId
            );
            return;
        }
        boolean duplicate = topScore >= duplicateThreshold;
        logDemoSummary(
                "[4] qdrant-duplicate",
                duplicate ? "DUPLICATE" : "PASS",
                List.of(
                        "top_similarity=" + summaryPercent(topScore),
                        "threshold=" + summaryPercent(duplicateThreshold)
                ),
                requestId
        );
    }

    private void logDemoSummaryFinal(
            String status,
            String qdrantUpsert,
            boolean registrationAllowed,
            String requestId
    ) {
        List<String> details = new ArrayList<>();
        details.add("qdrant_upsert=" + summaryText(qdrantUpsert));
        if (!registrationAllowed) {
            details.add("registration_allowed=false");
        }
        logDemoSummary("[5] final", summaryText(status), details, requestId);
    }

    private void logDemoSummaryFinalRejected(String reason, String requestId) {
        logDemoSummary(
                "[5] final",
                "REJECTED",
                List.of(
                        "reason=" + summaryText(reason),
                        "qdrant=skipped",
                        "db_write=skipped"
                ),
                requestId
        );
    }

    private void logDemoSummary(
            String stage,
            String status,
            List<String> details,
            String requestId
    ) {
        if (!demoSummaryEnabled) {
            return;
        }
        StringBuilder builder = new StringBuilder();
        builder.append(DEMO_SUMMARY_PREFIX)
                .append(' ')
                .append("%-22s".formatted(stage))
                .append(' ')
                .append(summaryText(status));
        if (details != null) {
            for (String detail : details) {
                if (detail != null && !detail.isBlank()) {
                    builder.append(" | ").append(safe(detail));
                }
            }
        }
        if (demoSummaryIncludeRequestId && requestId != null && !requestId.isBlank()) {
            builder.append(" | request_id=").append(safe(requestId));
        }
        log.info(builder.toString());
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

    private DemoScoreStats demoScoreStats(List<Double> values, double threshold) {
        List<Double> presentValues = values == null
                ? List.of()
                : values.stream()
                .filter(value -> value != null && Double.isFinite(value))
                .toList();
        if (presentValues.isEmpty()) {
            return new DemoScoreStats(null, null, null, null, 0, 0);
        }
        Double min = presentValues.stream().min(Comparator.naturalOrder()).orElse(null);
        Double max = presentValues.stream().max(Comparator.naturalOrder()).orElse(null);
        Double mean = presentValues.stream().mapToDouble(Double::doubleValue).average().orElse(0.0);
        Double median = median(presentValues);
        int passCount = (int) presentValues.stream().filter(value -> value >= threshold).count();
        return new DemoScoreStats(min, max, mean, median, passCount, presentValues.size() - passCount);
    }

    private static boolean referenceQualityPassed(ReferenceQualityReport report) {
        return report.verdict() == ReferenceQualityVerdict.ACCEPTED
                || report.verdict() == ReferenceQualityVerdict.WARN_ACCEPTED;
    }

    private static Double vectorNorm(List<Double> vector) {
        if (vector == null || vector.isEmpty()) {
            return null;
        }
        double sum = 0.0;
        for (Double value : vector) {
            if (value == null || !Double.isFinite(value)) {
                return null;
            }
            sum += value * value;
        }
        return Math.sqrt(sum);
    }

    private static boolean vectorFinite(List<Double> vector) {
        return vector != null
                && !vector.isEmpty()
                && vector.stream().allMatch(value -> value != null && Double.isFinite(value));
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

    private static boolean hasPresentFile(MultipartFile file) {
        return file != null && !file.isEmpty();
    }

    private String requestIdForTrace(String requestId) {
        if (requestId != null && !requestId.isBlank()) {
            return requestId.trim();
        }
        return demoTraceEnabled || demoSummaryEnabled ? UUID.randomUUID().toString() : null;
    }

    private String filenameOrDefault(String filename, int referenceIndex) {
        return filename == null || filename.isBlank() ? "nose_image_%d.jpg".formatted(referenceIndex) : filename;
    }

    private static String contentTypeOrDefault(MultipartFile file) {
        String contentType = file.getContentType();
        return contentType == null || contentType.isBlank() ? "image/png" : contentType;
    }

    private static long elapsedMillis(long startedNanos) {
        return Math.round((System.nanoTime() - startedNanos) / 1_000_000.0);
    }

    private static String safe(String value) {
        if (value == null) {
            return null;
        }
        String sanitized = value
                .replace('\n', '_')
                .replace('\r', '_')
                .replace('\t', '_')
                .trim();
        if (sanitized.length() > 120) {
            return sanitized.substring(0, 120);
        }
        return sanitized;
    }

    private static String formatScore(double score) {
        return "%.4f".formatted(score);
    }

    private static String formatNullableScore(Double score) {
        return score == null ? "null" : formatScore(score);
    }

    private static String formatPercent(double score) {
        return "%.1f".formatted(score * 100.0);
    }

    private static String formatNullablePercent(Double score) {
        return score == null ? "null" : formatPercent(score);
    }

    private static String summaryText(String value) {
        String safeValue = safe(value);
        return safeValue == null || safeValue.isBlank() ? "none" : safeValue;
    }

    private static String summaryPercent(double score) {
        return formatPercent(score) + "%";
    }

    private static String summaryPercent(Double score) {
        return score == null ? "none" : summaryPercent(score.doubleValue());
    }

    private static String summaryCrop(Integer width, Integer height) {
        if (width == null || height == null) {
            return "none";
        }
        return "%dx%d".formatted(width, height);
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

    private record StoredRegistrationImages(
            FileStorageService.StoredFile profileImage,
            List<FileStorageService.StoredFile> noseImages
    ) {
    }

    private record PendingRegistration(
            String dogId,
            FileStorageService.StoredFile profileImage,
            List<StoredNoseImage> noseImages,
            Long verificationLogId
    ) {

        private StoredNoseImage representativeNoseImage() {
            return noseImages.get(0);
        }
    }

    private record ProfileNoseMatchResult(Double score) {
        static ProfileNoseMatchResult empty() {
            return new ProfileNoseMatchResult(null);
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

    private record DemoProfileCompareStats(
            int total,
            int passCount,
            Double minScore,
            Double maxScore,
            Double meanScore,
            Double medianScore,
            List<ProfileMatchScoreResponse> scores,
            boolean passed
    ) {
    }

    private record DemoScoreStats(
            Double min,
            Double max,
            Double mean,
            Double median,
            int passCount,
            int failCount
    ) {
    }
}
