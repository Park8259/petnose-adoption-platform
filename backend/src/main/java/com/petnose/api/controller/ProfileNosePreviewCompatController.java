package com.petnose.api.controller;

import com.petnose.api.dto.registration.ProfileNosePreviewApiResponse;
import com.petnose.api.service.ProfileNosePreviewService;
import lombok.RequiredArgsConstructor;
import org.springframework.context.annotation.Profile;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.multipart.MultipartFile;

/**
 * Backward-compatible alias for the existing Flutter preview UX in non-dev profiles.
 * Only this non-destructive preview route is exposed; other /api/dev routes remain dev-only.
 */
@Profile("!dev")
@RestController
@RequestMapping("/api/dev")
@RequiredArgsConstructor
public class ProfileNosePreviewCompatController {

    private final ProfileNosePreviewService profileNosePreviewService;

    @PostMapping(value = "/profile-nose-preview", consumes = "multipart/form-data")
    public ResponseEntity<ProfileNosePreviewApiResponse> profileNosePreview(
            @RequestParam(value = "profile_image", required = false) MultipartFile profileImage
    ) {
        return ResponseEntity.ok(profileNosePreviewService.preview(profileImage));
    }
}
