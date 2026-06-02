package com.petnose.api.service;

import com.petnose.api.domain.entity.PasswordResetToken;
import com.petnose.api.domain.entity.User;
import com.petnose.api.domain.enums.UserRole;
import com.petnose.api.dto.auth.LoginRequest;
import com.petnose.api.dto.auth.LoginResponse;
import com.petnose.api.dto.auth.PasswordResetConfirmRequest;
import com.petnose.api.dto.auth.PasswordResetConfirmResponse;
import com.petnose.api.dto.auth.PasswordResetRequest;
import com.petnose.api.dto.auth.PasswordResetRequestResponse;
import com.petnose.api.dto.auth.RegisterRequest;
import com.petnose.api.dto.user.UserMeResponse;
import com.petnose.api.dto.user.UserPasswordChangeRequest;
import com.petnose.api.dto.user.UserPasswordChangeResponse;
import com.petnose.api.dto.user.UserProfileImageUpdateResponse;
import com.petnose.api.dto.user.UserProfileResponse;
import com.petnose.api.dto.user.UserProfileUpdateRequest;
import com.petnose.api.exception.ApiException;
import com.petnose.api.repository.PasswordResetTokenRepository;
import com.petnose.api.repository.UserRepository;
import lombok.RequiredArgsConstructor;
import org.springframework.dao.DataIntegrityViolationException;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.http.HttpStatus;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;
import org.springframework.web.multipart.MultipartFile;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.security.SecureRandom;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Base64;
import java.util.HexFormat;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.regex.Pattern;

@Service
@RequiredArgsConstructor
public class AuthService {

    private static final int MAX_EMAIL_LENGTH = 255;
    private static final int MAX_DISPLAY_NAME_LENGTH = 150;
    private static final int MAX_CONTACT_PHONE_LENGTH = 30;
    private static final int MAX_REGION_LENGTH = 100;
    private static final int MAX_PROFILE_REGION_LENGTH = 100;
    private static final int MIN_PASSWORD_LENGTH = 8;
    private static final int MAX_PASSWORD_LENGTH = 255;
    private static final int PASSWORD_RESET_TOKEN_BYTES = 32;
    private static final String SHA_256 = "SHA-256";
    private static final Pattern PROFILE_DISPLAY_NAME_PATTERN = Pattern.compile("^[가-힣A-Za-z0-9]{2,10}$");
    private static final Pattern PROFILE_CONTACT_PHONE_PATTERN = Pattern.compile("^010[0-9]{8}$");

    private final UserRepository userRepository;
    private final PasswordResetTokenRepository passwordResetTokenRepository;
    private final PasswordEncoder passwordEncoder;
    private final JwtTokenService jwtTokenService;
    private final FileStorageService fileStorageService;
    private final SecureRandom secureRandom = new SecureRandom();

    @Value("${auth.password-reset.token-ttl-seconds:1800}")
    private long passwordResetTokenTtlSeconds;

    @Value("${auth.password-reset.expose-token-in-response:false}")
    private boolean exposePasswordResetTokenInResponse;

    @Transactional
    public UserMeResponse register(RegisterRequest request) {
        return register(request, null);
    }

    @Transactional
    public UserMeResponse register(RegisterRequest request, MultipartFile profileImage) {
        String email = normalizeEmail(request.email());
        String password = required(request.password(), "password");
        if (password.length() < 8) {
            throw badRequest("password는 8자 이상이어야 합니다.");
        }
        if (userRepository.existsByEmail(email)) {
            throw new ApiException(HttpStatus.CONFLICT, "EMAIL_ALREADY_EXISTS", "이미 가입된 email 입니다.");
        }

        String displayName = required(request.displayName(), "display_name");
        String contactPhone = required(request.contactPhone(), "contact_phone");
        String region = required(request.region(), "region");
        validateDisplayName(displayName);
        validateContactPhone(contactPhone);
        validateRegion(region, MAX_REGION_LENGTH);

        User user = new User();
        user.setEmail(email);
        user.setPasswordHash(passwordEncoder.encode(password));
        user.setRole(UserRole.USER);
        user.setDisplayName(displayName);
        user.setContactPhone(contactPhone);
        user.setRegion(region);
        user.setActive(true);

        try {
            User saved = userRepository.saveAndFlush(user);
            storeUserProfileImageIfPresent(saved, profileImage);
            userRepository.flush();
            return UserMeResponse.from(saved);
        } catch (DataIntegrityViolationException e) {
            throw new ApiException(HttpStatus.CONFLICT, "EMAIL_ALREADY_EXISTS", "이미 가입된 email 입니다.");
        }
    }

