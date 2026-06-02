package com.petnose.api.controller;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.petnose.api.domain.entity.PasswordResetToken;
import com.petnose.api.domain.entity.User;
import com.petnose.api.domain.enums.UserRole;
import com.petnose.api.repository.PasswordResetTokenRepository;
import com.petnose.api.repository.UserRepository;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.MediaType;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.test.web.servlet.ResultActions;
import org.springframework.transaction.annotation.Transactional;

import java.lang.reflect.Field;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.HexFormat;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.not;
import static org.hamcrest.Matchers.nullValue;
import static org.hamcrest.Matchers.isEmptyOrNullString;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest(properties = "auth.password-reset.expose-token-in-response=true")
@AutoConfigureMockMvc
@ActiveProfiles("test")
@Transactional
class PasswordResetApiIntegrationTest {

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private ObjectMapper objectMapper;

    @Autowired
    private UserRepository userRepository;

    @Autowired
    private PasswordResetTokenRepository passwordResetTokenRepository;

    @Autowired
    private PasswordEncoder passwordEncoder;

    @Test
    void passwordResetRequestForExistingEmailExposesDevTokenAndStoresOnlyHash() throws Exception {
        saveUser("reset-existing@example.com", "password123", true);

        MvcResult result = requestPasswordReset("  Reset-Existing@Example.COM  ")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.requested").value(true))
                .andExpect(jsonPath("$.reset_token").value(not(isEmptyOrNullString())))
                .andExpect(jsonPath("$.expires_in").value(1800))
                .andReturn();

        String resetToken = objectMapper.readTree(responseBody(result)).get("reset_token").asText();
        PasswordResetToken stored = passwordResetTokenRepository.findAll().getFirst();
        Set<String> tokenFields = Set.of(PasswordResetToken.class.getDeclaredFields()).stream()
                .map(Field::getName)
                .collect(Collectors.toSet());

        assertThat(stored.getTokenHash()).hasSize(64);
        assertThat(stored.getTokenHash()).isNotEqualTo(resetToken);
        assertThat(stored.getTokenHash()).isEqualTo(sha256Hex(resetToken));
        assertThat(stored.getExpiresAt()).isAfter(Instant.now());
        assertThat(stored.getUsedAt()).isNull();
        assertThat(tokenFields).doesNotContain("resetToken", "rawToken", "plainToken");
    }

    @Test
    void passwordResetRequestForUnknownEmailDoesNotIssueToken() throws Exception {
        requestPasswordReset("unknown-reset@example.com")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.requested").value(true))
                .andExpect(jsonPath("$.reset_token").value(nullValue()))
                .andExpect(jsonPath("$.expires_in").value(1800));

        assertThat(passwordResetTokenRepository.findAll()).isEmpty();
    }

    @Test
    void passwordResetConfirmSuccessChangesPasswordAndMarksTokenUsed() throws Exception {
        saveUser("reset-confirm@example.com", "password123", true);
        String resetToken = exposedResetToken("reset-confirm@example.com");
        Long tokenId = passwordResetTokenRepository.findAll().getFirst().getId();

        mockMvc.perform(post("/api/auth/password-reset/confirm")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "reset_token", resetToken,
                                "new_password", "new-password123"
                        ))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.reset").value(true))
                .andExpect(jsonPath("$.password").doesNotExist())
                .andExpect(jsonPath("$.password_hash").doesNotExist());

        mockMvc.perform(post("/api/auth/login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "email", "reset-confirm@example.com",
                                "password", "password123"
                        ))))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("INVALID_CREDENTIALS"));

        mockMvc.perform(post("/api/auth/login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "email", "reset-confirm@example.com",
                                "password", "new-password123"
                        ))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.access_token").value(not(isEmptyOrNullString())));

        PasswordResetToken usedToken = passwordResetTokenRepository.findById(tokenId).orElseThrow();
        assertThat(usedToken.getUsedAt()).isNotNull();
    }

    @Test
    void passwordResetTokenReuseFails() throws Exception {
        saveUser("reset-reuse@example.com", "password123", true);
        String resetToken = exposedResetToken("reset-reuse@example.com");

        mockMvc.perform(post("/api/auth/password-reset/confirm")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "reset_token", resetToken,
                                "new_password", "new-password123"
                        ))))
                .andExpect(status().isOk());

        mockMvc.perform(post("/api/auth/password-reset/confirm")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "reset_token", resetToken,
                                "new_password", "another-password123"
                        ))))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("RESET_TOKEN_ALREADY_USED"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void expiredPasswordResetTokenFails() throws Exception {
        saveUser("reset-expired@example.com", "password123", true);
        String resetToken = exposedResetToken("reset-expired@example.com");
        PasswordResetToken stored = passwordResetTokenRepository.findAll().getFirst();
        stored.setExpiresAt(Instant.now().minusSeconds(1));
        passwordResetTokenRepository.saveAndFlush(stored);

        mockMvc.perform(post("/api/auth/password-reset/confirm")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "reset_token", resetToken,
                                "new_password", "new-password123"
                        ))))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("RESET_TOKEN_EXPIRED"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void invalidPasswordResetTokenFails() throws Exception {
        mockMvc.perform(post("/api/auth/password-reset/confirm")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "reset_token", "invalid-reset-token",
                                "new_password", "new-password123"
                        ))))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("INVALID_RESET_TOKEN"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void inactiveUserResetRequestDoesNotIssueTokenAndInactiveConfirmFails() throws Exception {
        User inactive = saveUser("reset-inactive@example.com", "password123", false);

        requestPasswordReset("reset-inactive@example.com")
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.requested").value(true))
                .andExpect(jsonPath("$.reset_token").value(nullValue()));
        assertThat(passwordResetTokenRepository.findAll()).isEmpty();

        PasswordResetToken token = new PasswordResetToken();
        token.setUserId(inactive.getId());
        token.setTokenHash(sha256Hex("inactive-reset-token"));
        token.setExpiresAt(Instant.now().plusSeconds(1800));
        passwordResetTokenRepository.saveAndFlush(token);

        mockMvc.perform(post("/api/auth/password-reset/confirm")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "reset_token", "inactive-reset-token",
                                "new_password", "new-password123"
                        ))))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.error_code").value("USER_INACTIVE"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    private ResultActions requestPasswordReset(String email) throws Exception {
        return mockMvc.perform(post("/api/auth/password-reset/request")
                .contentType(MediaType.APPLICATION_JSON)
                .content(json(Map.of("email", email))));
    }

    private String exposedResetToken(String email) throws Exception {
        MvcResult result = requestPasswordReset(email)
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.reset_token").value(not(isEmptyOrNullString())))
                .andReturn();
        return objectMapper.readTree(responseBody(result)).get("reset_token").asText();
    }

    private User saveUser(String email, String password, boolean active) {
        User user = new User();
        user.setEmail(email);
        user.setPasswordHash(passwordEncoder.encode(password));
        user.setRole(UserRole.USER);
        user.setActive(active);
        return userRepository.saveAndFlush(user);
    }

    private String sha256Hex(String value) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        return HexFormat.of().formatHex(digest.digest(value.getBytes(StandardCharsets.UTF_8)));
    }

    private String responseBody(MvcResult result) {
        return new String(result.getResponse().getContentAsByteArray(), StandardCharsets.UTF_8);
    }

    private String json(Object value) throws Exception {
        return objectMapper.writeValueAsString(value);
    }
}
