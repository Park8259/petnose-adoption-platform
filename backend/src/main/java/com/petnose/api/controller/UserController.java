package com.petnose.api.controller;

import com.petnose.api.dto.user.UserMeResponse;
import com.petnose.api.dto.user.UserPasswordChangeRequest;
import com.petnose.api.dto.user.UserPasswordChangeResponse;
import com.petnose.api.dto.user.UserProfileImageUpdateResponse;
import com.petnose.api.dto.user.UserProfileResponse;
import com.petnose.api.dto.user.UserProfileUpdateRequest;
import com.petnose.api.service.AuthService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;

@RestController
@RequestMapping("/api/users")
@RequiredArgsConstructor
public class UserController {

    private final AuthService authService;

    @GetMapping("/me")
    public UserMeResponse me(@RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorization) {
        return authService.me(authorization);
    }

    @PatchMapping("/me/profile")
    public UserProfileResponse updateProfile(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorization,
            @RequestBody UserProfileUpdateRequest request
    ) {
        return authService.updateProfile(authorization, request);
    }

    @PatchMapping(value = "/me/profile-image", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public UserProfileImageUpdateResponse updateProfileImage(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorization,
            @RequestParam(value = "profile_image", required = false) MultipartFile profileImage
    ) {
        return authService.updateProfileImage(authorization, profileImage);
    }

    @PatchMapping("/me/password")
    public UserPasswordChangeResponse changePassword(
            @RequestHeader(value = HttpHeaders.AUTHORIZATION, required = false) String authorization,
            @Valid @RequestBody UserPasswordChangeRequest request
    ) {
        return authService.changePassword(authorization, request);
    }
}