    @Transactional(readOnly = true)
    public LoginResponse login(LoginRequest request) {
        String email = normalizeEmail(request.email());
        String password = required(request.password(), "password");

        User user = userRepository.findByEmail(email)
                .orElseThrow(this::invalidCredentials);
        if (!passwordEncoder.matches(password, user.getPasswordHash())) {
            throw invalidCredentials();
        }
        if (!user.isActive()) {
            throw new ApiException(HttpStatus.FORBIDDEN, "USER_INACTIVE", "비활성화된 사용자입니다.");
        }

        return new LoginResponse(
                jwtTokenService.createAccessToken(user),
                "Bearer",
                jwtTokenService.getAccessTokenTtlSeconds(),
                UserMeResponse.from(user)
        );
    }

    @Transactional(readOnly = true)
    public UserMeResponse me(String authorizationHeader) {
        return UserMeResponse.from(currentActiveUser(authorizationHeader));
    }

    @Transactional
    public UserProfileResponse updateProfile(String authorizationHeader, UserProfileUpdateRequest request) {
        User user = currentActiveUser(authorizationHeader);
        NormalizedProfileUpdate normalized = validateAndNormalizeProfileUpdate(request);

        if (request.hasDisplayName()) {
            user.setDisplayName(normalized.displayName());
        }
        if (request.hasContactPhone()) {
            user.setContactPhone(normalized.contactPhone());
        }
        if (request.hasRegion()) {
            user.setRegion(normalized.region());
        }

        return UserProfileResponse.from(user);
    }

    @Transactional
    public UserProfileImageUpdateResponse updateProfileImage(String authorizationHeader, MultipartFile profileImage) {
        User user = currentActiveUser(authorizationHeader);
        storeUserProfileImage(user, profileImage);
        userRepository.flush();
        return UserProfileImageUpdateResponse.from(user);
    }

