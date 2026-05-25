package com.petnose.api.service;

import com.petnose.api.domain.entity.AdoptionPost;
import com.petnose.api.domain.entity.Dog;
import com.petnose.api.domain.enums.AdoptionPostStatus;
import com.petnose.api.domain.enums.DogImageType;
import com.petnose.api.domain.enums.DogStatus;
import com.petnose.api.domain.enums.VerificationResult;
import com.petnose.api.dto.dog.DogListItemResponse;
import com.petnose.api.dto.dog.DogListResponse;
import com.petnose.api.dto.dog.DogOwnerDetailResponse;
import com.petnose.api.dto.dog.DogPublicDetailResponse;
import com.petnose.api.exception.ApiException;
import com.petnose.api.repository.AdoptionPostRepository;
import com.petnose.api.repository.DogImageRepository;
import com.petnose.api.repository.DogRepository;
import com.petnose.api.repository.VerificationLogRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.util.Collection;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;

@Service
@RequiredArgsConstructor
public class DogQueryService {

    private static final int MAX_PAGE_SIZE = 100;

    private static final List<AdoptionPostStatus> ACTIVE_POST_STATUSES = List.of(
            AdoptionPostStatus.DRAFT,
            AdoptionPostStatus.OPEN,
            AdoptionPostStatus.RESERVED
    );

    private static final List<AdoptionPostStatus> PUBLIC_DETAIL_POST_STATUSES = List.of(
            AdoptionPostStatus.OPEN,
            AdoptionPostStatus.RESERVED
    );

    private final DogRepository dogRepository;
    private final VerificationLogRepository verificationLogRepository;
    private final DogImageRepository dogImageRepository;
    private final AdoptionPostRepository adoptionPostRepository;

    @Transactional(readOnly = true)
    public DogListResponse findMyDogs(Long currentUserId, int page, int size) {
        validatePageRequest(page, size);

        Page<Dog> dogs = dogRepository.findByOwnerUserIdOrderByCreatedAtDescIdDesc(
                currentUserId,
                PageRequest.of(page, size)
        );
        DogQueryContext context = loadContext(dogs.getContent());
        List<DogListItemResponse> items = dogs.getContent().stream()
                .map(dog -> toListItemResponse(dog, context))
                .toList();

        return new DogListResponse(items, page, size, dogs.getTotalElements());
    }

