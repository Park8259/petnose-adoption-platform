package com.petnose.api.service;

import com.petnose.api.domain.entity.AdoptionPost;
import com.petnose.api.domain.entity.Dog;
import com.petnose.api.domain.entity.DogImage;
import com.petnose.api.domain.entity.User;
import com.petnose.api.domain.entity.VerificationLog;
import com.petnose.api.domain.enums.AdoptionPostStatus;
import com.petnose.api.domain.enums.DogImageType;
import com.petnose.api.domain.enums.DogStatus;
import com.petnose.api.domain.enums.VerificationResult;
import com.petnose.api.dto.adoption.AdoptionPostCreateRequest;
import com.petnose.api.dto.adoption.AdoptionPostCreateResponse;
import com.petnose.api.dto.adoption.AdoptionPostDetailResponse;
import com.petnose.api.dto.adoption.AdoptionPostListItemResponse;
import com.petnose.api.dto.adoption.AdoptionPostListResponse;
import com.petnose.api.dto.adoption.AdoptionPostOwnerListItemResponse;
import com.petnose.api.dto.adoption.AdoptionPostOwnerListResponse;
import com.petnose.api.dto.adoption.AdoptionPostStatusUpdateRequest;
import com.petnose.api.dto.adoption.AdoptionPostStatusUpdateResponse;
import com.petnose.api.exception.ApiException;
import com.petnose.api.repository.AdoptionPostRepository;
import com.petnose.api.repository.DogImageRepository;
import com.petnose.api.repository.DogRepository;
import com.petnose.api.repository.UserRepository;
import com.petnose.api.repository.VerificationLogRepository;
import com.petnose.api.service.chat.ChatRoomPostStatusSyncService;
import lombok.RequiredArgsConstructor;
import org.springframework.data.domain.Page;
import org.springframework.data.domain.PageRequest;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;
import org.springframework.web.multipart.MultipartFile;

import java.time.LocalDateTime;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.function.Function;
import java.util.stream.Collectors;

@Service
@RequiredArgsConstructor
public class AdoptionPostService {

    private static final int DEFAULT_PUBLIC_PAGE = 0;
    private static final int DEFAULT_PUBLIC_PAGE_SIZE = 20;
    private static final int MAX_PUBLIC_PAGE_SIZE = 100;

    private static final List<AdoptionPostStatus> ACTIVE_STATUSES = List.of(
            AdoptionPostStatus.DRAFT,
            AdoptionPostStatus.OPEN,
            AdoptionPostStatus.RESERVED
    );

    private final UserRepository userRepository;
    private final DogRepository dogRepository;
    private final VerificationLogRepository verificationLogRepository;
    private final DogImageRepository dogImageRepository;
    private final AdoptionPostRepository adoptionPostRepository;
    private final FileStorageService fileStorageService;
    private final ChatRoomPostStatusSyncService chatRoomPostStatusSyncService;

    @Transactional(readOnly = true)
    public AdoptionPostListResponse findPublicPosts(String statusParam, String pageParam, String sizeParam) {
        int page = parsePageParameter(pageParam, DEFAULT_PUBLIC_PAGE);
        int size = parsePageParameter(sizeParam, DEFAULT_PUBLIC_PAGE_SIZE);
        return findPublicPosts(statusParam, page, size);
    }

    @Transactional(readOnly = true)
    public AdoptionPostListResponse findPublicPosts(String statusParam, int page, int size) {
        validatePageRequest(page, size);
        AdoptionPostStatus status = AdoptionPostStatus.fromPublicQuery(statusParam);

        Page<AdoptionPost> posts = adoptionPostRepository.findPublicPageByStatus(
                status,
                PageRequest.of(page, size)
        );
        PublicPostContext context = loadPublicPostContext(posts.getContent());
        List<AdoptionPostListItemResponse> items = posts.getContent().stream()
                .map(post -> toListItemResponse(post, context))
                .toList();

        return new AdoptionPostListResponse(items, page, size, posts.getTotalElements());
    }

