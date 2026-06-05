package com.petnose.api.service;

import com.petnose.api.client.EmbedClient;
import com.petnose.api.client.QdrantDogVectorClient;
import com.petnose.api.client.QdrantDogVectorClient.QdrantVectorSearchResult;
import com.petnose.api.config.HandoverVerificationProperties;
import com.petnose.api.domain.entity.AdoptionPost;
import com.petnose.api.domain.entity.Dog;
import com.petnose.api.domain.enums.AdoptionPostStatus;
import com.petnose.api.domain.enums.DogStatus;
import com.petnose.api.domain.enums.HandoverVerificationDecision;
import com.petnose.api.dto.adoption.HandoverScoreBreakdownResponse;
import com.petnose.api.dto.adoption.HandoverVerificationResponse;
import com.petnose.api.exception.ApiException;
import com.petnose.api.repository.AdoptionPostRepository;
import com.petnose.api.repository.DogRepository;
import com.petnose.api.service.nose.DogNoseCandidateAggregator;
import com.petnose.api.service.nose.DogNoseCandidateAggregator.DogNoseAggregationResult;
import com.petnose.api.service.nose.DogNoseCandidateAggregator.DogNoseCandidateScore;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.stereotype.Service;
import org.springframework.web.multipart.MultipartFile;

import java.io.IOException;
import java.util.ArrayList;
import java.util.List;

@Slf4j
@Service
@RequiredArgsConstructor
public class HandoverVerificationService {

    private final AdoptionPostRepository adoptionPostRepository;
    private final DogRepository dogRepository;
    private final EmbedClient embedClient;
    private final QdrantDogVectorClient qdrantDogVectorClient;
    private final HandoverVerificationProperties properties;
    private final DogNoseCandidateAggregator dogNoseCandidateAggregator = new DogNoseCandidateAggregator();

    @Value("${qdrant.vector-dimension}")
    private int expectedVectorDimension;

