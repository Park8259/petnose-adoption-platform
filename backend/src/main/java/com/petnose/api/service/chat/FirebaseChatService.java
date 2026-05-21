package com.petnose.api.service.chat;

import com.google.cloud.Timestamp;
import com.google.cloud.firestore.*;
import com.google.firebase.auth.FirebaseAuth;
import com.google.firebase.messaging.FirebaseMessaging;
import com.google.firebase.messaging.Message;
import com.petnose.api.domain.entity.AdoptionPost;
import com.petnose.api.domain.entity.Dog;
import com.petnose.api.domain.entity.User;
import com.petnose.api.domain.enums.AdoptionPostStatus;
import com.petnose.api.domain.enums.DogImageType;
import com.petnose.api.domain.enums.DogStatus;
import com.petnose.api.domain.enums.FcmPlatform;
import com.petnose.api.dto.chat.*;
import com.petnose.api.exception.ApiException;
import com.petnose.api.repository.AdoptionPostRepository;
import com.petnose.api.repository.DogImageRepository;
import com.petnose.api.repository.DogRepository;
import com.petnose.api.repository.UserRepository;
import com.petnose.api.service.FileStorageService;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.http.HttpStatus;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.*;

@Slf4j
@Service
public class FirebaseChatService {

    private static final String CHAT_ROOMS = "chat_rooms";
    private static final String MESSAGES = "messages";
    private static final String USER_DEVICES = "user_devices";

    private final AdoptionPostRepository adoptionPostRepository;
    private final DogRepository dogRepository;
    private final DogImageRepository dogImageRepository;
    private final UserRepository userRepository;
    private final FileStorageService fileStorageService;
    private final Firestore firestore;
    private final FirebaseAuth firebaseAuth;
    private final FirebaseMessaging firebaseMessaging;

    public FirebaseChatService(
            AdoptionPostRepository adoptionPostRepository,
            DogRepository dogRepository,
            DogImageRepository dogImageRepository,
            UserRepository userRepository,
            FileStorageService fileStorageService,
            ObjectProvider<Firestore> firestoreProvider,
            ObjectProvider<FirebaseAuth> firebaseAuthProvider,
            ObjectProvider<FirebaseMessaging> firebaseMessagingProvider
    ) {
        this.adoptionPostRepository = adoptionPostRepository;
        this.dogRepository = dogRepository;
        this.dogImageRepository = dogImageRepository;
        this.userRepository = userRepository;
        this.fileStorageService = fileStorageService;
        this.firestore = firestoreProvider.getIfAvailable();
        this.firebaseAuth = firebaseAuthProvider.getIfAvailable();
        this.firebaseMessaging = firebaseMessagingProvider.getIfAvailable();
    }

    @Transactional(readOnly = true)
    public FirebaseTokenResponse createFirebaseToken(Long userId) {
        requireActiveUser(userId);
        if (firebaseAuth == null) {
            throw firebaseDisabled();
        }

        String uid = firebaseUid(userId);
        try {
            String token = firebaseAuth.createCustomToken(uid, Map.of("user_id", userId));
            return new FirebaseTokenResponse(uid, token);
        } catch (Exception e) {
            throw new ApiException(
                    HttpStatus.SERVICE_UNAVAILABLE,
                    "FIREBASE_TOKEN_ISSUE_FAILED",
                    "Firebase 인증 토큰을 발급하지 못했습니다."
            );
        }
    }