    @Transactional(readOnly = true)
    public AdoptionPostOwnerListResponse findOwnerPosts(
            Long currentUserId,
            String statusParam,
            String pageParam,
            String sizeParam
    ) {
        int page = parsePageParameter(pageParam, DEFAULT_PUBLIC_PAGE);
        int size = parsePageParameter(sizeParam, DEFAULT_PUBLIC_PAGE_SIZE);
        return findOwnerPosts(currentUserId, statusParam, page, size);
    }

    @Transactional(readOnly = true)
    public AdoptionPostOwnerListResponse findOwnerPosts(
            Long currentUserId,
            String statusParam,
            int page,
            int size
    ) {
        validatePageRequest(page, size);
        AdoptionPostStatus status = AdoptionPostStatus.fromOwnerQuery(statusParam);
        PageRequest pageRequest = PageRequest.of(page, size);
        Page<AdoptionPost> posts = status == null
                ? adoptionPostRepository.findByAuthorUserIdOrderByCreatedAtDescIdDesc(currentUserId, pageRequest)
                : adoptionPostRepository.findByAuthorUserIdAndStatusOrderByCreatedAtDescIdDesc(currentUserId, status, pageRequest);

        OwnerPostContext context = loadOwnerPostContext(posts.getContent());
        List<AdoptionPostOwnerListItemResponse> items = posts.getContent().stream()
                .map(post -> toOwnerListItemResponse(post, context))
                .toList();

        return new AdoptionPostOwnerListResponse(items, page, size, posts.getTotalElements());
    }

