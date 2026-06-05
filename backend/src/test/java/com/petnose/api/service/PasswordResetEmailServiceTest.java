package com.petnose.api.service;

import com.petnose.api.config.PasswordResetEmailProperties;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.mail.MailSendException;
import org.springframework.mail.SimpleMailMessage;
import org.springframework.mail.javamail.JavaMailSender;

import java.time.Instant;
import java.util.UUID;

import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatCode;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.doThrow;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class PasswordResetEmailServiceTest {

    @Mock
    private JavaMailSender mailSender;
    @Mock
    private ObjectProvider<JavaMailSender> mailSenderProvider;

    private PasswordResetEmailProperties properties;
    private PasswordResetEmailService emailService;

    @BeforeEach
    void setUp() {
        properties = new PasswordResetEmailProperties();
        emailService = new PasswordResetEmailService(mailSenderProvider, properties);
    }

    @Test
    void sendPasswordResetEmailAsyncDoesNotSendWhenEmailDisabled() {
        emailService.sendPasswordResetEmailAsync(
                "user@example.com",
                UUID.randomUUID().toString(),
                Instant.parse("2026-06-04T00:00:00Z")
        );

        verify(mailSender, never()).send(any(SimpleMailMessage.class));
    }

    @Test
    void sendPasswordResetEmailAsyncSendsResetLinkWhenEmailEnabled() {
        properties.setEmailEnabled(true);
        properties.setResetUrlTemplate("https://app.example.com/password-reset?token={token}");
        properties.setMailFrom("no-reply@example.com");
        properties.setMailSubject("[PetNose] Reset");
        String resetToken = UUID.randomUUID().toString();
        Instant expiresAt = Instant.parse("2026-06-04T00:30:00Z");
        when(mailSenderProvider.getIfAvailable()).thenReturn(mailSender);

        emailService.sendPasswordResetEmailAsync("user@example.com", resetToken, expiresAt);

        ArgumentCaptor<SimpleMailMessage> messageCaptor = ArgumentCaptor.forClass(SimpleMailMessage.class);
        verify(mailSender).send(messageCaptor.capture());
        SimpleMailMessage message = messageCaptor.getValue();
        assertThat(message.getTo()).containsExactly("user@example.com");
        assertThat(message.getFrom()).isEqualTo("no-reply@example.com");
        assertThat(message.getSubject()).isEqualTo("[PetNose] Reset");
        assertThat(message.getText())
                .contains("https://app.example.com/password-reset?token=" + resetToken)
                .contains(expiresAt.toString())
                .contains("새 비밀번호");
    }

    @Test
    void sendPasswordResetEmailAsyncSkipsTemplateWithoutTokenPlaceholder() {
        properties.setEmailEnabled(true);
        properties.setResetUrlTemplate("https://app.example.com/password-reset");

        assertThatCode(() -> emailService.sendPasswordResetEmailAsync(
                "user@example.com",
                UUID.randomUUID().toString(),
                Instant.parse("2026-06-04T00:00:00Z")
        )).doesNotThrowAnyException();

        verify(mailSender, never()).send(any(SimpleMailMessage.class));
    }

    @Test
    void sendPasswordResetEmailAsyncDoesNotPropagateMailSenderFailure() {
        properties.setEmailEnabled(true);
        when(mailSenderProvider.getIfAvailable()).thenReturn(mailSender);
        doThrow(new MailSendException("smtp unavailable"))
                .when(mailSender)
                .send(any(SimpleMailMessage.class));

        assertThatCode(() -> emailService.sendPasswordResetEmailAsync(
                "user@example.com",
                UUID.randomUUID().toString(),
                Instant.parse("2026-06-04T00:00:00Z")
        )).doesNotThrowAnyException();
    }
}
