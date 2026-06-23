package com.petnose.api.controller;

import com.petnose.api.dto.registration.DogRegisterRequest;
import com.petnose.api.dto.registration.DogRegisterResponse;
import com.petnose.api.dto.registration.DogNoseVerificationResponse;
import com.petnose.api.dto.registration.DogProfileDraftRequest;
import com.petnose.api.dto.registration.DogProfileDraftResponse;
import com.petnose.api.dto.registration.ProfileNosePreviewApiResponse;
import com.petnose.api.exception.ApiException;
import com.petnose.api.service.AuthService;
import com.petnose.api.service.DogRegistrationService;
import com.petnose.api.service.ProfileNosePreviewService;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpHeaders;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;

import java.util.List;
import java.util.UUID;

@RestController
@RequestMapping("/api/dogs")
@RequiredArgsConstructor
public class DogRegistrationController {

    private static final String REQUEST_ID_HEADER = "X-Request-Id";

    private final AuthService authService;
    private final DogRegistrationService dogRegistrationService;
    private final ProfileNosePreviewService profileNosePreviewService;

    @PostMapping(value = "/profile-nose-preview", consumes = "multipart/form-data")
    public ResponseEntity<ProfileNosePreviewApiResponse> profileNosePreview(
            @RequestHeader(value = REQUEST_ID_HEADER, required = false) String requestId,
            @RequestParam(value = "profile_image", required = false) MultipartFile profileImage
    ) {
        return ResponseEntity.ok(profileNosePreviewService.preview(profileImage, requestId));
    }

    @PostMapping(value = "/profile-draft", consumes = "multipart/form-data")
    public ResponseEntity<DogProfileDraftResponse> createProfileDraft(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorization,
            @RequestParam(value = "user_id", required = false) Long userId,
            @RequestParam(value = "name", required = false) String name,
            @RequestParam(value = "breed", required = false) String breed,
            @RequestParam(value = "gender", required = false) String gender,
            @RequestParam(value = "birth_date", required = false) String birthDate,
            @RequestParam(value = "description", required = false) String description,
            @RequestParam(value = "profile_image", required = false) MultipartFile profileImage
    ) {
        Long ownerUserId = resolveOwnerUserId(authorization, userId);
        DogProfileDraftResponse response = dogRegistrationService.createProfileDraft(
                new DogProfileDraftRequest(ownerUserId, name, breed, gender, birthDate, description, profileImage)
        );
        return ResponseEntity.status(HttpStatus.CREATED).body(response);
    }

    @PostMapping(value = "/{dogId}/nose-verification", consumes = "multipart/form-data")
    public ResponseEntity<DogNoseVerificationResponse> verifyPendingDogNose(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorization,
            @PathVariable String dogId,
            @RequestParam(value = "user_id", required = false) Long userId,
            @RequestParam(value = "nose_image", required = false) List<MultipartFile> noseImage,
            @RequestParam(value = "nose_images", required = false) List<MultipartFile> noseImages
    ) {
        Long ownerUserId = resolveOwnerUserId(authorization, userId);
        DogNoseVerificationResponse response = dogRegistrationService.verifyPendingDogWithNoseImages(
                dogId,
                ownerUserId,
                selectNoseImages(noseImage, noseImages)
        );
        return ResponseEntity.ok(response);
    }

    @PostMapping(value = "/register", consumes = "multipart/form-data")
    public ResponseEntity<DogRegisterResponse> registerDog(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorization,
            @RequestHeader(value = REQUEST_ID_HEADER, required = false) String requestId,
            @RequestParam(value = "user_id", required = false) Long userId,
            @RequestParam(value = "name", required = false) String name,
            @RequestParam(value = "breed", required = false) String breed,
            @RequestParam(value = "gender", required = false) String gender,
            @RequestParam(value = "birth_date", required = false) String birthDate,
            @RequestParam(value = "age", required = false) String age,
            @RequestParam(value = "price", required = false) String price,
            @RequestParam(value = "description", required = false) String description,
            @RequestParam(value = "health", required = false) String health,
            @RequestParam(value = "profile_image", required = false) MultipartFile profileImage,
            @RequestParam(value = "face_check_image", required = false) MultipartFile faceCheckImage,
            @RequestParam(value = "nose_image", required = false) List<MultipartFile> noseImage,
            @RequestParam(value = "nose_images", required = false) List<MultipartFile> noseImages
    ) {
        Long ownerUserId = resolveOwnerUserId(authorization, userId);
        DogRegisterRequest request = new DogRegisterRequest(
                ownerUserId,
                name,
                breed,
                gender,
                birthDate,
                age,
                price,
                description,
                health,
                selectNoseImages(noseImage, noseImages)
        );
        DogRegisterResponse response = hasPresentFile(profileImage) || hasPresentFile(faceCheckImage) || (requestId != null && !requestId.isBlank())
                ? dogRegistrationService.register(request, profileImage, faceCheckImage, requestIdOrNew(requestId))
                : dogRegistrationService.register(request);

        if (response.registrationAllowed()) {
            return ResponseEntity.status(HttpStatus.CREATED).body(response);
        }
        // TODO: 추후 프론트 협의 후 DUPLICATE_SUSPECTED를 HTTP 409로 전환 가능.
        return ResponseEntity.ok(response);
    }

    private Long resolveOwnerUserId(String authorization, Long userId) {
        if (authorization != null && !authorization.isBlank()) {
            return authService.currentActiveUserId(authorization);
        }
        if (userId == null) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "USER_ID_REQUIRED", "user_id는 필수입니다.");
        }
        return userId;
    }

    private static List<MultipartFile> selectNoseImages(
            List<MultipartFile> canonicalNoseImage,
            List<MultipartFile> legacyNoseImages
    ) {
        // `nose_image` is the canonical multipart field; `nose_images` is kept as a legacy alias.
        if (hasPresentFile(canonicalNoseImage)) {
            return canonicalNoseImage;
        }
        return legacyNoseImages;
    }

    private static String requestIdOrNew(String requestId) {
        return requestId == null || requestId.isBlank()
                ? UUID.randomUUID().toString()
                : requestId.trim();
    }

    private static boolean hasPresentFile(List<MultipartFile> files) {
        return files != null && files.stream().anyMatch(file -> file != null && !file.isEmpty());
    }

    private static boolean hasPresentFile(MultipartFile file) {
        return file != null && !file.isEmpty();
    }
}
