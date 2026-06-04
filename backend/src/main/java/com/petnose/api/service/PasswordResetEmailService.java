package com.petnose.api.service;

import com.petnose.api.config.PasswordResetEmailProperties;
import lombok.RequiredArgsConstructor;
import lombok.extern.slf4j.Slf4j;
import org.springframework.beans.factory.ObjectProvider;
import org.springframework.mail.SimpleMailMessage;
import org.springframework.mail.javamail.JavaMailSender;
import org.springframework.scheduling.annotation.Async;
import org.springframework.stereotype.Service;
import org.springframework.util.StringUtils;

import java.time.Instant;

@Slf4j
@Service
@RequiredArgsConstructor
public class PasswordResetEmailService {

    private static final String TOKEN_PLACEHOLDER = "{token}";

    private final ObjectProvider<JavaMailSender> mailSenderProvider;
    private final PasswordResetEmailProperties properties;

    @Async("mailTaskExecutor")
    public void sendPasswordResetEmailAsync(String toEmail, String rawResetToken, Instant expiresAt) {
        try {
            if (!properties.isEmailEnabled()) {
                log.debug("Password reset email delivery is disabled.");
                return;
            }
            if (!StringUtils.hasText(toEmail) || !StringUtils.hasText(rawResetToken)) {
                log.warn("Password reset email skipped because recipient or token is missing.");
                return;
            }

            String resetUrl = buildResetUrl(rawResetToken);
            if (resetUrl == null) {
                log.warn("Password reset email skipped because reset URL template has no token placeholder.");
                return;
            }
            JavaMailSender mailSender = mailSenderProvider.getIfAvailable();
            if (mailSender == null) {
                log.warn("Password reset email skipped because JavaMailSender is not configured.");
                return;
            }

            SimpleMailMessage message = new SimpleMailMessage();
            message.setTo(toEmail);
            if (StringUtils.hasText(properties.getMailFrom())) {
                message.setFrom(properties.getMailFrom());
            }
            message.setSubject(defaultIfBlank(properties.getMailSubject(), "[PetNose] 비밀번호 재설정 안내"));
            message.setText(emailText(resetUrl, expiresAt));

            mailSender.send(message);
            log.info("Password reset email queued successfully for recipient={}", maskEmail(toEmail));
        } catch (Exception e) {
            log.warn("Password reset email delivery failed for recipient={}: {}", maskEmail(toEmail), e.getMessage());
        }
    }

    private String buildResetUrl(String rawResetToken) {
        String template = properties.getResetUrlTemplate();
        if (!StringUtils.hasText(template) || !template.contains(TOKEN_PLACEHOLDER)) {
            return null;
        }
        return template.replace(TOKEN_PLACEHOLDER, rawResetToken);
    }

    private String emailText(String resetUrl, Instant expiresAt) {
        String expiresAtText = expiresAt == null ? "설정된 만료 시간" : expiresAt.toString();
        return """
                PetNose 비밀번호 재설정을 요청하셨습니다.

                아래 링크에서 새 비밀번호를 설정해 주세요.
                %s

                이 링크는 %s 까지 유효합니다.
                본인이 요청하지 않았다면 이 이메일을 무시해 주세요.
                """.formatted(resetUrl, expiresAtText);
    }

    private String defaultIfBlank(String value, String defaultValue) {
        return StringUtils.hasText(value) ? value : defaultValue;
    }

    private String maskEmail(String email) {
        if (!StringUtils.hasText(email)) {
            return "(empty)";
        }
        int atIndex = email.indexOf('@');
        if (atIndex <= 0 || atIndex == email.length() - 1) {
            return "(invalid-email)";
        }
        String local = email.substring(0, atIndex);
        String domain = email.substring(atIndex + 1);
        String maskedLocal = local.length() == 1 ? "*" : local.charAt(0) + "***";
        return maskedLocal + "@" + domain;
    }
}
