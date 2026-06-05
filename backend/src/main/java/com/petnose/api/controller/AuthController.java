package com.petnose.api.controller;

import com.petnose.api.dto.auth.LoginRequest;
import com.petnose.api.dto.auth.LoginResponse;
import com.petnose.api.dto.auth.PasswordResetConfirmRequest;
import com.petnose.api.dto.auth.PasswordResetConfirmResponse;
import com.petnose.api.dto.auth.PasswordResetRequest;
import com.petnose.api.dto.auth.PasswordResetRequestResponse;
import com.petnose.api.dto.auth.RegisterRequest;
import com.petnose.api.dto.user.UserMeResponse;
import com.petnose.api.service.AuthService;
import jakarta.validation.Valid;
import lombok.RequiredArgsConstructor;
import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;
import org.springframework.web.multipart.MultipartFile;

@RestController
@RequestMapping("/api/auth")
@RequiredArgsConstructor
public class AuthController {

    private final AuthService authService;

    @PostMapping(value = "/register", consumes = MediaType.APPLICATION_JSON_VALUE)
    public ResponseEntity<UserMeResponse> register(@Valid @RequestBody RegisterRequest request) {
        return ResponseEntity.status(HttpStatus.CREATED).body(authService.register(request));
    }

    @PostMapping(value = "/register", consumes = MediaType.MULTIPART_FORM_DATA_VALUE)
    public ResponseEntity<UserMeResponse> registerMultipart(
            @RequestParam(value = "email", required = false) String email,
            @RequestParam(value = "password", required = false) String password,
            @RequestParam(value = "display_name", required = false) String displayName,
            @RequestParam(value = "contact_phone", required = false) String contactPhone,
            @RequestParam(value = "region", required = false) String region,
            @RequestParam(value = "profile_image", required = false) MultipartFile profileImage
    ) {
        RegisterRequest request = new RegisterRequest(email, password, displayName, contactPhone, region);
        return ResponseEntity.status(HttpStatus.CREATED).body(authService.register(request, profileImage));
    }

    @PostMapping("/login")
    public LoginResponse login(@Valid @RequestBody LoginRequest request) {
        return authService.login(request);
    }

    @PostMapping("/password-reset/request")
    public PasswordResetRequestResponse requestPasswordReset(@Valid @RequestBody PasswordResetRequest request) {
        return authService.requestPasswordReset(request);
    }

    @PostMapping("/password-reset/confirm")
    public PasswordResetConfirmResponse confirmPasswordReset(@Valid @RequestBody PasswordResetConfirmRequest request) {
        return authService.confirmPasswordReset(request);
    }
}
