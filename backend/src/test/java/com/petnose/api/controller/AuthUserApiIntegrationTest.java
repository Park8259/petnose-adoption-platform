package com.petnose.api.controller;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.petnose.api.domain.entity.User;
import com.petnose.api.domain.enums.UserRole;
import com.petnose.api.repository.UserRepository;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.autoconfigure.web.servlet.AutoConfigureMockMvc;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.http.HttpHeaders;
import org.springframework.http.MediaType;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.context.ActiveProfiles;
import org.springframework.test.web.servlet.MockMvc;
import org.springframework.test.web.servlet.MvcResult;
import org.springframework.transaction.annotation.Transactional;

import javax.crypto.Mac;
import javax.crypto.spec.SecretKeySpec;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import static org.assertj.core.api.Assertions.assertThat;
import static org.hamcrest.Matchers.isEmptyOrNullString;
import static org.hamcrest.Matchers.not;
import static org.hamcrest.Matchers.nullValue;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.get;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.patch;
import static org.springframework.test.web.servlet.request.MockMvcRequestBuilders.post;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.jsonPath;
import static org.springframework.test.web.servlet.result.MockMvcResultMatchers.status;

@SpringBootTest
@AutoConfigureMockMvc
@ActiveProfiles("test")
@Transactional
class AuthUserApiIntegrationTest {

    private static final String TEST_JWT_SECRET = "test-petnose-jwt-secret-change-me-32bytes";

    @Autowired
    private MockMvc mockMvc;

    @Autowired
    private ObjectMapper objectMapper;

    @Autowired
    private UserRepository userRepository;

    @Autowired
    private PasswordEncoder passwordEncoder;