    @Transactional(readOnly = true)
    public AdoptionPostDetailResponse findPublicPost(Long postId) {
        AdoptionPost post = adoptionPostRepository.findById(postId)
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "POST_NOT_FOUND", "Adoption post was not found."));
        if (!post.getStatus().isPublicVisible()) {
            throw new ApiException(HttpStatus.NOT_FOUND, "POST_NOT_PUBLIC", "Adoption post is not public.");
        }

        PublicPostContext context = loadPublicPostContext(List.of(post));
        return toDetailResponse(post, context);
    }

    @Transactional
    public AdoptionPostCreateResponse create(Long currentUserId, AdoptionPostCreateRequest request) {
        validateRequest(request);
        AdoptionPostStatus requestedStatus = AdoptionPostStatus.fromCreateRequest(request.status());

        User currentUser = userRepository.findById(currentUserId)
                .orElseThrow(() -> new ApiException(HttpStatus.UNAUTHORIZED, "UNAUTHORIZED", "인증이 필요합니다."));
        validateUser(currentUser);

        Dog dog = dogRepository.findById(request.dogId().trim())
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "DOG_NOT_FOUND", "강아지를 찾을 수 없습니다."));
        validateDogOwner(currentUser, dog);
        validateDogStatus(dog);
        validateLatestVerificationLog(dog.getId());
        validateNoActivePost(dog.getId());
        saveRequiredProfileImage(dog.getId(), request.profileImage());

        AdoptionPost post = new AdoptionPost();
        post.setAuthorUserId(currentUser.getId());
        post.setDogId(dog.getId());
        post.setTitle(request.title().trim());
        post.setContent(request.content().trim());
        post.setStatus(requestedStatus);
        if (requestedStatus == AdoptionPostStatus.OPEN) {
            post.setPublishedAt(LocalDateTime.now());
        }
        post.setClosedAt(null);

        AdoptionPost saved = adoptionPostRepository.save(post);

        return new AdoptionPostCreateResponse(
                saved.getId(),
                saved.getDogId(),
                saved.getTitle(),
                saved.getContent(),
                saved.getStatus().name(),
                saved.getPublishedAt(),
                saved.getCreatedAt()
        );
    }

    @Transactional
    public AdoptionPostStatusUpdateResponse updateStatus(
            Long currentUserId,
            Long postId,
            AdoptionPostStatusUpdateRequest request
    ) {
        AdoptionPost post = adoptionPostRepository.findById(postId)
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "POST_NOT_FOUND", "Adoption post was not found."));

        if (!post.getAuthorUserId().equals(currentUserId)) {
            throw new ApiException(HttpStatus.FORBIDDEN, "POST_OWNER_MISMATCH", "현재 사용자의 게시글이 아닙니다.");
        }

        AdoptionPostStatus targetStatus = parseStatusUpdateRequest(request);
        AdoptionPostStatus currentStatus = post.getStatus();
        if (currentStatus == targetStatus) {
            return toStatusUpdateResponse(post);
        }
        validateStatusTransition(currentStatus, targetStatus);

        LocalDateTime now = LocalDateTime.now();
        applyStatusTransition(currentUserId, post, currentStatus, targetStatus, now);
        adoptionPostRepository.flush();
        scheduleChatRoomStatusSync(post.getId(), post.getStatus());
        return toStatusUpdateResponse(post);
    }

    private void validateRequest(AdoptionPostCreateRequest request) {
        if (request == null) {
            throw validationFailed("request는 필수입니다.");
        }
        if (request.dogId() == null || request.dogId().isBlank()) {
            throw validationFailed("dog_id는 필수입니다.");
        }
        if (request.title() == null || request.title().isBlank()) {
            throw validationFailed("title은 필수입니다.");
        }
        if (request.title().trim().length() > 200) {
            throw validationFailed("title은 최대 200자까지 입력할 수 있습니다.");
        }
        if (request.content() == null || request.content().isBlank()) {
            throw validationFailed("content는 필수입니다.");
        }
        if (request.profileImage() == null || request.profileImage().isEmpty()) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "PROFILE_IMAGE_REQUIRED", "profile_image는 필수입니다.");
        }
    }

    private ApiException validationFailed(String message) {
        return new ApiException(HttpStatus.BAD_REQUEST, "VALIDATION_FAILED", message);
    }

    private void validateUser(User currentUser) {
        if (!currentUser.isActive()) {
            throw new ApiException(HttpStatus.FORBIDDEN, "USER_INACTIVE", "비활성 사용자입니다.");
        }
        if (currentUser.getDisplayName() == null || currentUser.getDisplayName().isBlank()) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "USER_PROFILE_REQUIRED", "작성자 표시 이름이 필요합니다.");
        }
    }

    private void validateDogOwner(User currentUser, Dog dog) {
        if (!currentUser.getId().equals(dog.getOwnerUserId())) {
            throw new ApiException(HttpStatus.FORBIDDEN, "DOG_OWNER_MISMATCH", "현재 사용자의 강아지가 아닙니다.");
        }
    }

    private void validateDogStatus(Dog dog) {
        if (dog.getStatus() != DogStatus.REGISTERED) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "DOG_NOT_REGISTERED", "등록 완료된 강아지만 분양 게시글을 생성할 수 있습니다.");
        }
    }

    private void validateLatestVerificationLog(String dogId) {
        VerificationLog latest = verificationLogRepository.findFirstByDogIdOrderByCreatedAtDescIdDesc(dogId)
                .orElseThrow(() -> new ApiException(HttpStatus.BAD_REQUEST, "DOG_NOT_VERIFIED", "비문 인증 이력이 없습니다."));

        if (latest.getResult() == VerificationResult.DUPLICATE_SUSPECTED) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "DOG_NOT_VERIFIED", "최신 비문 인증 결과가 중복 의심입니다.");
        }
        if (latest.getResult() != VerificationResult.PASSED) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "DOG_NOT_VERIFIED", "최신 비문 인증 결과가 통과 상태가 아닙니다.");
        }
    }

    private void validateNoActivePost(String dogId) {
        if (adoptionPostRepository.existsByDogIdAndStatusIn(dogId, ACTIVE_STATUSES)) {
            throw new ApiException(HttpStatus.CONFLICT, "DOG_ALREADY_HAS_ACTIVE_POST", "이미 활성 분양 게시글이 있습니다.");
        }
    }

    private void validateNoOtherActivePost(String dogId, Long currentPostId) {
        if (adoptionPostRepository.existsByDogIdAndStatusInAndIdNot(dogId, ACTIVE_STATUSES, currentPostId)) {
            throw new ApiException(HttpStatus.CONFLICT, "DOG_ALREADY_HAS_ACTIVE_POST", "이미 활성 분양 게시글이 있습니다.");
        }
    }

    private void saveRequiredProfileImage(String dogId, MultipartFile profileImage) {
        FileStorageService.StoredFile stored = fileStorageService.storeProfileImage(dogId, profileImage);
        DogImage image = new DogImage();
        image.setDogId(dogId);
        image.setImageType(DogImageType.PROFILE);
        image.setFilePath(stored.relativePath());
        image.setMimeType(stored.mimeType());
        image.setFileSize(stored.fileSize());
        image.setSha256(stored.sha256());
        dogImageRepository.save(image);
    }

    private AdoptionPostStatus parseStatusUpdateRequest(AdoptionPostStatusUpdateRequest request) {
        return AdoptionPostStatus.fromStatusUpdateRequest(request == null ? null : request.status());
    }

    private void validateStatusTransition(AdoptionPostStatus currentStatus, AdoptionPostStatus targetStatus) {
        boolean allowed = switch (currentStatus) {
            case DRAFT -> targetStatus == AdoptionPostStatus.OPEN || targetStatus == AdoptionPostStatus.CLOSED;
            case OPEN -> targetStatus == AdoptionPostStatus.RESERVED
                    || targetStatus == AdoptionPostStatus.COMPLETED
                    || targetStatus == AdoptionPostStatus.CLOSED;
            case RESERVED -> targetStatus == AdoptionPostStatus.OPEN
                    || targetStatus == AdoptionPostStatus.COMPLETED
                    || targetStatus == AdoptionPostStatus.CLOSED;
            case COMPLETED, CLOSED -> false;
        };

        if (!allowed) {
            throw new ApiException(
                    HttpStatus.BAD_REQUEST,
                    "INVALID_STATUS_TRANSITION",
                    "요청한 게시글 상태 변경은 허용되지 않습니다."
            );
        }
    }

    private void applyStatusTransition(
            Long currentUserId,
            AdoptionPost post,
            AdoptionPostStatus currentStatus,
            AdoptionPostStatus targetStatus,
            LocalDateTime now
    ) {
        if (currentStatus == AdoptionPostStatus.DRAFT && targetStatus == AdoptionPostStatus.OPEN) {
            validatePublishEligibilityForExistingPost(currentUserId, post);
            post.setStatus(AdoptionPostStatus.OPEN);
            if (post.getPublishedAt() == null) {
                post.setPublishedAt(now);
            }
            post.setClosedAt(null);
            return;
        }

        if (currentStatus == AdoptionPostStatus.RESERVED && targetStatus == AdoptionPostStatus.OPEN) {
            post.setStatus(AdoptionPostStatus.OPEN);
            if (post.getPublishedAt() == null) {
                post.setPublishedAt(now);
            }
            post.setClosedAt(null);
            return;
        }

        if (targetStatus == AdoptionPostStatus.RESERVED) {
            post.setStatus(AdoptionPostStatus.RESERVED);
            post.setClosedAt(null);
            return;
        }

        if (targetStatus == AdoptionPostStatus.COMPLETED) {
            post.setStatus(AdoptionPostStatus.COMPLETED);
            post.setClosedAt(now);
            markDogAdopted(post.getDogId());
            return;
        }

        if (targetStatus == AdoptionPostStatus.CLOSED) {
            post.setStatus(AdoptionPostStatus.CLOSED);
            post.setClosedAt(now);
        }
    }

    private void validatePublishEligibilityForExistingPost(Long currentUserId, AdoptionPost post) {
        User currentUser = userRepository.findById(currentUserId)
                .orElseThrow(() -> new ApiException(HttpStatus.UNAUTHORIZED, "UNAUTHORIZED", "인증이 필요합니다."));
        validateUser(currentUser);

        Dog dog = dogRepository.findById(post.getDogId())
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "DOG_NOT_FOUND", "강아지를 찾을 수 없습니다."));
        validateDogOwner(currentUser, dog);
        validateDogStatus(dog);
        validateLatestVerificationLog(dog.getId());
        validateNoOtherActivePost(dog.getId(), post.getId());
    }

    private void markDogAdopted(String dogId) {
        Dog dog = dogRepository.findById(dogId)
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "DOG_NOT_FOUND", "강아지를 찾을 수 없습니다."));
        dog.setStatus(DogStatus.ADOPTED);
    }

    private void scheduleChatRoomStatusSync(Long postId, AdoptionPostStatus status) {
        if (TransactionSynchronizationManager.isSynchronizationActive()) {
            TransactionSynchronizationManager.registerSynchronization(new TransactionSynchronization() {
                @Override
                public void afterCommit() {
                    syncChatRoomPostStatusSafely(postId, status);
                }
            });
            return;
        }

        syncChatRoomPostStatusSafely(postId, status);
    }

    private void syncChatRoomPostStatusSafely(Long postId, AdoptionPostStatus status) {
        try {
            chatRoomPostStatusSyncService.syncPostStatus(postId, status);
        } catch (Exception ignored) {
            // Firebase chat state is a secondary snapshot; MySQL status changes remain authoritative.
        }
    }

    private int parsePageParameter(String value, int defaultValue) {
        if (value == null) {
            return defaultValue;
        }
        try {
            return Integer.parseInt(value);
        } catch (NumberFormatException e) {
            throw invalidPageRequest();
        }
    }

    private void validatePageRequest(int page, int size) {
        if (page < 0 || size <= 0 || size > MAX_PUBLIC_PAGE_SIZE) {
            throw invalidPageRequest();
        }
    }

    private ApiException invalidPageRequest() {
        return new ApiException(
                HttpStatus.BAD_REQUEST,
                "INVALID_PAGE_REQUEST",
                "page must be greater than or equal to 0 and size must be between 1 and 100"
        );
    }

    private PublicPostContext loadPublicPostContext(List<AdoptionPost> posts) {
        Set<String> dogIds = posts.stream()
                .map(AdoptionPost::getDogId)
                .collect(Collectors.toCollection(LinkedHashSet::new));
        Set<Long> authorUserIds = posts.stream()
                .map(AdoptionPost::getAuthorUserId)
                .collect(Collectors.toCollection(LinkedHashSet::new));

        Map<String, Dog> dogsById = dogRepository.findAllById(dogIds).stream()
                .collect(Collectors.toMap(Dog::getId, Function.identity()));
        Map<Long, User> authorsById = userRepository.findAllById(authorUserIds).stream()
                .collect(Collectors.toMap(User::getId, Function.identity()));

        return new PublicPostContext(
                dogsById,
                authorsById,
                loadProfileImageUrlsByDogId(dogIds),
                loadVerificationStatusesByDogId(dogIds)
        );
    }

    private OwnerPostContext loadOwnerPostContext(List<AdoptionPost> posts) {
        Set<String> dogIds = posts.stream()
                .map(AdoptionPost::getDogId)
                .collect(Collectors.toCollection(LinkedHashSet::new));

        Map<String, Dog> dogsById = dogRepository.findAllById(dogIds).stream()
                .collect(Collectors.toMap(Dog::getId, Function.identity()));

        return new OwnerPostContext(
                dogsById,
                loadProfileImageUrlsByDogId(dogIds),
                loadVerificationStatusesByDogId(dogIds)
        );
    }

    private Map<String, String> loadProfileImageUrlsByDogId(Set<String> dogIds) {
        Map<String, String> urlsByDogId = new HashMap<>();
        if (dogIds.isEmpty()) {
            return urlsByDogId;
        }

        dogImageRepository.findByDogIdInAndImageTypeOrderByDogIdAscUploadedAtDescIdDesc(dogIds, DogImageType.PROFILE)
                .forEach(image -> urlsByDogId.putIfAbsent(image.getDogId(), toFileUrl(image.getFilePath())));
        return urlsByDogId;
    }

    private Map<String, String> loadVerificationStatusesByDogId(Set<String> dogIds) {
        Map<String, String> statusesByDogId = new HashMap<>();
        if (dogIds.isEmpty()) {
            return statusesByDogId;
        }

        verificationLogRepository.findByDogIdInOrderByDogIdAscCreatedAtDescIdDesc(dogIds)
                .forEach(log -> statusesByDogId.putIfAbsent(log.getDogId(), toPublicVerificationStatus(log.getResult())));
        return statusesByDogId;
    }

    private AdoptionPostListItemResponse toListItemResponse(AdoptionPost post, PublicPostContext context) {
        Dog dog = requiredDog(post, context);
        User author = requiredAuthor(post, context);

        return new AdoptionPostListItemResponse(
                post.getId(),
                dog.getId(),
                post.getTitle(),
                post.getStatus().name(),
                dog.getName(),
                dog.getBreed(),
                dog.getGender() == null ? null : dog.getGender().name(),
                dog.getBirthDate(),
                context.profileImageUrlsByDogId().get(dog.getId()),
                context.verificationStatusesByDogId().getOrDefault(dog.getId(), "PENDING"),
                author.getDisplayName(),
                author.getRegion(),
                post.getPublishedAt(),
                post.getCreatedAt()
        );
    }

    private AdoptionPostOwnerListItemResponse toOwnerListItemResponse(AdoptionPost post, OwnerPostContext context) {
        Dog dog = requiredDog(post, context);

        return new AdoptionPostOwnerListItemResponse(
                post.getId(),
                dog.getId(),
                post.getTitle(),
                post.getStatus().name(),
                dog.getName(),
                dog.getBreed(),
                dog.getGender() == null ? null : dog.getGender().name(),
                dog.getBirthDate(),
                context.profileImageUrlsByDogId().get(dog.getId()),
                context.verificationStatusesByDogId().getOrDefault(dog.getId(), "PENDING"),
                post.getPublishedAt(),
                post.getClosedAt(),
                post.getCreatedAt(),
                post.getUpdatedAt()
        );
    }

    private AdoptionPostStatusUpdateResponse toStatusUpdateResponse(AdoptionPost post) {
        return new AdoptionPostStatusUpdateResponse(
                post.getId(),
                post.getDogId(),
                post.getTitle(),
                post.getContent(),
                post.getStatus().name(),
                post.getPublishedAt(),
                post.getClosedAt(),
                post.getCreatedAt(),
                post.getUpdatedAt()
        );
    }

    private AdoptionPostDetailResponse toDetailResponse(AdoptionPost post, PublicPostContext context) {
        Dog dog = requiredDog(post, context);
        User author = requiredAuthor(post, context);

        return new AdoptionPostDetailResponse(
                post.getId(),
                dog.getId(),
                post.getTitle(),
                post.getContent(),
                post.getStatus().name(),
                dog.getName(),
                dog.getBreed(),
                dog.getGender() == null ? null : dog.getGender().name(),
                dog.getBirthDate(),
                dog.getDescription(),
                context.profileImageUrlsByDogId().get(dog.getId()),
                context.verificationStatusesByDogId().getOrDefault(dog.getId(), "PENDING"),
                author.getDisplayName(),
                author.getContactPhone(),
                author.getRegion(),
                post.getPublishedAt(),
                post.getCreatedAt(),
                post.getUpdatedAt()
        );
    }

    private Dog requiredDog(AdoptionPost post, PublicPostContext context) {
        Dog dog = context.dogsById().get(post.getDogId());
        if (dog == null) {
            throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "POST_DATA_INTEGRITY_ERROR", "Post dog data is missing.");
        }
        return dog;
    }

    private Dog requiredDog(AdoptionPost post, OwnerPostContext context) {
        Dog dog = context.dogsById().get(post.getDogId());
        if (dog == null) {
            throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "POST_DATA_INTEGRITY_ERROR", "Post dog data is missing.");
        }
        return dog;
    }

    private User requiredAuthor(AdoptionPost post, PublicPostContext context) {
        User author = context.authorsById().get(post.getAuthorUserId());
        if (author == null) {
            throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "POST_DATA_INTEGRITY_ERROR", "Post author data is missing.");
        }
        return author;
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

    private String toPublicVerificationStatus(VerificationResult result) {
        if (result == null) {
            return "PENDING";
        }
        return switch (result) {
            case PASSED -> "VERIFIED";
            case DUPLICATE_SUSPECTED -> "DUPLICATE_SUSPECTED";
            case PENDING -> "PENDING";
            case EMBED_FAILED, QDRANT_SEARCH_FAILED, QDRANT_UPSERT_FAILED -> "FAILED";
        };
    }

    private record PublicPostContext(
            Map<String, Dog> dogsById,
            Map<Long, User> authorsById,
            Map<String, String> profileImageUrlsByDogId,
            Map<String, String> verificationStatusesByDogId
    ) {
    }

    private record OwnerPostContext(
            Map<String, Dog> dogsById,
            Map<String, String> profileImageUrlsByDogId,
            Map<String, String> verificationStatusesByDogId
    ) {
    }
}
