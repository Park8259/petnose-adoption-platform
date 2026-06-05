package com.petnose.api.domain.entity;

import com.petnose.api.domain.enums.DogNoseEmbeddingKind;
import com.petnose.api.domain.enums.NoseReferenceQualityStatus;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.EnumType;
import jakarta.persistence.Enumerated;
import jakarta.persistence.Id;
import jakarta.persistence.PrePersist;
import jakarta.persistence.Table;
import lombok.Getter;
import lombok.NoArgsConstructor;
import lombok.Setter;

import java.math.BigDecimal;
import java.time.Instant;

@Getter
@Setter
@NoArgsConstructor
@Entity
@Table(name = "dog_nose_references")
public class DogNoseReference {

    @Id
    @Column(length = 36)
    private String id;

    @Column(name = "dog_id", nullable = false, length = 36)
    private String dogId;

    @Column(name = "dog_image_id")
    private Long dogImageId;

    @Column(name = "qdrant_point_id", nullable = false, length = 36, unique = true)
    private String qdrantPointId;

    @Enumerated(EnumType.STRING)
    @Column(name = "embedding_kind", nullable = false, length = 20)
    private DogNoseEmbeddingKind embeddingKind;

    @Column(name = "reference_index")
    private Integer referenceIndex;

    @Column(nullable = false, length = 100)
    private String model;

    @Column(nullable = false)
    private Integer dimension;

    @Column(name = "preprocess_version", nullable = false, length = 100)
    private String preprocessVersion;

    @Enumerated(EnumType.STRING)
    @Column(name = "quality_status", nullable = false, length = 30)
    private NoseReferenceQualityStatus qualityStatus = NoseReferenceQualityStatus.ACCEPTED;

    @Column(name = "quality_score", precision = 6, scale = 5)
    private BigDecimal qualityScore;

    @Column(name = "is_active", nullable = false)
    private boolean active = true;

    @Column(name = "created_at", nullable = false, updatable = false)
    private Instant createdAt;

    @PrePersist
    public void prePersist() {
        if (this.createdAt == null) {
            this.createdAt = Instant.now();
        }
        if (this.qualityStatus == null) {
            this.qualityStatus = NoseReferenceQualityStatus.ACCEPTED;
        }
    }
}
