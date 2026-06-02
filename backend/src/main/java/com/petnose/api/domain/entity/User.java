package com.petnose.api.domain.entity;

import com.petnose.api.domain.enums.UserRole;
import jakarta.persistence.*;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.Instant;

@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "users")
public class User {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(nullable = false, unique = true, length = 255)
    private String email;

    @Column(name = "password_hash", nullable = false, length = 255)
    private String passwordHash;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    private UserRole role = UserRole.USER;

    @Column(name = "display_name", length = 150)
    private String displayName;

    @Column(name = "contact_phone", length = 30)
    private String contactPhone;

    @Column(length = 100)
    private String region;

    @Column(name = "profile_image_path", length = 500)
    private String profileImagePath;

    @Column(name = "profile_image_mime_type", length = 100)
    private String profileImageMimeType;

    @Column(name = "profile_image_file_size")
    private Long profileImageFileSize;

    @Column(name = "profile_image_sha256", length = 64)
    private String profileImageSha256;

    @Column(name = "is_active", nullable = false)
    private boolean active = true;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @PrePersist
    public void prePersist() {
        this.createdAt = Instant.now();
    }
}
