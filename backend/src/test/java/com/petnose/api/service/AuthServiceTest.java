package com.petnose.api.service;

import com.petnose.api.config.PasswordResetEmailProperties;
import com.petnose.api.domain.entity.User;
import com.petnose.api.domain.entity.PasswordResetToken;
import com.petnose.api.domain.enums.UserRole;
import com.petnose.api.dto.auth.PasswordResetRequest;
import com.petnose.api.dto.auth.RegisterRequest;
import com.petnose.api.repository.PasswordResetTokenRepository;
import com.petnose.api.repository.UserRepository;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.InOrder;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.mock.web.MockMultipartFile;
import org.springframework.security.crypto.password.PasswordEncoder;
import org.springframework.test.util.ReflectionTestUtils;
import org.springframework.transaction.support.TransactionSynchronization;
import org.springframework.transaction.support.TransactionSynchronizationManager;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.time.Instant;
import java.util.HexFormat;
import java.util.Optional;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.inOrder;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class AuthServiceTest {

    @Mock
    private UserRepository userRepository;
    @Mock
    private PasswordResetTokenRepository passwordResetTokenRepository;
    @Mock
    private PasswordEncoder passwordEncoder;
    @Mock
    private JwtTokenService jwtTokenService;
    @Mock
    private FileStorageService fileStorageService;
    @Mock
    private PasswordResetEmailService passwordResetEmailService;
    @Mock
    private PasswordResetEmailProperties passwordResetEmailProperties;

    @InjectMocks
    private AuthService authService;

    @Test
    void registerWithProfileImageRegistersRollbackCleanup() {
        FileStorageService.StoredFile stored = storedProfileFile(10L);
        when(userRepository.existsByEmail("owner@example.com")).thenReturn(false);
        when(passwordEncoder.encode("password123")).thenReturn("encoded-password");
        when(userRepository.saveAndFlush(any(User.class))).thenAnswer(invocation -> {
            User user = invocation.getArgument(0);
            user.setId(10L);
            return user;
        });
        when(fileStorageService.storeUserProfileImage(eq(10L), any())).thenReturn(stored);

        var response = authService.register(
                new RegisterRequest("Owner@Example.COM", "password123", "Owner", "01012341234", "Seoul"),
                profileImage()
        );

        assertThat(response.userId()).isEqualTo(10L);
        assertThat(response.email()).isEqualTo("owner@example.com");
        assertThat(response.profileImageUrl()).isEqualTo("/files/users/10/profile/avatar.jpg");
        InOrder inOrder = inOrder(fileStorageService);
        inOrder.verify(fileStorageService).storeUserProfileImage(eq(10L), any());
        inOrder.verify(fileStorageService).deleteOnTransactionRollback(stored);
        verify(userRepository).flush();
    }

    @Test
    void updateProfileImageRegistersRollbackCleanup() {
        User user = user(10L);
        FileStorageService.StoredFile stored = storedProfileFile(user.getId());
        when(jwtTokenService.parseUserId("access-token")).thenReturn(user.getId());
        when(userRepository.findById(user.getId())).thenReturn(Optional.of(user));
        when(fileStorageService.storeUserProfileImage(eq(user.getId()), any())).thenReturn(stored);

        var response = authService.updateProfileImage("Bearer access-token", profileImage());

        assertThat(response.userId()).isEqualTo(user.getId());
        assertThat(response.profileImageUrl()).isEqualTo("/files/users/10/profile/avatar.jpg");
        InOrder inOrder = inOrder(fileStorageService);
        inOrder.verify(fileStorageService).storeUserProfileImage(eq(user.getId()), any());
        inOrder.verify(fileStorageService).deleteOnTransactionRollback(stored);
        verify(userRepository).flush();
    }

    @Test
    void requestPasswordResetSchedulesEmailOnlyAfterCommitForActiveUser() throws Exception {
        ReflectionTestUtils.setField(authService, "passwordResetTokenTtlSeconds", 1800L);
        User user = user(10L);
        user.setEmail("reset@example.com");
        when(userRepository.findByEmail("reset@example.com")).thenReturn(Optional.of(user));
        when(passwordResetEmailProperties.isEmailEnabled()).thenReturn(true);
        when(passwordResetTokenRepository.save(any(PasswordResetToken.class)))
                .thenAnswer(invocation -> invocation.getArgument(0));

        TransactionSynchronizationManager.initSynchronization();
        try {
            var response = authService.requestPasswordReset(new PasswordResetRequest("  Reset@Example.COM  "));

            assertThat(response.requested()).isTrue();
            assertThat(response.exposedFields()).isEmpty();
            verify(passwordResetEmailService, never())
                    .sendPasswordResetEmailAsync(anyString(), anyString(), any(Instant.class));

            for (TransactionSynchronization synchronization : TransactionSynchronizationManager.getSynchronizations()) {
                synchronization.afterCommit();
            }
        } finally {
            TransactionSynchronizationManager.clearSynchronization();
        }

        ArgumentCaptor<PasswordResetToken> tokenCaptor = ArgumentCaptor.forClass(PasswordResetToken.class);
        verify(passwordResetTokenRepository).save(tokenCaptor.capture());
        PasswordResetToken storedToken = tokenCaptor.getValue();

        ArgumentCaptor<String> resetTokenCaptor = ArgumentCaptor.forClass(String.class);
        ArgumentCaptor<Instant> expiresAtCaptor = ArgumentCaptor.forClass(Instant.class);
        verify(passwordResetEmailService).sendPasswordResetEmailAsync(
                eq("reset@example.com"),
                resetTokenCaptor.capture(),
                expiresAtCaptor.capture()
        );
        assertThat(storedToken.getTokenHash()).isEqualTo(sha256Hex(resetTokenCaptor.getValue()));
        assertThat(storedToken.getTokenHash()).isNotEqualTo(resetTokenCaptor.getValue());
        assertThat(expiresAtCaptor.getValue()).isEqualTo(storedToken.getExpiresAt());
    }

    @Test
    void requestPasswordResetDoesNotScheduleEmailForUnknownEmail() {
        when(userRepository.findByEmail("unknown@example.com")).thenReturn(Optional.empty());

        var response = authService.requestPasswordReset(new PasswordResetRequest("unknown@example.com"));

        assertThat(response.requested()).isTrue();
        assertThat(response.exposedFields()).isEmpty();
        verify(passwordResetTokenRepository, never()).save(any());
        verifyNoInteractions(passwordResetEmailService);
    }

    @Test
    void requestPasswordResetDoesNotScheduleEmailForInactiveUser() {
        User user = user(10L);
        user.setEmail("inactive@example.com");
        user.setActive(false);
        when(userRepository.findByEmail("inactive@example.com")).thenReturn(Optional.of(user));

        var response = authService.requestPasswordReset(new PasswordResetRequest("inactive@example.com"));

        assertThat(response.requested()).isTrue();
        assertThat(response.exposedFields()).isEmpty();
        verify(passwordResetTokenRepository, never()).save(any());
        verifyNoInteractions(passwordResetEmailService);
    }

    private User user(Long id) {
        User user = new User();
        user.setId(id);
        user.setEmail("owner@example.com");
        user.setPasswordHash("encoded-password");
        user.setRole(UserRole.USER);
        user.setDisplayName("Owner");
        user.setContactPhone("01012341234");
        user.setRegion("Seoul");
        user.setActive(true);
        return user;
    }

    private MockMultipartFile profileImage() {
        return new MockMultipartFile(
                "profile_image",
                "avatar.jpg",
                "image/jpeg",
                new byte[]{1, 2, 3}
        );
    }

    private FileStorageService.StoredFile storedProfileFile(Long userId) {
        return new FileStorageService.StoredFile(
                "users/%d/profile/avatar.jpg".formatted(userId),
                "image/jpeg",
                3L,
                "profile-sha256",
                "avatar.jpg",
                new byte[]{1, 2, 3}
        );
    }

    private String sha256Hex(String value) throws Exception {
        MessageDigest digest = MessageDigest.getInstance("SHA-256");
        return HexFormat.of().formatHex(digest.digest(value.getBytes(StandardCharsets.UTF_8)));
    }
}
