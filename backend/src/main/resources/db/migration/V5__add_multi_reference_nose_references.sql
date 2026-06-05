ALTER TABLE dogs DROP CHECK chk_dogs_status;

ALTER TABLE dogs
    ADD CONSTRAINT chk_dogs_status
    CHECK (status IN (
        'PENDING',
        'REGISTERED',
        'DUPLICATE_SUSPECTED',
        'REVIEW_REQUIRED',
        'REJECTED',
        'ADOPTED',
        'INACTIVE'
    ));

ALTER TABLE verification_logs DROP CHECK chk_verification_logs_result;

ALTER TABLE verification_logs
    ADD CONSTRAINT chk_verification_logs_result
    CHECK (result IN (
        'PENDING',
        'PASSED',
        'DUPLICATE_SUSPECTED',
        'REVIEW_REQUIRED',
        'EMBED_FAILED',
        'QDRANT_SEARCH_FAILED',
        'QDRANT_UPSERT_FAILED'
    ));

ALTER TABLE verification_logs
    ADD COLUMN score_breakdown_json TEXT NULL AFTER similarity_score;

CREATE TABLE dog_nose_references (
    id CHAR(36) NOT NULL,
    dog_id CHAR(36) NOT NULL,
    dog_image_id BIGINT NULL,
    qdrant_point_id CHAR(36) NOT NULL,
    embedding_kind VARCHAR(20) NOT NULL,
    reference_index INT NULL,
    model VARCHAR(100) NOT NULL,
    dimension INT NOT NULL,
    preprocess_version VARCHAR(100) NOT NULL,
    quality_status VARCHAR(30) NOT NULL DEFAULT 'ACCEPTED',
    quality_score DECIMAL(6, 5) NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,

    PRIMARY KEY (id),
    UNIQUE KEY uk_dog_nose_references_qdrant_point_id (qdrant_point_id),
    KEY idx_dog_nose_references_dog_id (dog_id),
    KEY idx_dog_nose_references_dog_kind_active (dog_id, embedding_kind, is_active),
    KEY idx_dog_nose_references_image_id (dog_image_id),

    CONSTRAINT fk_dog_nose_references_dog
        FOREIGN KEY (dog_id) REFERENCES dogs(id),

    CONSTRAINT fk_dog_nose_references_image
        FOREIGN KEY (dog_image_id) REFERENCES dog_images(id),

    CONSTRAINT chk_dog_nose_references_kind
        CHECK (embedding_kind IN ('REFERENCE', 'CENTROID')),

    CONSTRAINT chk_dog_nose_references_quality
        CHECK (quality_status IN ('ACCEPTED', 'REJECTED', 'NEEDS_REVIEW'))
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci;