    public HandoverVerificationResponse verify(Long postId, MultipartFile noseImage) {
        AdoptionPost post = adoptionPostRepository.findById(postId)
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "POST_NOT_FOUND", "Adoption post was not found."));
        validatePostIsVerifiable(post);

        Dog expectedDog = dogRepository.findById(post.getDogId())
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "DOG_NOT_FOUND", "강아지를 찾을 수 없습니다."));
        validateExpectedDog(expectedDog);

        validateNoseImage(noseImage);
        EmbedClient.EmbedResponse embedResponse = requestEmbeddingOrFail(postId, noseImage);
        validateEmbeddingDimensionOrFail(embedResponse);

        HandoverQdrantSearchResults searchResults = searchExpectedDogReferenceSetFromQdrantOrFail(
                postId,
                embedResponse,
                expectedDog.getId()
        );
        return evaluate(post.getId(), expectedDog.getId(), embedResponse, searchResults);
    }

    private void validatePostIsVerifiable(AdoptionPost post) {
        if (post.getStatus() != AdoptionPostStatus.OPEN && post.getStatus() != AdoptionPostStatus.RESERVED) {
            throw new ApiException(
                    HttpStatus.BAD_REQUEST,
                    "POST_NOT_VERIFIABLE",
                    "인계 비문 확인은 OPEN 또는 RESERVED 상태의 분양글에서만 가능합니다."
            );
        }
    }

    private void validateExpectedDog(Dog dog) {
        if (dog.getStatus() != DogStatus.REGISTERED) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "DOG_NOT_VERIFIED", "비문 인증을 통과한 강아지만 확인할 수 있습니다.");
        }
    }

    private void validateNoseImage(MultipartFile noseImage) {
        if (noseImage == null || noseImage.isEmpty()) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "NOSE_IMAGE_REQUIRED", "nose_image는 필수입니다.");
        }
    }

    private EmbedClient.EmbedResponse requestEmbeddingOrFail(Long postId, MultipartFile noseImage) {
        try {
            return embedClient.embed(
                    noseImage.getBytes(),
                    originalFilenameOrDefault(noseImage),
                    contentTypeOrDefault(noseImage)
            );
        } catch (IOException e) {
            throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "INVALID_NOSE_IMAGE", "비문 이미지 처리에 실패했습니다.");
        } catch (EmbedClient.EmbedClientException e) {
            log.warn("[HandoverVerification] embed 실패: postId={}, upstreamStatus={}, message={}",
                    postId, e.getUpstreamStatus(), e.getMessage());
            if (e.getUpstreamStatus() != null && e.getUpstreamStatus() == 400) {
                throw new ApiException(HttpStatus.UNPROCESSABLE_ENTITY, "INVALID_NOSE_IMAGE", "비문 이미지 처리에 실패했습니다.");
            }
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "EMBED_SERVICE_UNAVAILABLE", "임베딩 서비스를 사용할 수 없습니다.");
        }
    }

    private void validateEmbeddingDimensionOrFail(EmbedClient.EmbedResponse embedResponse) {
        if (embedResponse.vector() == null || embedResponse.vector().isEmpty()) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "EMPTY_EMBEDDING", "임베딩 결과가 비어 있습니다.");
        }
        if (embedResponse.dimension() != expectedVectorDimension) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "EMBEDDING_DIMENSION_MISMATCH", "임베딩 차원이 시스템 설정과 일치하지 않습니다.");
        }
    }

    private HandoverQdrantSearchResults searchExpectedDogReferenceSetFromQdrantOrFail(
            Long postId,
            EmbedClient.EmbedResponse embedResponse,
            String expectedDogId
    ) {
        try {
            List<QdrantVectorSearchResult> referenceResults = qdrantDogVectorClient.searchExpectedDogReferences(
                    embedResponse.vector(),
                    expectedDogId,
                    properties.effectiveTopK()
            );
            List<QdrantVectorSearchResult> centroidResults = qdrantDogVectorClient.searchExpectedDogCentroid(
                    embedResponse.vector(),
                    expectedDogId
            );
            return new HandoverQdrantSearchResults(referenceResults, centroidResults);
        } catch (QdrantDogVectorClient.QdrantClientException e) {
            log.warn("[HandoverVerification] qdrant search 실패: postId={}, status={}, message={}",
                    postId, e.getUpstreamStatus(), e.getMessage());
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "QDRANT_SEARCH_FAILED", "인계 비문 확인 검색에 실패했습니다.");
        }
    }

    private HandoverVerificationResponse evaluate(
            Long postId,
            String expectedDogId,
            EmbedClient.EmbedResponse embedResponse,
            HandoverQdrantSearchResults searchResults
    ) {
        validateThresholdsOrFail();

        List<QdrantVectorSearchResult> referenceResults = filterExpectedDogResults(
                postId,
                expectedDogId,
                searchResults.referenceResults(),
                "REFERENCE"
        );
        List<QdrantVectorSearchResult> centroidResults = filterExpectedDogResults(
                postId,
                expectedDogId,
                searchResults.centroidResults(),
                "CENTROID"
        );
        DogNoseAggregationResult aggregationResult = dogNoseCandidateAggregator.aggregate(
                referenceResults,
                centroidResults,
                properties.getAmbiguousThreshold()
        );
        DogNoseCandidateScore candidate = aggregationResult.topCandidate();

        if (candidate == null) {
            return response(
                    postId,
                    expectedDogId,
                    HandoverVerificationDecision.NO_MATCH_CANDIDATE,
                    null,
                    false,
                    embedResponse,
                    noCandidateScoreBreakdown(centroidResults)
            );
        }

        boolean topMatchIsExpected = expectedDogId.equals(candidate.dogId());
        if (!topMatchIsExpected) {
            log.warn(
                    "[HandoverVerification] expected-dog reference aggregation returned a different dog: postId={}, expectedDogId={}",
                    postId,
                    expectedDogId
            );
            return response(
                    postId,
                    expectedDogId,
                    HandoverVerificationDecision.NOT_MATCHED,
                    null,
                    false,
                    embedResponse,
                    noCandidateScoreBreakdown(centroidResults)
            );
        }

        HandoverVerificationDecision decision = decide(candidate.finalScore());
        return response(
                postId,
                expectedDogId,
                decision,
                candidate.finalScore(),
                true,
                embedResponse,
                scoreBreakdown(candidate)
        );
    }

    private HandoverVerificationResponse response(
            Long postId,
            String expectedDogId,
            HandoverVerificationDecision decision,
            Double similarityScore,
            boolean topMatchIsExpected,
            EmbedClient.EmbedResponse embedResponse,
            HandoverScoreBreakdownResponse scoreBreakdown
    ) {
        return new HandoverVerificationResponse(
                postId,
                expectedDogId,
                decision == HandoverVerificationDecision.MATCHED,
                decision,
                similarityScore,
                properties.getMatchThreshold(),
                properties.getAmbiguousThreshold(),
                topMatchIsExpected,
                embedResponse.model(),
                embedResponse.dimension(),
                message(decision),
                scoreBreakdown
        );
    }

    private HandoverVerificationDecision decide(double finalScore) {
        if (finalScore >= properties.getMatchThreshold()) {
            return HandoverVerificationDecision.MATCHED;
        }
        if (finalScore >= properties.getAmbiguousThreshold()) {
            return HandoverVerificationDecision.AMBIGUOUS;
        }
        return HandoverVerificationDecision.NOT_MATCHED;
    }

    private List<QdrantVectorSearchResult> filterExpectedDogResults(
            Long postId,
            String expectedDogId,
            List<QdrantVectorSearchResult> results,
            String embeddingKind
    ) {
        if (results == null || results.isEmpty()) {
            return List.of();
        }

        List<QdrantVectorSearchResult> expectedResults = new ArrayList<>();
        int skippedCount = 0;
        for (QdrantVectorSearchResult result : results) {
            if (result == null) {
                continue;
            }
            if (expectedDogId.equals(result.dogId())) {
                expectedResults.add(result);
            } else {
                skippedCount++;
            }
        }

        if (skippedCount > 0) {
            log.warn(
                    "[HandoverVerification] expected-dog {} search returned non-expected results: postId={}, expectedDogId={}, skippedCount={}",
                    embeddingKind,
                    postId,
                    expectedDogId,
                    skippedCount
            );
        }
        return expectedResults;
    }

    private HandoverScoreBreakdownResponse scoreBreakdown(DogNoseCandidateScore candidate) {
        return new HandoverScoreBreakdownResponse(
                candidate.finalScore(),
                candidate.maxReferenceScore(),
                candidate.top2AverageScore(),
                candidate.centroidScore(),
                candidate.hitCount()
        );
    }

    private HandoverScoreBreakdownResponse noCandidateScoreBreakdown(List<QdrantVectorSearchResult> centroidResults) {
        return new HandoverScoreBreakdownResponse(
                null,
                null,
                null,
                maxCentroidScore(centroidResults),
                0
        );
    }

    private Double maxCentroidScore(List<QdrantVectorSearchResult> centroidResults) {
        if (centroidResults == null || centroidResults.isEmpty()) {
            return null;
        }

        Double maxScore = null;
        for (QdrantVectorSearchResult result : centroidResults) {
            if (result == null) {
                continue;
            }
            if (maxScore == null || result.score() > maxScore) {
                maxScore = result.score();
            }
        }
        return maxScore;
    }

    private void validateThresholdsOrFail() {
        double matchThreshold = properties.getMatchThreshold();
        double ambiguousThreshold = properties.getAmbiguousThreshold();
        if (!Double.isFinite(matchThreshold) || !Double.isFinite(ambiguousThreshold)
                || ambiguousThreshold > matchThreshold
                || ambiguousThreshold < 0.0
                || matchThreshold > 1.0) {
            throw new ApiException(
                    HttpStatus.INTERNAL_SERVER_ERROR,
                    "INVALID_HANDOVER_VERIFICATION_THRESHOLD",
                    "인계 비문 확인 기준값 설정이 올바르지 않습니다."
            );
        }
    }

    private String message(HandoverVerificationDecision decision) {
        return switch (decision) {
            case MATCHED -> "분양글에 등록된 강아지와 일치합니다.";
            case AMBIGUOUS -> "유사도가 기준에 근접하지만 확정하기 어렵습니다. 비문 이미지를 다시 촬영해주세요.";
            case NOT_MATCHED -> "분양글에 등록된 강아지와 일치하지 않습니다. 거래 전 확인이 필요합니다.";
            case NO_MATCH_CANDIDATE -> "일치 후보를 찾지 못했습니다. 비문 이미지를 다시 촬영해주세요.";
        };
    }

    private String originalFilenameOrDefault(MultipartFile noseImage) {
        String filename = noseImage.getOriginalFilename();
        return filename == null || filename.isBlank() ? "handover_nose_image" : filename;
    }

    private String contentTypeOrDefault(MultipartFile noseImage) {
        String contentType = noseImage.getContentType();
        return contentType == null || contentType.isBlank() ? MediaType.APPLICATION_OCTET_STREAM_VALUE : contentType;
    }

    private record HandoverQdrantSearchResults(
            List<QdrantVectorSearchResult> referenceResults,
            List<QdrantVectorSearchResult> centroidResults
    ) {
    }
}
