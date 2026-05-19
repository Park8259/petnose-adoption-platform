package com.petnose.api.domain.entity;

import com.petnose.api.domain.enums.VerificationResult;
import com.petnose.api.domain.enums.VerificationPurpose;
import jakarta.persistence.*;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.Instant;

@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "verification_logs")
public class VerificationLog {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    private Long id;

    @Column(name = "dog_id", nullable = false, length = 36)
    private String dogId;

    @Column(name = "dog_image_id")
    private Long dogImageId;

    @Column(name = "requested_by_user_id", nullable = false)
    private Long requestedByUserId;

    @Column(name = "submitted_image_path", length = 500)
    private String submittedImagePath;

    @Column(name = "submitted_image_mime_type", length = 100)
    private String submittedImageMimeType;

    @Column(name = "submitted_image_file_size")
    private Long submittedImageFileSize;

    @Column(name = "submitted_image_sha256", length = 64)
    private String submittedImageSha256;

    @Enumerated(EnumType.STRING)
    @Column(name = "result", nullable = false, length = 40)
    private VerificationResult result;

    @Enumerated(EnumType.STRING)
    @Column(name = "purpose", nullable = false, length = 40)
    private VerificationPurpose purpose = VerificationPurpose.DOG_REGISTRATION;

    @Column(name = "similarity_score", precision = 6, scale = 5)
    private BigDecimal similarityScore;

    @Column(name = "candidate_dog_id", length = 36)
    private String candidateDogId;

    @Column(name = "model", length = 100)
    private String model;

    @Column(name = "dimension")
    private Integer dimension;

    @Column(name = "failure_reason", length = 1000)
    private String failureReason;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @PrePersist
    public void prePersist() {
        if (this.purpose == null) {
            this.purpose = VerificationPurpose.DOG_REGISTRATION;
        }
        if (this.createdAt == null) {
            this.createdAt = Instant.now();
        }
    }
}
