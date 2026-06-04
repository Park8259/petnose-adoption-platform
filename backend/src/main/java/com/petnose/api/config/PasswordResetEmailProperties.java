package com.petnose.api.config;

import lombok.Getter;
import lombok.Setter;
import org.springframework.boot.context.properties.ConfigurationProperties;

@Getter
@Setter
@ConfigurationProperties(prefix = "auth.password-reset")
public class PasswordResetEmailProperties {

    private boolean emailEnabled = false;
    private String resetUrlTemplate = "http://localhost:3000/password-reset?token={token}";
    private String mailFrom = "no-reply@petnose.local";
    private String mailSubject = "[PetNose] 비밀번호 재설정 안내";
}
