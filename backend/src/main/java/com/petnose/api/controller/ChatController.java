package com.petnose.api.controller;

import com.petnose.api.dto.chat.ChatMessageResponse;
import com.petnose.api.dto.chat.ChatMessageSendRequest;
import com.petnose.api.dto.chat.ChatReadResponse;
import com.petnose.api.dto.chat.ChatRoomCreateRequest;
import com.petnose.api.dto.chat.ChatRoomListResponse;
import com.petnose.api.dto.chat.ChatRoomResponse;
import com.petnose.api.dto.chat.FcmTokenUpdateRequest;
import com.petnose.api.dto.chat.FcmTokenUpdateResponse;
import com.petnose.api.dto.chat.FirebaseTokenResponse;
import com.petnose.api.dto.adoption.AdoptionPostStatusUpdateResponse;
import com.petnose.api.service.AuthService;
import com.petnose.api.service.chat.FirebaseChatService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;

@RestController
@RequiredArgsConstructor
public class ChatController {

    private final AuthService authService;
    private final FirebaseChatService firebaseChatService;

    @PostMapping("/api/firebase/custom-token")
    public FirebaseTokenResponse createFirebaseToken(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorizationHeader
    ) {
        Long currentUserId = authService.currentActiveUserId(authorizationHeader);
        return firebaseChatService.createFirebaseToken(currentUserId);
    }

    @PutMapping("/api/users/me/fcm-token")
    public FcmTokenUpdateResponse updateFcmToken(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorizationHeader,
            @Valid @RequestBody FcmTokenUpdateRequest request
    ) {
        Long currentUserId = authService.currentActiveUserId(authorizationHeader);
        return firebaseChatService.updateFcmToken(currentUserId, request.fcmToken(), request.platform());
    }

    @PostMapping("/api/chat/rooms")
    @ResponseStatus(HttpStatus.CREATED)
    public ChatRoomResponse createRoom(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorizationHeader,
            @Valid @RequestBody ChatRoomCreateRequest request
    ) {
        Long currentUserId = authService.currentActiveUserId(authorizationHeader);
        return firebaseChatService.createRoom(request.postId(), currentUserId);
    }

    @GetMapping("/api/chat/rooms")
    public ChatRoomListResponse listRooms(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorizationHeader,
            @RequestParam(defaultValue = "0") int page,
            @RequestParam(defaultValue = "20") int size
    ) {
        Long currentUserId = authService.currentActiveUserId(authorizationHeader);
        return firebaseChatService.listRooms(currentUserId, page, size);
    }

    @PostMapping("/api/chat/rooms/{room_id}/messages")
    @ResponseStatus(HttpStatus.CREATED)
    public ChatMessageResponse sendMessage(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorizationHeader,
            @PathVariable("room_id") String roomId,
            @Valid @RequestBody ChatMessageSendRequest request
    ) {
        Long currentUserId = authService.currentActiveUserId(authorizationHeader);
        return firebaseChatService.sendMessage(roomId, currentUserId, request.text(), request.clientMessageId());
    }

    @PostMapping(value = "/api/chat/rooms/{room_id}/messages/images", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    @ResponseStatus(HttpStatus.CREATED)
    public ChatMessageResponse sendImageMessage(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorizationHeader,
            @PathVariable("room_id") String roomId,
            @RequestParam(value = "image", required = false) MultipartFile image,
            @RequestParam(value = "client_message_id", required = false) String clientMessageId
    ) {
        Long currentUserId = authService.currentActiveUserId(authorizationHeader);
        return firebaseChatService.sendImageMessage(roomId, currentUserId, image, clientMessageId);
    }

    @PostMapping("/api/chat/rooms/{room_id}/reservation")
    public AdoptionPostStatusUpdateResponse reserveFromRoom(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorizationHeader,
            @PathVariable("room_id") String roomId
    ) {
        Long currentUserId = authService.currentActiveUserId(authorizationHeader);
        return firebaseChatService.reserveFromRoom(roomId, currentUserId);
    }

    @DeleteMapping("/api/chat/rooms/{room_id}/reservation")
    public AdoptionPostStatusUpdateResponse cancelReservationFromRoom(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorizationHeader,
            @PathVariable("room_id") String roomId
    ) {
        Long currentUserId = authService.currentActiveUserId(authorizationHeader);
        return firebaseChatService.cancelReservationFromRoom(roomId, currentUserId);
    }

    @PostMapping("/api/chat/rooms/{room_id}/completion")
    public AdoptionPostStatusUpdateResponse completeFromRoom(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorizationHeader,
            @PathVariable("room_id") String roomId
    ) {
        Long currentUserId = authService.currentActiveUserId(authorizationHeader);
        return firebaseChatService.completeFromRoom(roomId, currentUserId);
    }

    @PatchMapping("/api/chat/rooms/{room_id}/read")
    public ChatReadResponse markAsRead(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorizationHeader,
            @PathVariable("room_id") String roomId
    ) {
        Long currentUserId = authService.currentActiveUserId(authorizationHeader);
        return firebaseChatService.markAsRead(roomId, currentUserId);
    }
}