    @Transactional(readOnly = true)
    public Object findDogDetail(String dogId, Long currentUserId) {
        Dog dog = dogRepository.findById(dogId)
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "DOG_NOT_FOUND", "강아지를 찾을 수 없습니다."));
        DogQueryContext context = loadContext(List.of(dog));

        if (currentUserId != null && currentUserId.equals(dog.getOwnerUserId())) {
            return toOwnerDetailResponse(dog, context);
        }

        if (!adoptionPostRepository.existsByDogIdAndStatusIn(dog.getId(), PUBLIC_DETAIL_POST_STATUSES)) {
            throw new ApiException(HttpStatus.FORBIDDEN, "DOG_NOT_ACCESSIBLE", "공개 조회할 수 없는 강아지입니다.");
        }
        return toPublicDetailResponse(dog, context);
    }

    private void validatePageRequest(int page, int size) {
        if (page < 0 || size <= 0 || size > MAX_PAGE_SIZE) {
            throw new ApiException(
                    HttpStatus.BAD_REQUEST,
                    "INVALID_PAGE_REQUEST",
                    "page must be greater than or equal to 0 and size must be between 1 and 100"
            );
        }
    }

    private DogQueryContext loadContext(List<Dog> dogs) {
        Set<String> dogIds = dogs.stream()
                .map(Dog::getId)
                .collect(Collectors.toCollection(LinkedHashSet::new));

        return new DogQueryContext(
                loadLatestVerificationResultsByDogId(dogIds),
                loadImageUrlsByDogId(dogIds, DogImageType.PROFILE),
                loadImageUrlsByDogId(dogIds, DogImageType.NOSE),
                loadActivePostsByDogId(dogIds)
        );
    }

    private Map<String, VerificationResult> loadLatestVerificationResultsByDogId(Set<String> dogIds) {
        Map<String, VerificationResult> resultsByDogId = new HashMap<>();
        if (dogIds.isEmpty()) {
            return resultsByDogId;
        }

        verificationLogRepository.findByDogIdInOrderByDogIdAscCreatedAtDescIdDesc(dogIds)
                .forEach(log -> resultsByDogId.putIfAbsent(log.getDogId(), log.getResult()));
        return resultsByDogId;
    }

    private Map<String, String> loadImageUrlsByDogId(Set<String> dogIds, DogImageType imageType) {
        Map<String, String> urlsByDogId = new HashMap<>();
        if (dogIds.isEmpty()) {
            return urlsByDogId;
        }

        dogImageRepository.findByDogIdInAndImageTypeOrderByDogIdAscUploadedAtDescIdDesc(dogIds, imageType)
                .forEach(image -> urlsByDogId.putIfAbsent(image.getDogId(), toFileUrl(image.getFilePath())));
        return urlsByDogId;
    }

    private Map<String, AdoptionPost> loadActivePostsByDogId(Collection<String> dogIds) {
        Map<String, AdoptionPost> postsByDogId = new HashMap<>();
        if (dogIds.isEmpty()) {
            return postsByDogId;
        }

        adoptionPostRepository.findByDogIdInAndStatusInOrderByDogIdAscCreatedAtDescIdDesc(dogIds, ACTIVE_POST_STATUSES)
                .forEach(post -> postsByDogId.putIfAbsent(post.getDogId(), post));
        return postsByDogId;
    }

    private DogListItemResponse toListItemResponse(Dog dog, DogQueryContext context) {
        VerificationProjection verification = verificationOf(dog, context);
        AdoptionPost activePost = context.activePostsByDogId().get(dog.getId());

        return new DogListItemResponse(
                dog.getId(),
                dog.getName(),
                dog.getBreed(),
                dog.getGender() == null ? null : dog.getGender().name(),
                dog.getBirthDate(),
                dog.getStatus().name(),
                verification.verificationStatus(),
                verification.embeddingStatus(),
                context.profileImageUrlsByDogId().get(dog.getId()),
                activePost != null,
                activePost == null ? null : activePost.getId(),
                canCreatePost(dog, verification.latestResult(), activePost),
                dog.getCreatedAt()
        );
    }

    private DogOwnerDetailResponse toOwnerDetailResponse(Dog dog, DogQueryContext context) {
        VerificationProjection verification = verificationOf(dog, context);
        AdoptionPost activePost = context.activePostsByDogId().get(dog.getId());

        return new DogOwnerDetailResponse(
                dog.getId(),
                dog.getName(),
                dog.getBreed(),
                dog.getGender() == null ? null : dog.getGender().name(),
                dog.getBirthDate(),
                dog.getDescription(),
                dog.getStatus().name(),
                verification.verificationStatus(),
                verification.embeddingStatus(),
                context.noseImageUrlsByDogId().get(dog.getId()),
                context.profileImageUrlsByDogId().get(dog.getId()),
                activePost != null,
                activePost == null ? null : activePost.getId(),
                canCreatePost(dog, verification.latestResult(), activePost),
                dog.getCreatedAt(),
                dog.getUpdatedAt()
        );
    }

    private DogPublicDetailResponse toPublicDetailResponse(Dog dog, DogQueryContext context) {
        VerificationProjection verification = verificationOf(dog, context);
        AdoptionPost activePost = context.activePostsByDogId().get(dog.getId());

        return new DogPublicDetailResponse(
                dog.getId(),
                dog.getName(),
                dog.getBreed(),
                dog.getGender() == null ? null : dog.getGender().name(),
                dog.getBirthDate(),
                dog.getDescription(),
                dog.getStatus().name(),
                verification.verificationStatus(),
                verification.embeddingStatus(),
                context.profileImageUrlsByDogId().get(dog.getId()),
                activePost != null,
                activePost == null ? null : activePost.getId(),
                false,
                dog.getCreatedAt(),
                dog.getUpdatedAt()
        );
    }

    private VerificationProjection verificationOf(Dog dog, DogQueryContext context) {
        return VerificationProjection.from(context.latestVerificationResultsByDogId().get(dog.getId()));
    }

    private boolean canCreatePost(Dog dog, VerificationResult latestResult, AdoptionPost activePost) {
        return dog.getStatus() == DogStatus.REGISTERED
                && latestResult == VerificationResult.PASSED
                && activePost == null;
    }

    private String toFileUrl(String filePath) {
        if (filePath == null || filePath.isBlank()) {
            return null;
        }

        String normalized = filePath.trim().replace('\\', '/');
        if (normalized.startsWith("/files/")) {
            return normalized;
        }
        if (normalized.startsWith("files/")) {
            return "/" + normalized;
        }
        if (normalized.startsWith("/")) {
            return "/files" + normalized;
        }
        return "/files/" + normalized;
    }

    private record DogQueryContext(
            Map<String, VerificationResult> latestVerificationResultsByDogId,
            Map<String, String> profileImageUrlsByDogId,
            Map<String, String> noseImageUrlsByDogId,
            Map<String, AdoptionPost> activePostsByDogId
    ) {
    }

    private record VerificationProjection(
            VerificationResult latestResult,
            String verificationStatus,
            String embeddingStatus
    ) {
        private static VerificationProjection from(VerificationResult result) {
            if (result == null) {
                return new VerificationProjection(null, "PENDING", "PENDING");
            }

            return switch (result) {
                case PASSED -> new VerificationProjection(result, "VERIFIED", "COMPLETED");
                case DUPLICATE_SUSPECTED ->
                        new VerificationProjection(result, "DUPLICATE_SUSPECTED", "SKIPPED_DUPLICATE");
                case REVIEW_REQUIRED -> new VerificationProjection(result, "REVIEW_REQUIRED", "SKIPPED_REVIEW");
                case PENDING -> new VerificationProjection(result, "PENDING", "PENDING");
                case EMBED_FAILED, QDRANT_SEARCH_FAILED -> new VerificationProjection(result, "FAILED", "FAILED");
                case QDRANT_UPSERT_FAILED -> new VerificationProjection(result, "FAILED", "QDRANT_SYNC_FAILED");
            };
        }
    }
}
