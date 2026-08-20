package com.petnose.api.domain.entity;

import com.petnose.api.domain.enums.AdoptionPostStatus;
import jakarta.persistence.*;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.LocalDateTime;

@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "adoption_posts")
public class AdoptionPost {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "author_user_id", nullable = false)
    private Long authorUserId;

    @Column(name = "adopter_user_id")
    private Long adopterUserId;

    @Column(name = "reserved_by_user_id")
    private Long reservedByUserId;

    @Column(name = "reserved_at")
    private LocalDateTime reservedAt;

    @Column(name = "dog_id", nullable = false, length = 36)
    private String dogId;

    @Column(nullable = false, length = 200)
    private String title;

    @Column(nullable = false, columnDefinition = "TEXT")
    private String content;

    @Column(name = "price")
    private Long price;

    @Enumerated(EnumType.STRING)
    @Column(nullable = false, length = 20)
    private AdoptionPostStatus status = AdoptionPostStatus.DRAFT;

    @Column(name = "published_at")
    private LocalDateTime publishedAt;

    @Column(name = "closed_at")
    private LocalDateTime closedAt;

    @Column(name = "adopted_at")
    private LocalDateTime adoptedAt;

    @Column(name = "verification_step1_completed", nullable = false)
    private boolean verificationStep1Completed = false;

    @Column(name = "verification_step2_completed", nullable = false)
    private boolean verificationStep2Completed = false;

    @Column(name = "verification_step3_completed", nullable = false)
    private boolean verificationStep3Completed = false;

    @Column(name = "created_at", nullable = false, updatable = false)
    private LocalDateTime createdAt;

    @Column(name = "updated_at", nullable = false)
    private LocalDateTime updatedAt;

    @PrePersist
    public void prePersist() {
        LocalDateTime now = LocalDateTime.now();
        if (this.createdAt == null) {
            this.createdAt = now;
        }
        if (this.updatedAt == null) {
            this.updatedAt = now;
        }
    }

    @PreUpdate
    public void preUpdate() {
        this.updatedAt = LocalDateTime.now();
    }
}