    @Transactional(readOnly = true)
    public FcmTokenUpdateResponse updateFcmToken(Long userId, String fcmToken, FcmPlatform platform) {
        Firestore db = requireFirestore();
        requireActiveUser(userId);

        String uid = firebaseUid(userId);
        String tokenHash = sha256(fcmToken);
        DocumentReference tokenRef = db.collection(USER_DEVICES)
                .document(uid)
                .collection("tokens")
                .document(tokenHash);

        Map<String, Object> device = new LinkedHashMap<>();
        device.put("fcm_token", fcmToken);
        device.put("platform", platform.name());
        device.put("created_at", FieldValue.serverTimestamp());
        device.put("updated_at", FieldValue.serverTimestamp());
        device.put("last_seen_at", FieldValue.serverTimestamp());

        try {
            tokenRef.set(device, SetOptions.merge()).get();
            return new FcmTokenUpdateResponse(true);
        } catch (Exception e) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "CHAT_MESSAGE_SEND_FAILED", "FCM 토큰을 저장하지 못했습니다.");
        }
    }

    @Transactional(readOnly = true)
    public ChatRoomResponse createRoom(Long postId, Long requesterUserId) {
        Firestore db = requireFirestore();
        User requester = requireActiveUser(requesterUserId);
        AdoptionPost post = requirePost(postId);
        Dog dog = requireDog(post.getDogId());
        requireRegisteredDog(dog);
        User author = requireActiveUser(post.getAuthorUserId());

        if (Objects.equals(post.getAuthorUserId(), requester.getId())) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "CHAT_SELF_INQUIRY_NOT_ALLOWED", "본인 게시글에는 문의할 수 없습니다.");
        }

        String roomId = roomId(post.getId(), requester.getId());
        DocumentReference roomRef = db.collection(CHAT_ROOMS).document(roomId);
        DocumentSnapshot existingRoom = readRoomIfExists(roomRef);
        if (existingRoom != null) {
            return toRoomResponse(roomId, post, requester.getId());
        }

        if (!canCreateRoom(post.getStatus())) {
            throw new ApiException(
                    HttpStatus.CONFLICT,
                    "CHAT_NOT_ALLOWED_FOR_POST_STATUS",
                    "현재 게시글 상태에서는 채팅을 시작할 수 없습니다.",
                    Map.of("post_id", post.getId(), "status", post.getStatus().name())
            );
        }

        ChatRoomState roomState = ChatRoomState.from(post.getStatus());
        Map<String, Object> room = new LinkedHashMap<>();
        room.put("room_id", roomId);
        room.put("post_id", post.getId());
        room.put("dog_id", dog.getId());
        room.put("author_uid", firebaseUid(author.getId()));
        room.put("inquirer_uid", firebaseUid(requester.getId()));
        room.put("author_user_id", author.getId());
        room.put("inquirer_user_id", requester.getId());
        room.put("participant_uids", List.of(firebaseUid(author.getId()), firebaseUid(requester.getId())));
        room.put("participant_user_ids", List.of(author.getId(), requester.getId()));
        room.put("participants", participantsSnapshot(author, requester));
        room.put("post_snapshot", postSnapshot(post, dog));
        room.put("post_status_snapshot", post.getStatus().name());
        room.put("room_status", roomState.roomStatus());
        room.put("message_enabled", roomState.messageEnabled());
        room.put("last_read_at", lastReadAt(author.getId(), requester.getId()));
        room.put("status", "ACTIVE");
        room.put("created_at", FieldValue.serverTimestamp());
        room.put("updated_at", FieldValue.serverTimestamp());
        room.put("synced_at", FieldValue.serverTimestamp());

        try {
            roomRef.set(room, SetOptions.merge()).get();
            return toRoomResponse(roomId, post, requester.getId());
        } catch (Exception e) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "CHAT_MESSAGE_SEND_FAILED", "채팅방을 생성하지 못했습니다.");
        }
    }

    @Transactional(readOnly = true)
    public ChatRoomListResponse listRooms(Long userId, int page, int size) {
        Firestore db = requireFirestore();
        requireActiveUser(userId);

        int safePage = Math.max(page, 0);
        int safeSize = Math.max(size, 1);
        String uid = firebaseUid(userId);
        List<QueryDocumentSnapshot> snapshots;
        try {
            snapshots = db.collection(CHAT_ROOMS)
                    .whereArrayContains("participant_uids", uid)
                    .get()
                    .get()
                    .getDocuments();
        } catch (Exception e) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "CHAT_ROOM_NOT_FOUND", "채팅방 목록을 조회하지 못했습니다.");
        }

        List<ChatRoomListItemResponse> allItems = snapshots.stream()
                .sorted(Comparator.comparing(this::roomUpdatedAt).reversed())
                .map(snapshot -> toListItem(snapshot, userId))
                .toList();

        int fromIndex = Math.min(safePage * safeSize, allItems.size());
        int toIndex = Math.min(fromIndex + safeSize, allItems.size());
        return new ChatRoomListResponse(allItems.subList(fromIndex, toIndex), safePage, safeSize, allItems.size());
    }

    @Transactional(readOnly = true)
    public ChatMessageResponse sendMessage(String roomId, Long senderUserId, String text, String clientMessageId) {
        Firestore db = requireFirestore();
        requireActiveUser(senderUserId);
        String trimmedText = validateMessageText(text);

        DocumentReference roomRef = db.collection(CHAT_ROOMS).document(roomId);
        DocumentSnapshot roomSnapshot = requireRoom(roomRef);
        List<Long> participantIds = readParticipantUserIds(roomSnapshot);
        if (!participantIds.contains(senderUserId)) {
            throw new ApiException(HttpStatus.FORBIDDEN, "CHAT_ROOM_ACCESS_DENIED", "이 채팅방에 메시지를 보낼 권한이 없습니다.");
        }

        Long postId = roomSnapshot.getLong("post_id");
        if (postId == null) {
            throw new ApiException(HttpStatus.CONFLICT, "CHAT_ROOM_NOT_FOUND", "채팅방의 게시글 정보가 올바르지 않습니다.");
        }

        AdoptionPost post = requirePost(postId);
        validateRoomId(roomId, post, roomSnapshot);
        if (!canSendMessage(post.getStatus())) {
            throw new ApiException(
                    HttpStatus.CONFLICT,
                    "CHAT_ROOM_ALREADY_CLOSED",
                    "현재 게시글 상태에서는 메시지를 보낼 수 없습니다.",
                    Map.of("post_id", post.getId(), "status", post.getStatus().name())
            );
        }

        ChatMessageResponse existingMessage = findExistingMessage(roomRef, roomId, senderUserId, clientMessageId);
        if (existingMessage != null) {
            return existingMessage;
        }

        DocumentReference messageRef = roomRef.collection(MESSAGES).document();
        String senderUid = firebaseUid(senderUserId);
        Instant responseCreatedAt = Instant.now();
        Map<String, Object> message = new LinkedHashMap<>();
        message.put("message_id", messageRef.getId());
        message.put("room_id", roomId);
        message.put("sender_uid", senderUid);
        message.put("sender_user_id", senderUserId);
        message.put("type", "TEXT");
        message.put("text", trimmedText);
        message.put("client_message_id", clientMessageId == null ? "" : clientMessageId);
        message.put("created_at", FieldValue.serverTimestamp());

        ChatRoomState roomState = ChatRoomState.from(post.getStatus());
        WriteBatch batch = db.batch();
        batch.set(messageRef, message);
        batch.set(roomRef, Map.of(
                "updated_at", FieldValue.serverTimestamp(),
                "synced_at", FieldValue.serverTimestamp(),
                "post_status_snapshot", post.getStatus().name(),
                "room_status", roomState.roomStatus(),
                "message_enabled", roomState.messageEnabled(),
                "last_message", Map.of(
                        "text_preview", preview(trimmedText),
                        "sender_uid", senderUid,
                        "created_at", FieldValue.serverTimestamp()
                )
        ), SetOptions.merge());

        try {
            batch.commit().get();
        } catch (Exception e) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "CHAT_MESSAGE_SEND_FAILED", "메시지를 전송하지 못했습니다.");
        }

        sendPushToOtherParticipants(roomId, post.getId(), participantIds, senderUserId, trimmedText);
        return new ChatMessageResponse(messageRef.getId(), roomId, senderUid, "TEXT", trimmedText, responseCreatedAt.toString());
    }

    @Transactional(readOnly = true)
    public ChatReadResponse markAsRead(String roomId, Long userId) {
        Firestore db = requireFirestore();
        requireActiveUser(userId);
        DocumentReference roomRef = db.collection(CHAT_ROOMS).document(roomId);
        DocumentSnapshot snapshot = requireRoom(roomRef);
        List<Long> participantIds = readParticipantUserIds(snapshot);
        if (!participantIds.contains(userId)) {
            throw new ApiException(HttpStatus.FORBIDDEN, "CHAT_ROOM_ACCESS_DENIED", "이 채팅방을 읽음 처리할 권한이 없습니다.");
        }

        try {
            roomRef.update("last_read_at.%s".formatted(firebaseUid(userId)), FieldValue.serverTimestamp()).get();
            return new ChatReadResponse(roomId, true);
        } catch (Exception e) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "CHAT_MESSAGE_SEND_FAILED", "채팅방 읽음 처리를 저장하지 못했습니다.");
        }
    }

    private Firestore requireFirestore() {
        if (firestore == null) {
            throw firebaseDisabled();
        }
        return firestore;
    }

    private ApiException firebaseDisabled() {
        return new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "FIREBASE_DISABLED", "Firebase 연동이 비활성화되어 있습니다.");
    }

    private User requireActiveUser(Long userId) {
        User user = userRepository.findById(userId)
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "USER_NOT_FOUND", "존재하지 않는 사용자입니다."));
        if (!user.isActive()) {
            throw new ApiException(HttpStatus.FORBIDDEN, "USER_INACTIVE", "비활성화된 사용자입니다.");
        }
        return user;
    }

    private AdoptionPost requirePost(Long postId) {
        return adoptionPostRepository.findById(postId)
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "POST_NOT_FOUND", "Adoption post was not found."));
    }

    private Dog requireDog(String dogId) {
        return dogRepository.findById(dogId)
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "DOG_NOT_FOUND", "강아지를 찾을 수 없습니다."));
    }

    private void requireRegisteredDog(Dog dog) {
        if (dog.getStatus() != DogStatus.REGISTERED) {
            throw new ApiException(HttpStatus.CONFLICT, "DOG_NOT_REGISTERED", "등록 완료된 강아지 게시글에서만 채팅방을 만들 수 있습니다.");
        }
    }

    private boolean canCreateRoom(AdoptionPostStatus status) {
        return status == AdoptionPostStatus.OPEN;
    }

    private boolean canSendMessage(AdoptionPostStatus status) {
        return status == AdoptionPostStatus.OPEN || status == AdoptionPostStatus.RESERVED;
    }

    private DocumentSnapshot requireRoom(DocumentReference roomRef) {
        try {
            DocumentSnapshot snapshot = roomRef.get().get();
            if (!snapshot.exists()) {
                throw new ApiException(HttpStatus.NOT_FOUND, "CHAT_ROOM_NOT_FOUND", "채팅방을 찾을 수 없습니다.");
            }
            return snapshot;
        } catch (ApiException e) {
            throw e;
        } catch (Exception e) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "CHAT_ROOM_NOT_FOUND", "채팅방 정보를 읽지 못했습니다.");
        }
    }

    private DocumentSnapshot readRoomIfExists(DocumentReference roomRef) {
        try {
            DocumentSnapshot snapshot = roomRef.get().get();
            return snapshot.exists() ? snapshot : null;
        } catch (Exception e) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "CHAT_ROOM_NOT_FOUND", "채팅방 정보를 읽지 못했습니다.");
        }
    }

    private List<Long> readParticipantUserIds(DocumentSnapshot snapshot) {
        List<?> rawParticipants = snapshot.get("participant_user_ids", List.class);
        if (rawParticipants == null) {
            throw new ApiException(HttpStatus.CONFLICT, "CHAT_ROOM_NOT_FOUND", "채팅방 참여자 정보가 올바르지 않습니다.");
        }
        return rawParticipants.stream()
                .map(value -> Long.parseLong(value.toString()))
                .toList();
    }

    private ChatRoomResponse toRoomResponse(String roomId, AdoptionPost post, Long inquirerUserId) {
        return new ChatRoomResponse(roomId, post.getId(), CHAT_ROOMS + "/" + roomId, post.getAuthorUserId(), inquirerUserId, "ACTIVE");
    }

    private String roomId(Long postId, Long inquirerUserId) {
        return "post_%d_user_%d".formatted(postId, inquirerUserId);
    }

    private String firebaseUid(Long userId) {
        return "user_%d".formatted(userId);
    }

    private Map<String, Object> participantsSnapshot(User author, User requester) {
        Map<String, Object> participants = new LinkedHashMap<>();
        participants.put(firebaseUid(author.getId()), participantSnapshot(author, "AUTHOR"));
        participants.put(firebaseUid(requester.getId()), participantSnapshot(requester, "INQUIRER"));
        return participants;
    }

    private Map<String, Object> participantSnapshot(User user, String role) {
        return Map.of(
                "user_id", user.getId(),
                "display_name", safeDisplayName(user),
                "role", role
        );
    }

    private Map<String, Object> lastReadAt(Long authorUserId, Long inquirerUserId) {
        Map<String, Object> lastReadAt = new LinkedHashMap<>();
        lastReadAt.put(firebaseUid(authorUserId), null);
        lastReadAt.put(firebaseUid(inquirerUserId), null);
        return lastReadAt;
    }

    private Map<String, Object> postSnapshot(AdoptionPost post, Dog dog) {
        Map<String, Object> snapshot = new LinkedHashMap<>();
        snapshot.put("title", post.getTitle());
        snapshot.put("status", post.getStatus().name());
        snapshot.put("dog_name", dog.getName());
        snapshot.put("breed", dog.getBreed());
        dogImageRepository.findFirstByDogIdAndImageTypeOrderByUploadedAtDescIdDesc(dog.getId(), DogImageType.PROFILE)
                .ifPresent(image -> snapshot.put("profile_image_url", fileStorageService.toPublicUrl(image.getFilePath())));
        return snapshot;
    }

    private void validateRoomId(String roomId, AdoptionPost post, DocumentSnapshot roomSnapshot) {
        Long inquirerUserId = roomSnapshot.getLong("inquirer_user_id");
        if (inquirerUserId == null || !roomId(post.getId(), inquirerUserId).equals(roomId)) {
            throw new ApiException(HttpStatus.CONFLICT, "CHAT_ROOM_NOT_FOUND", "채팅방 ID 규칙이 올바르지 않습니다.");
        }
    }

    private String validateMessageText(String text) {
        String trimmed = text == null ? "" : text.trim();
        if (trimmed.isBlank()) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "CHAT_MESSAGE_EMPTY", "메시지는 비어 있을 수 없습니다.");
        }
        if (trimmed.length() > 1000) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "CHAT_MESSAGE_TOO_LONG", "메시지는 1000자를 초과할 수 없습니다.");
        }
        return trimmed;
    }

    private ChatMessageResponse findExistingMessage(DocumentReference roomRef, String roomId, Long senderUserId, String clientMessageId) {
        if (clientMessageId == null || clientMessageId.isBlank()) {
            return null;
        }
        try {
            List<QueryDocumentSnapshot> documents = roomRef.collection(MESSAGES)
                    .whereEqualTo("sender_user_id", senderUserId)
                    .whereEqualTo("client_message_id", clientMessageId)
                    .limit(1)
                    .get()
                    .get()
                    .getDocuments();
            if (documents.isEmpty()) {
                return null;
            }
            DocumentSnapshot message = documents.getFirst();
            Timestamp createdAt = message.getTimestamp("created_at");
            return new ChatMessageResponse(
                    message.getId(),
                    roomId,
                    firebaseUid(senderUserId),
                    Optional.ofNullable(message.getString("type")).orElse("TEXT"),
                    Optional.ofNullable(message.getString("text")).orElse(""),
                    createdAt == null ? Instant.now().toString() : createdAt.toDate().toInstant().toString()
            );
        } catch (Exception e) {
            throw new ApiException(HttpStatus.SERVICE_UNAVAILABLE, "CHAT_MESSAGE_SEND_FAILED", "중복 메시지 확인에 실패했습니다.");
        }
    }

    private ChatRoomListItemResponse toListItem(DocumentSnapshot snapshot, Long currentUserId) {
        Long postId = snapshot.getLong("post_id");
        AdoptionPost post = postId == null ? null : adoptionPostRepository.findById(postId).orElse(null);
        Long authorUserId = snapshot.getLong("author_user_id");
        Long inquirerUserId = snapshot.getLong("inquirer_user_id");
        Long otherUserId = Objects.equals(currentUserId, authorUserId) ? inquirerUserId : authorUserId;
        Map<String, Object> lastMessage = readMap(snapshot, "last_message");

        return new ChatRoomListItemResponse(
                snapshot.getId(),
                postId,
                post == null ? "" : post.getTitle(),
                post == null ? "" : post.getStatus().name(),
                otherUserId == null ? "" : userRepository.findById(otherUserId).map(this::safeDisplayName).orElse(""),
                Objects.toString(lastMessage.getOrDefault("text_preview", ""), ""),
                timestampString(lastMessage.get("created_at")),
                0
        );
    }

    private Map<String, Object> readMap(DocumentSnapshot snapshot, String field) {
        Object value = snapshot.get(field);
        if (value instanceof Map<?, ?> rawMap) {
            Map<String, Object> map = new HashMap<>();
            rawMap.forEach((key, mapValue) -> map.put(String.valueOf(key), mapValue));
            return map;
        }
        return Map.of();
    }

    private Instant roomUpdatedAt(DocumentSnapshot snapshot) {
        Timestamp timestamp = snapshot.getTimestamp("updated_at");
        return timestamp == null ? Instant.EPOCH : timestamp.toDate().toInstant();
    }

    private String timestampString(Object value) {
        if (value instanceof Timestamp timestamp) {
            return timestamp.toDate().toInstant().toString();
        }
        return "";
    }

    private String safeDisplayName(User user) {
        if (user.getDisplayName() != null && !user.getDisplayName().isBlank()) {
            return user.getDisplayName();
        }
        return "사용자 %d".formatted(user.getId());
    }

    private String preview(String text) {
        return text.length() <= 120 ? text : text.substring(0, 120);
    }

    private String sha256(String value) {
        try {
            MessageDigest digest = MessageDigest.getInstance("SHA-256");
            byte[] hash = digest.digest(value.getBytes(StandardCharsets.UTF_8));
            StringBuilder builder = new StringBuilder();
            for (byte b : hash) {
                builder.append("%02x".formatted(b));
            }
            return builder.toString();
        } catch (Exception e) {
            throw new ApiException(HttpStatus.INTERNAL_SERVER_ERROR, "FCM_TOKEN_INVALID", "FCM 토큰 처리에 실패했습니다.");
        }
    }

    private void sendPushToOtherParticipants(String roomId, Long postId, List<Long> participants, Long senderUserId, String text) {
        if (firebaseMessaging == null) {
            return;
        }

        participants.stream()
                .filter(userId -> !Objects.equals(userId, senderUserId))
                .forEach(userId -> sendPushToUser(roomId, postId, userId, text));
    }

    private void sendPushToUser(String roomId, Long postId, Long recipientUserId, String text) {
        for (DocumentSnapshot device : findUserDevices(recipientUserId)) {
            String token = device.getString("fcm_token");
            if (token == null || token.isBlank()) {
                continue;
            }
            try {
                Message message = Message.builder()
                        .setToken(token)
                        .putData("type", "chat_message")
                        .putData("room_id", roomId)
                        .putData("post_id", postId.toString())
                        .putData("preview", preview(text))
                        .build();
                firebaseMessaging.send(message);
            } catch (Exception e) {
                log.warn("[FCM] 채팅 push 발송 실패: recipientUserId={}, platform={}, error={}",
                        recipientUserId,
                        device.getString("platform"),
                        e.getClass().getSimpleName());
            }
        }
    }

    private List<QueryDocumentSnapshot> findUserDevices(Long userId) {
        try {
            return requireFirestore()
                    .collection(USER_DEVICES)
                    .document(firebaseUid(userId))
                    .collection("tokens")
                    .get()
                    .get()
                    .getDocuments();
        } catch (Exception e) {
            log.warn("[FCM] 사용자 디바이스 조회 실패: recipientUserId={}, error={}", userId, e.getClass().getSimpleName());
            return List.of();
        }
    }
}