    @Test
    void registerReturnsUserRoleAndStoresPasswordHash() throws Exception {
        mockMvc.perform(post("/api/auth/register")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "email", "Owner@Example.COM",
                                "password", "password123",
                                "display_name", "Bori Owner",
                                "contact_phone", "01012341234",
                                "region", "Seoul"
                        ))))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.user_id").exists())
                .andExpect(jsonPath("$.email").value("owner@example.com"))
                .andExpect(jsonPath("$.role").value("USER"))
                .andExpect(jsonPath("$.display_name").value("Bori Owner"))
                .andExpect(jsonPath("$.contact_phone").value("01012341234"))
                .andExpect(jsonPath("$.region").value("Seoul"))
                .andExpect(jsonPath("$.profile_image_url").value(nullValue()))
                .andExpect(jsonPath("$.is_active").value(true));

        User saved = userRepository.findByEmail("owner@example.com").orElseThrow();
        assertThat(saved.getRole()).isEqualTo(UserRole.USER);
        assertThat(saved.getPasswordHash()).isNotEqualTo("password123");
        assertThat(saved.getPasswordHash()).startsWith("$2");
        assertThat(passwordEncoder.matches("password123", saved.getPasswordHash())).isTrue();
    }

    @Test
    void loginReturnsAccessTokenAndMeReturnsCurrentUser() throws Exception {
        register("me@example.com", "password123", "Me User", "01011112222", "Busan");

        MvcResult loginResult = mockMvc.perform(post("/api/auth/login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "email", "me@example.com",
                                "password", "password123"
                        ))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.access_token").value(not(isEmptyOrNullString())))
                .andExpect(jsonPath("$.token_type").value("Bearer"))
                .andExpect(jsonPath("$.expires_in").value(3600))
                .andExpect(jsonPath("$.user.user_id").exists())
                .andExpect(jsonPath("$.user.email").value("me@example.com"))
                .andExpect(jsonPath("$.user.role").value("USER"))
                .andExpect(jsonPath("$.user.display_name").value("Me User"))
                .andExpect(jsonPath("$.user.contact_phone").value("01011112222"))
                .andExpect(jsonPath("$.user.profile_image_url").value(nullValue()))
                .andExpect(jsonPath("$.user.is_active").value(true))
                .andReturn();

        JsonNode loginBody = objectMapper.readTree(responseBody(loginResult));
        String accessToken = loginBody.get("access_token").asText();

        mockMvc.perform(get("/api/users/me")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.user_id").value(loginBody.get("user").get("user_id").asLong()))
                .andExpect(jsonPath("$.email").value("me@example.com"))
                .andExpect(jsonPath("$.role").value("USER"))
                .andExpect(jsonPath("$.display_name").value("Me User"))
                .andExpect(jsonPath("$.contact_phone").value("01011112222"))
                .andExpect(jsonPath("$.region").value("Busan"))
                .andExpect(jsonPath("$.profile_image_url").value(nullValue()))
                .andExpect(jsonPath("$.is_active").value(true));
    }

    @Test
    void meReturnsRequiredProfileFieldKeysForFlutterFlow() throws Exception {
        register("me-profile@example.com", "password123", "Profile User", "01012341234", "Seoul");
        String accessToken = loginAccessToken("me-profile@example.com", "password123");

        MvcResult result = mockMvc.perform(get("/api/users/me")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.user_id").exists())
                .andExpect(jsonPath("$.email").value("me-profile@example.com"))
                .andExpect(jsonPath("$.role").value("USER"))
                .andExpect(jsonPath("$.display_name").value("Profile User"))
                .andExpect(jsonPath("$.contact_phone").value("01012341234"))
                .andExpect(jsonPath("$.region").value("Seoul"))
                .andExpect(jsonPath("$.profile_image_url").value(nullValue()))
                .andExpect(jsonPath("$.is_active").value(true))
                .andExpect(jsonPath("$.created_at").doesNotExist())
                .andReturn();

        JsonNode body = objectMapper.readTree(responseBody(result));
        assertThat(body.fieldNames())
                .toIterable()
                .containsExactly("user_id", "email", "role", "display_name", "contact_phone", "region", "profile_image_url", "is_active");
    }

    @Test
    void meReturnsProfileImageUrlWhenStoredPathExists() throws Exception {
        User user = saveUser("profile-image-me@example.com", "password123", true);
        user.setProfileImagePath("users\\%d\\profile\\avatar.jpg".formatted(user.getId()));
        userRepository.saveAndFlush(user);
        String accessToken = signedToken(user.getId(), Instant.now().plusSeconds(3600).getEpochSecond());

        mockMvc.perform(get("/api/users/me")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.profile_image_url").value("/files/users/%d/profile/avatar.jpg".formatted(user.getId())))
                .andExpect(jsonPath("$.password_hash").doesNotExist());
    }

    @Test
    void registerMissingEmailReturnsValidationFailed() throws Exception {
        mockMvc.perform(post("/api/auth/register")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of("password", "password123"))))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("VALIDATION_FAILED"))
                .andExpect(jsonPath("$.message").exists())
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void registerBlankPasswordReturnsValidationFailed() throws Exception {
        Map<String, String> body = new LinkedHashMap<>();
        body.put("email", "blank-password@example.com");
        body.put("password", " ");

        mockMvc.perform(post("/api/auth/register")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(body)))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("VALIDATION_FAILED"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void registerMalformedJsonReturnsValidationFailed() throws Exception {
        mockMvc.perform(post("/api/auth/register")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content("{"))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("VALIDATION_FAILED"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void registerDuplicateEmailReturnsEmailAlreadyExists() throws Exception {
        register("duplicate@example.com", "password123", "Duplicate", "01012341234", "Seoul");

        mockMvc.perform(post("/api/auth/register")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "email", "duplicate@example.com",
                                "password", "password123",
                                "display_name", "Duplicate",
                                "contact_phone", "01012341234",
                                "region", "Seoul"
                        ))))
                .andExpect(status().isConflict())
                .andExpect(jsonPath("$.error_code").value("EMAIL_ALREADY_EXISTS"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void registerIgnoresRoleInPublicSignupAndAlwaysStoresUser() throws Exception {
        mockMvc.perform(post("/api/auth/register")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "email", "role-ignore@example.com",
                                "password", "password123",
                                "display_name", "RoleIgnore",
                                "contact_phone", "01012341234",
                                "region", "Seoul",
                                "role", "ADMIN"
                        ))))
                .andExpect(status().isCreated())
                .andExpect(jsonPath("$.role").value("USER"));

        User saved = userRepository.findByEmail("role-ignore@example.com").orElseThrow();
        assertThat(saved.getRole()).isEqualTo(UserRole.USER);
    }

    @Test
    void loginWrongPasswordReturnsInvalidCredentials() throws Exception {
        register("wrong-password@example.com", "password123", "Wrong Password", null, null);

        mockMvc.perform(post("/api/auth/login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "email", "wrong-password@example.com",
                                "password", "wrong-password"
                        ))))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("INVALID_CREDENTIALS"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void loginUnknownEmailReturnsInvalidCredentials() throws Exception {
        mockMvc.perform(post("/api/auth/login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "email", "unknown@example.com",
                                "password", "password123"
                        ))))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("INVALID_CREDENTIALS"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void loginInactiveUserReturnsUserInactive() throws Exception {
        saveUser("inactive-login@example.com", "password123", false);

        mockMvc.perform(post("/api/auth/login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "email", "inactive-login@example.com",
                                "password", "password123"
                        ))))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.error_code").value("USER_INACTIVE"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void registerMissingDisplayNameReturnsValidationFailed() throws Exception {
        mockMvc.perform(post("/api/auth/register")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "email", "missing-display@example.com",
                                "password", "password123",
                                "contact_phone", "01012341234",
                                "region", "Seoul"
                        ))))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("VALIDATION_FAILED"));
    }

    @Test
    void registerMissingContactPhoneReturnsValidationFailed() throws Exception {
        mockMvc.perform(post("/api/auth/register")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "email", "missing-phone@example.com",
                                "password", "password123",
                                "display_name", "PhoneUser",
                                "region", "Seoul"
                        ))))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("VALIDATION_FAILED"));
    }

    @Test
    void registerRejectsInvalidContactPhoneFormats() throws Exception {
        List<String> invalidPhones = List.of(
                "010" + "-" + "1234" + "-" + "5678",
                "01112345678",
                "0101234567",
                "010123456789"
        );

        for (String phone : invalidPhones) {
            mockMvc.perform(post("/api/auth/register")
                            .contentType(MediaType.APPLICATION_JSON)
                            .content(json(Map.of(
                                    "email", "invalid-phone-%d@example.com".formatted(phone.hashCode()),
                                    "password", "password123",
                                    "display_name", "PhoneUser",
                                    "contact_phone", phone,
                                    "region", "Seoul"
                            ))))
                    .andExpect(status().isBadRequest())
                    .andExpect(jsonPath("$.error_code").value("VALIDATION_FAILED"));
        }
    }

    @Test
    void registerMissingRegionReturnsValidationFailed() throws Exception {
        mockMvc.perform(post("/api/auth/register")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "email", "missing-region@example.com",
                                "password", "password123",
                                "display_name", "RegionUser",
                                "contact_phone", "01012341234"
                        ))))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("VALIDATION_FAILED"));
    }

    @Test
    void meRequiresBearerToken() throws Exception {
        mockMvc.perform(get("/api/users/me"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void meRejectsMalformedBearerHeader() throws Exception {
        mockMvc.perform(get("/api/users/me")
                        .header(HttpHeaders.AUTHORIZATION, "Token abc"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void meRejectsInvalidToken() throws Exception {
        mockMvc.perform(get("/api/users/me")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer invalid-token"))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void meRejectsExpiredToken() throws Exception {
        User user = saveUser("expired@example.com", "password123", true);
        String expiredToken = signedToken(user.getId(), Instant.now().minusSeconds(60).getEpochSecond());

        mockMvc.perform(get("/api/users/me")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + expiredToken))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void meReturnsUserNotFoundWhenTokenSubjectUserDoesNotExist() throws Exception {
        String token = signedToken(999999L, Instant.now().plusSeconds(3600).getEpochSecond());

        mockMvc.perform(get("/api/users/me")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + token))
                .andExpect(status().isNotFound())
                .andExpect(jsonPath("$.error_code").value("USER_NOT_FOUND"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void meRejectsInactiveUserWithValidToken() throws Exception {
        register("inactive-me@example.com", "password123", "Inactive Me", null, null);
        String accessToken = loginAccessToken("inactive-me@example.com", "password123");

        User user = userRepository.findByEmail("inactive-me@example.com").orElseThrow();
        user.setActive(false);
        userRepository.saveAndFlush(user);

        mockMvc.perform(get("/api/users/me")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.error_code").value("USER_INACTIVE"))
                .andExpect(jsonPath("$.password_hash").doesNotExist())
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void profilePatchTrimsPersistsAndMeReflectsUpdatedProfile() throws Exception {
        register("profile@example.com", "password123", "Old Name", "01012341234", "Old Region");
        String accessToken = loginAccessToken("profile@example.com", "password123");

        MvcResult patchResult = mockMvc.perform(patch("/api/users/me/profile")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "display_name", "  행복임보자  ",
                                "contact_phone", "  01012345678  ",
                                "region", "  대구시 달서구  "
                        ))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.user_id").exists())
                .andExpect(jsonPath("$.display_name").value("행복임보자"))
                .andExpect(jsonPath("$.contact_phone").value("01012345678"))
                .andExpect(jsonPath("$.region").value("대구시 달서구"))
                .andExpect(jsonPath("$.profile_image_url").value(nullValue()))
                .andExpect(jsonPath("$.email").doesNotExist())
                .andExpect(jsonPath("$.role").doesNotExist())
                .andExpect(jsonPath("$.is_active").doesNotExist())
                .andReturn();

        JsonNode patchBody = objectMapper.readTree(responseBody(patchResult));
        assertThat(patchBody.fieldNames())
                .toIterable()
                .containsExactly("user_id", "display_name", "contact_phone", "region", "profile_image_url");

        User saved = userRepository.findByEmail("profile@example.com").orElseThrow();
        assertThat(saved.getDisplayName()).isEqualTo("행복임보자");
        assertThat(saved.getContactPhone()).isEqualTo("01012345678");
        assertThat(saved.getRegion()).isEqualTo("대구시 달서구");

        mockMvc.perform(get("/api/users/me")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.display_name").value("행복임보자"))
                .andExpect(jsonPath("$.contact_phone").value("01012345678"))
                .andExpect(jsonPath("$.region").value("대구시 달서구"));
    }

    @Test
    void profilePatchAcceptsDisplayNameBoundariesAndAllowedCharacters() throws Exception {
        register("profile-display-valid@example.com", "password123", "Name", null, null);
        String accessToken = loginAccessToken("profile-display-valid@example.com", "password123");
        List<String> validDisplayNames = List.of("초코", "User123", "가나다라마바사아자차");

        for (String displayName : validDisplayNames) {
            mockMvc.perform(patch("/api/users/me/profile")
                            .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                            .contentType(MediaType.APPLICATION_JSON)
                            .content(json(Map.of("display_name", displayName))))
                    .andExpect(status().isOk())
                    .andExpect(jsonPath("$.display_name").value(displayName));
        }

        User saved = userRepository.findByEmail("profile-display-valid@example.com").orElseThrow();
        assertThat(saved.getDisplayName()).isEqualTo("가나다라마바사아자차");
    }

    @Test
    void profilePatchRejectsInvalidDisplayNames() throws Exception {
        register("profile-display-invalid@example.com", "password123", "Name", null, null);
        String accessToken = loginAccessToken("profile-display-invalid@example.com", "password123");
        List<String> invalidDisplayNames = List.of(
                "A",
                "a".repeat(11),
                "초코 보호자",
                "   ",
                "초코!",
                "user_1",
                "초코🐶",
                "초코\n보호",
                "초코\t보호"
        );

        for (String displayName : invalidDisplayNames) {
            assertProfilePatchValidationFailed(accessToken, "display_name", displayName);
        }
    }

    @Test
    void profilePatchAcceptsContactPhoneDigitsAndTrims() throws Exception {
        register("profile-phone-valid@example.com", "password123", "Name", null, null);
        String accessToken = loginAccessToken("profile-phone-valid@example.com", "password123");

        mockMvc.perform(patch("/api/users/me/profile")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of("contact_phone", "01012345678"))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.contact_phone").value("01012345678"));

        mockMvc.perform(patch("/api/users/me/profile")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of("contact_phone", "  01012345678  "))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.contact_phone").value("01012345678"));

        User saved = userRepository.findByEmail("profile-phone-valid@example.com").orElseThrow();
        assertThat(saved.getContactPhone()).isEqualTo("01012345678");
    }

    @Test
    void profilePatchRejectsInvalidContactPhones() throws Exception {
        register("profile-phone-invalid@example.com", "password123", "Name", null, null);
        String accessToken = loginAccessToken("profile-phone-invalid@example.com", "password123");
        List<String> invalidContactPhones = List.of(
                "0101234567",
                "010123456789",
                "010" + "-" + "1234" + "-" + "5678",
                "010 1234 5678",
                "+821012345678",
                "(010)12345678",
                "010abcd5678",
                "   "
        );

        for (String contactPhone : invalidContactPhones) {
            assertProfilePatchValidationFailed(accessToken, "contact_phone", contactPhone);
        }
    }

    @Test
    void profilePatchAcceptsRegionTrimAndRejectsBlankOrTooLong() throws Exception {
        register("profile-region@example.com", "password123", "Name", null, null);
        String accessToken = loginAccessToken("profile-region@example.com", "password123");

        mockMvc.perform(patch("/api/users/me/profile")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of("region", "  대구시 달서구  "))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.region").value("대구시 달서구"));

        User saved = userRepository.findByEmail("profile-region@example.com").orElseThrow();
        assertThat(saved.getRegion()).isEqualTo("대구시 달서구");

        assertProfilePatchValidationFailed(accessToken, "region", "   ");
        assertProfilePatchValidationFailed(accessToken, "region", "r".repeat(101));
    }

    @Test
    void profilePatchRequiresAuthentication() throws Exception {
        mockMvc.perform(patch("/api/users/me/profile")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of("display_name", "NoToken"))))
                .andExpect(status().isUnauthorized())
                .andExpect(jsonPath("$.error_code").value("UNAUTHORIZED"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void profilePatchRejectsInactiveUserWithValidToken() throws Exception {
        register("inactive-profile@example.com", "password123", "Inactive Profile", null, null);
        String accessToken = loginAccessToken("inactive-profile@example.com", "password123");

        User user = userRepository.findByEmail("inactive-profile@example.com").orElseThrow();
        user.setActive(false);
        userRepository.saveAndFlush(user);

        mockMvc.perform(patch("/api/users/me/profile")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of("display_name", "ShouldNot"))))
                .andExpect(status().isForbidden())
                .andExpect(jsonPath("$.error_code").value("USER_INACTIVE"))
                .andExpect(jsonPath("$.details").value(nullValue()));
    }

    @Test
    void profilePatchPartialUpdateKeepsOmittedFields() throws Exception {
        register("partial-profile@example.com", "password123", "Partial Name", "01011112222", "Busan");
        String accessToken = loginAccessToken("partial-profile@example.com", "password123");

        mockMvc.perform(patch("/api/users/me/profile")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of("region", "Jeju"))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.display_name").value("Partial Name"))
                .andExpect(jsonPath("$.contact_phone").value("01011112222"))
                .andExpect(jsonPath("$.region").value("Jeju"));

        mockMvc.perform(patch("/api/users/me/profile")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of("display_name", "SafeName"))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.display_name").value("SafeName"))
                .andExpect(jsonPath("$.contact_phone").value("01011112222"))
                .andExpect(jsonPath("$.region").value("Jeju"));

        mockMvc.perform(patch("/api/users/me/profile")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of("contact_phone", "01012345678"))))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.display_name").value("SafeName"))
                .andExpect(jsonPath("$.contact_phone").value("01012345678"))
                .andExpect(jsonPath("$.region").value("Jeju"));

        User saved = userRepository.findByEmail("partial-profile@example.com").orElseThrow();
        assertThat(saved.getDisplayName()).isEqualTo("SafeName");
        assertThat(saved.getContactPhone()).isEqualTo("01012345678");
        assertThat(saved.getRegion()).isEqualTo("Jeju");
    }

    @Test
    void profilePatchExplicitNullStoresNull() throws Exception {
        register("null-profile@example.com", "password123", "Nullable Name", "01011112222", "Daegu");
        String accessToken = loginAccessToken("null-profile@example.com", "password123");
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("display_name", null);

        MvcResult patchResult = mockMvc.perform(patch("/api/users/me/profile")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(body)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.contact_phone").value("01011112222"))
                .andExpect(jsonPath("$.region").value("Daegu"))
                .andReturn();

        JsonNode patchBody = objectMapper.readTree(responseBody(patchResult));
        assertThat(patchBody.has("display_name")).isTrue();
        assertThat(patchBody.get("display_name").isNull()).isTrue();

        User saved = userRepository.findByEmail("null-profile@example.com").orElseThrow();
        assertThat(saved.getDisplayName()).isNull();

        Map<String, Object> contactAndRegionBody = new LinkedHashMap<>();
        contactAndRegionBody.put("contact_phone", null);
        contactAndRegionBody.put("region", null);

        MvcResult secondPatchResult = mockMvc.perform(patch("/api/users/me/profile")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(contactAndRegionBody)))
                .andExpect(status().isOk())
                .andReturn();

        JsonNode secondPatchBody = objectMapper.readTree(responseBody(secondPatchResult));
        assertThat(secondPatchBody.get("display_name").isNull()).isTrue();
        assertThat(secondPatchBody.get("contact_phone").isNull()).isTrue();
        assertThat(secondPatchBody.get("region").isNull()).isTrue();

        User nullCleared = userRepository.findByEmail("null-profile@example.com").orElseThrow();
        assertThat(nullCleared.getDisplayName()).isNull();
        assertThat(nullCleared.getContactPhone()).isNull();
        assertThat(nullCleared.getRegion()).isNull();
    }

    @Test
    void profilePatchRequiresAtLeastOneProfileField() throws Exception {
        register("empty-profile@example.com", "password123", "Name", null, null);
        String accessToken = loginAccessToken("empty-profile@example.com", "password123");

        mockMvc.perform(patch("/api/users/me/profile")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of())))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("VALIDATION_FAILED"))
                .andExpect(jsonPath("$.details.fields[0]").value("display_name"))
                .andExpect(jsonPath("$.details.fields[1]").value("contact_phone"))
                .andExpect(jsonPath("$.details.fields[2]").value("region"))
                .andExpect(jsonPath("$.details.timestamp").doesNotExist());
    }

    @Test
    void profilePatchRejectsUnknownFieldsOnly() throws Exception {
        register("unknown-profile@example.com", "password123", "Name", null, null);
        String accessToken = loginAccessToken("unknown-profile@example.com", "password123");

        mockMvc.perform(patch("/api/users/me/profile")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of("role", "ADMIN"))))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("VALIDATION_FAILED"))
                .andExpect(jsonPath("$.details.fields[0]").value("display_name"))
                .andExpect(jsonPath("$.details.fields[1]").value("contact_phone"))
                .andExpect(jsonPath("$.details.fields[2]").value("region"));
    }

    @Test
    void profilePatchIgnoresMassAssignmentFields() throws Exception {
        register("mass-assignment@example.com", "password123", "OldName", "01011112222", "Daegu");
        String accessToken = loginAccessToken("mass-assignment@example.com", "password123");
        User before = userRepository.findByEmail("mass-assignment@example.com").orElseThrow();
        String originalPasswordHash = before.getPasswordHash();

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("display_name", "SafeName");
        body.put("role", "ADMIN");
        body.put("email", "attacker@example.com");
        body.put("is_active", false);
        body.put("password_hash", "hack");

        mockMvc.perform(patch("/api/users/me/profile")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(body)))
                .andExpect(status().isOk())
                .andExpect(jsonPath("$.display_name").value("SafeName"))
                .andExpect(jsonPath("$.email").doesNotExist())
                .andExpect(jsonPath("$.role").doesNotExist())
                .andExpect(jsonPath("$.is_active").doesNotExist())
                .andExpect(jsonPath("$.password_hash").doesNotExist());

        User after = userRepository.findByEmail("mass-assignment@example.com").orElseThrow();
        assertThat(after.getRole()).isEqualTo(UserRole.USER);
        assertThat(after.getEmail()).isEqualTo("mass-assignment@example.com");
        assertThat(after.isActive()).isTrue();
        assertThat(after.getPasswordHash()).isEqualTo(originalPasswordHash);
        assertThat(after.getDisplayName()).isEqualTo("SafeName");
        assertThat(userRepository.findByEmail("attacker@example.com")).isEmpty();
    }

    private void register(String email, String password, String displayName, String contactPhone, String region) throws Exception {
        Map<String, String> body = new LinkedHashMap<>();
        body.put("email", email);
        body.put("password", password);
        body.put("display_name", displayName == null ? "DefaultUser" : displayName);
        body.put("contact_phone", contactPhone == null ? "01012341234" : contactPhone);
        body.put("region", region == null ? "Seoul" : region);

        mockMvc.perform(post("/api/auth/register")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(body)))
                .andExpect(status().isCreated());
    }

    private String loginAccessToken(String email, String password) throws Exception {
        MvcResult result = mockMvc.perform(post("/api/auth/login")
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(Map.of(
                                "email", email,
                                "password", password
                        ))))
                .andExpect(status().isOk())
                .andReturn();

        return objectMapper.readTree(responseBody(result))
                .get("access_token")
                .asText();
    }

    private User saveUser(String email, String password, boolean active) {
        User user = new User();
        user.setEmail(email);
        user.setPasswordHash(passwordEncoder.encode(password));
        user.setRole(UserRole.USER);
        user.setActive(active);
        return userRepository.saveAndFlush(user);
    }

    private void assertProfilePatchValidationFailed(String accessToken, String field, String value) throws Exception {
        Map<String, Object> body = new LinkedHashMap<>();
        body.put(field, value);

        mockMvc.perform(patch("/api/users/me/profile")
                        .header(HttpHeaders.AUTHORIZATION, "Bearer " + accessToken)
                        .contentType(MediaType.APPLICATION_JSON)
                        .content(json(body)))
                .andExpect(status().isBadRequest())
                .andExpect(jsonPath("$.error_code").value("VALIDATION_FAILED"))
                .andExpect(jsonPath("$.details.fields[0]").value(field))
                .andExpect(jsonPath("$.details.timestamp").doesNotExist());
    }

    private String signedToken(Long userId, long expiresAt) throws Exception {
        String header = base64Url(json(Map.of("alg", "HS256", "typ", "JWT")).getBytes(StandardCharsets.UTF_8));
        String payload = base64Url(json(Map.of(
                "sub", userId.toString(),
                "email", "token-user@example.com",
                "role", "USER",
                "iat", Instant.now().getEpochSecond(),
                "exp", expiresAt
        )).getBytes(StandardCharsets.UTF_8));
        String signingInput = header + "." + payload;
        Mac mac = Mac.getInstance("HmacSHA256");
        mac.init(new SecretKeySpec(TEST_JWT_SECRET.getBytes(StandardCharsets.UTF_8), "HmacSHA256"));
        return signingInput + "." + base64Url(mac.doFinal(signingInput.getBytes(StandardCharsets.UTF_8)));
    }

    private String base64Url(byte[] bytes) {
        return Base64.getUrlEncoder().withoutPadding().encodeToString(bytes);
    }

    private String responseBody(MvcResult result) {
        return new String(result.getResponse().getContentAsByteArray(), StandardCharsets.UTF_8);
    }

    private String json(Object value) throws Exception {
        return objectMapper.writeValueAsString(value);
    }
}