    @Transactional
    public UserPasswordChangeResponse changePassword(String authorizationHeader, UserPasswordChangeRequest request) {
        if (request == null) {
            throw badRequest("입력값 검증에 실패했습니다.");
        }
        User user = currentActiveUser(authorizationHeader);
        String currentPassword = required(request.currentPassword(), "current_password");
        String newPassword = validateNewPassword(request.newPassword());

        if (!passwordEncoder.matches(currentPassword, user.getPasswordHash())) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "INVALID_CURRENT_PASSWORD", "현재 비밀번호가 올바르지 않습니다.");
        }
        if (passwordEncoder.matches(newPassword, user.getPasswordHash())) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "PASSWORD_REUSE_NOT_ALLOWED", "현재 비밀번호와 동일한 새 비밀번호는 사용할 수 없습니다.");
        }

        user.setPasswordHash(passwordEncoder.encode(newPassword));
        return new UserPasswordChangeResponse(true);
    }

    @Transactional
    public PasswordResetRequestResponse requestPasswordReset(PasswordResetRequest request) {
        if (request == null) {
            throw badRequest("입력값 검증에 실패했습니다.");
        }
        String email = normalizeEmail(request.email());
        User user = userRepository.findByEmail(email).orElse(null);
        String resetToken = null;
        Instant now = Instant.now();

        if (user != null && user.isActive()) {
            passwordResetTokenRepository.markUnusedTokensUsedByUserId(user.getId(), now);
            resetToken = generatePasswordResetToken();

            PasswordResetToken token = new PasswordResetToken();
            token.setUserId(user.getId());
            token.setTokenHash(sha256Hex(resetToken));
            token.setExpiresAt(now.plusSeconds(passwordResetTokenTtlSeconds));
            passwordResetTokenRepository.save(token);
        }

        if (exposePasswordResetTokenInResponse) {
            return PasswordResetRequestResponse.exposed(resetToken, passwordResetTokenTtlSeconds);
        }
        return PasswordResetRequestResponse.hidden();
    }

    @Transactional
    public PasswordResetConfirmResponse confirmPasswordReset(PasswordResetConfirmRequest request) {
        if (request == null) {
            throw badRequest("입력값 검증에 실패했습니다.");
        }
        String resetToken = required(request.resetToken(), "reset_token");
        String newPassword = validateNewPassword(request.newPassword());
        PasswordResetToken storedToken = passwordResetTokenRepository.findByTokenHash(sha256Hex(resetToken))
                .orElseThrow(this::invalidResetToken);

        Instant now = Instant.now();
        if (storedToken.getUsedAt() != null) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "RESET_TOKEN_ALREADY_USED", "이미 사용된 비밀번호 재설정 token입니다.");
        }
        if (!storedToken.getExpiresAt().isAfter(now)) {
            throw new ApiException(HttpStatus.BAD_REQUEST, "RESET_TOKEN_EXPIRED", "만료된 비밀번호 재설정 token입니다.");
        }

        User user = userRepository.findById(storedToken.getUserId())
                .orElseThrow(this::invalidResetToken);
        if (!user.isActive()) {
            throw new ApiException(HttpStatus.FORBIDDEN, "USER_INACTIVE", "비활성화된 사용자입니다.");
        }

        user.setPasswordHash(passwordEncoder.encode(newPassword));
        storedToken.setUsedAt(now);
        passwordResetTokenRepository.markOtherUnusedTokensUsed(user.getId(), storedToken.getId(), now);
        return new PasswordResetConfirmResponse(true);
    }

    @Transactional(readOnly = true)
    public Long currentActiveUserId(String authorizationHeader) {
        return currentActiveUser(authorizationHeader).getId();
    }

    private User currentActiveUser(String authorizationHeader) {
        String token = bearerToken(authorizationHeader);
        Long userId = jwtTokenService.parseUserId(token);
        User user = userRepository.findById(userId)
                .orElseThrow(() -> new ApiException(HttpStatus.NOT_FOUND, "USER_NOT_FOUND", "존재하지 않는 사용자입니다."));
        if (!user.isActive()) {
            throw new ApiException(HttpStatus.FORBIDDEN, "USER_INACTIVE", "비활성화된 사용자입니다.");
        }
        return user;
    }

    private void storeUserProfileImageIfPresent(User user, MultipartFile profileImage) {
        if (profileImage == null) {
            return;
        }
        storeUserProfileImage(user, profileImage);
    }

    private void storeUserProfileImage(User user, MultipartFile profileImage) {
        FileStorageService.StoredFile stored = fileStorageService.storeUserProfileImage(user.getId(), profileImage);
        user.setProfileImagePath(stored.relativePath());
        user.setProfileImageMimeType(stored.mimeType());
        user.setProfileImageFileSize(stored.fileSize());
        user.setProfileImageSha256(stored.sha256());
    }

    private NormalizedProfileUpdate validateAndNormalizeProfileUpdate(UserProfileUpdateRequest request) {
        if (request == null || !request.hasAnyProfileField()) {
            throw validationFailed(
                    "display_name, contact_phone, region 중 최소 1개는 포함되어야 합니다.",
                    List.of("display_name", "contact_phone", "region")
            );
        }

        List<String> fields = new ArrayList<>();
        String displayName = null;
        String contactPhone = null;
        String region = null;

        if (request.hasDisplayName()) {
            displayName = normalizeDisplayNameForProfileUpdate(request.displayName(), fields);
        }
        if (request.hasContactPhone()) {
            contactPhone = normalizeContactPhoneForProfileUpdate(request.contactPhone(), fields);
        }
        if (request.hasRegion()) {
            region = normalizeRegionForProfileUpdate(request.region(), fields);
        }
        if (!fields.isEmpty()) {
            throw validationFailed(validationMessage(fields.get(0)), fields);
        }

        return new NormalizedProfileUpdate(displayName, contactPhone, region);
    }

    private String normalizeDisplayNameForProfileUpdate(String value, List<String> fields) {
        if (value == null) {
            return null;
        }
        String trimmed = value.trim();
        if (!PROFILE_DISPLAY_NAME_PATTERN.matcher(trimmed).matches()) {
            fields.add("display_name");
        }
        return trimmed;
    }

    private String normalizeContactPhoneForProfileUpdate(String value, List<String> fields) {
        if (value == null) {
            return null;
        }
        String trimmed = value.trim();
        if (!PROFILE_CONTACT_PHONE_PATTERN.matcher(trimmed).matches()) {
            fields.add("contact_phone");
        }
        return trimmed;
    }

    private String normalizeRegionForProfileUpdate(String value, List<String> fields) {
        if (value == null) {
            return null;
        }
        String trimmed = value.trim();
        if (trimmed.isBlank() || trimmed.length() > MAX_PROFILE_REGION_LENGTH) {
            fields.add("region");
        }
        return trimmed;
    }

    private String validationMessage(String field) {
        return switch (field) {
            case "display_name" -> "display_name은 공백 없이 한글, 영문, 숫자만 사용해 2자 이상 10자 이하여야 합니다.";
            case "contact_phone" -> "contact_phone은 010으로 시작하는 하이픈 없는 숫자 11자리여야 합니다.";
            case "region" -> "region은 공백만 사용할 수 없고 100자 이하여야 합니다.";
            default -> "입력값 검증에 실패했습니다.";
        };
    }

    private ApiException validationFailed(String message, List<String> fields) {
        return new ApiException(HttpStatus.BAD_REQUEST, "VALIDATION_FAILED", message, Map.of("fields", fields));
    }

    private String bearerToken(String authorizationHeader) {
        if (authorizationHeader == null || authorizationHeader.isBlank()) {
            throw new ApiException(HttpStatus.UNAUTHORIZED, "UNAUTHORIZED", "Authorization Bearer token이 필요합니다.");
        }
        String prefix = "Bearer ";
        if (!authorizationHeader.startsWith(prefix) || authorizationHeader.length() <= prefix.length()) {
            throw new ApiException(HttpStatus.UNAUTHORIZED, "UNAUTHORIZED", "Authorization Bearer token이 필요합니다.");
        }
        return authorizationHeader.substring(prefix.length()).trim();
    }

    private String normalizeEmail(String rawEmail) {
        String email = required(rawEmail, "email").toLowerCase(Locale.ROOT);
        if (email.length() > MAX_EMAIL_LENGTH) {
            throw badRequest("email은 255자 이하여야 합니다.");
        }
        if (!email.contains("@") || email.startsWith("@") || email.endsWith("@")) {
            throw badRequest("올바른 email 형식이 아닙니다.");
        }
        return email;
    }

    private String validateNewPassword(String rawPassword) {
        String password = required(rawPassword, "new_password");
        if (password.length() < MIN_PASSWORD_LENGTH) {
            throw badRequest("new_password는 " + MIN_PASSWORD_LENGTH + "자 이상이어야 합니다.");
        }
        if (password.length() > MAX_PASSWORD_LENGTH) {
            throw badRequest("new_password는 " + MAX_PASSWORD_LENGTH + "자 이하여야 합니다.");
        }
        return password;
    }

    private String required(String value, String fieldName) {
        if (value == null || value.trim().isEmpty()) {
            throw badRequest(fieldName + "은 필수입니다.");
        }
        return value.trim();
    }

    private String optional(String value, int maxLength, String fieldName) {
        if (value == null || value.trim().isEmpty()) {
            return null;
        }
        String trimmed = value.trim();
        if (trimmed.length() > maxLength) {
            throw badRequest(fieldName + "은 " + maxLength + "자 이하여야 합니다.");
        }
        return trimmed;
    }

    private void validateDisplayName(String displayName) {
        if (displayName.length() > MAX_DISPLAY_NAME_LENGTH) {
            throw badRequest("display_name은 " + MAX_DISPLAY_NAME_LENGTH + "자 이하여야 합니다.");
        }
    }

    private void validateContactPhone(String contactPhone) {
        if (contactPhone.length() > MAX_CONTACT_PHONE_LENGTH) {
            throw badRequest("contact_phone은 " + MAX_CONTACT_PHONE_LENGTH + "자 이하여야 합니다.");
        }
        if (!PROFILE_CONTACT_PHONE_PATTERN.matcher(contactPhone).matches()) {
            throw badRequest("contact_phone은 010으로 시작하는 하이픈 없는 숫자 11자리여야 합니다.");
        }
    }

    private void validateRegion(String region, int maxLength) {
        if (region.length() > maxLength) {
            throw badRequest("region은 " + maxLength + "자 이하여야 합니다.");
        }
    }

    private ApiException invalidCredentials() {
        return new ApiException(HttpStatus.UNAUTHORIZED, "INVALID_CREDENTIALS", "email 또는 password가 올바르지 않습니다.");
    }

    private ApiException invalidResetToken() {
        return new ApiException(HttpStatus.BAD_REQUEST, "INVALID_RESET_TOKEN", "유효하지 않은 비밀번호 재설정 token입니다.");
    }

    private String generatePasswordResetToken() {
        byte[] bytes = new byte[PASSWORD_RESET_TOKEN_BYTES];
        secureRandom.nextBytes(bytes);
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    private String sha256Hex(String value) {
        try {
            MessageDigest digest = MessageDigest.getInstance(SHA_256);
            return HexFormat.of().formatHex(digest.digest(value.getBytes(StandardCharsets.UTF_8)));
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 hash 생성에 실패했습니다.", e);
        }
    }

    private ApiException badRequest(String message) {
        return new ApiException(HttpStatus.BAD_REQUEST, "VALIDATION_FAILED", message);
    }

    private record NormalizedProfileUpdate(String displayName, String contactPhone, String region) {
    }
}
