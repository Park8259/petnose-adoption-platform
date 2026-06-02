package com.petnose.api.domain.entity;

import jakarta.persistence.*;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.time.LocalDateTime;

@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(
        name = "adoption_post_likes",
        uniqueConstraints = @UniqueConstraint(name = "uk_adoption_post_likes_user_post", columnNames = {"user_id", "post_id"}),
        indexes = {
                @Index(name = "idx_adoption_post_likes_user_created_at", columnList = "user_id, created_at"),
                @Index(name = "idx_adoption_post_likes_post_id", columnList = "post_id")
        }
)
public class AdoptionPostLike {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "user_id", nullable = false)
    private Long userId;

    @Column(name = "post_id", nullable = false)
    private Long postId;

    @Column(name = "created_at", nullable = false, updatable = false)
    private LocalDateTime createdAt;

    @PrePersist
    public void prePersist() {
        if (this.createdAt == null) {
            this.createdAt = LocalDateTime.now();
        }
    }
}
