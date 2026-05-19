-- =============================================================================
-- V20260508__mvp_canonical_schema.sql
-- PetNose MVP simplified canonical clean schema v2
--
-- Documentation-only clean schema. Do not place this file in the backend Flyway
-- migration directory as-is. MySQL is the source of truth; Qdrant is a vector
-- search index only.
-- =============================================================================

CREATE TABLE users (
    id BIGINT NOT NULL AUTO_INCREMENT,
    email VARCHAR(255) NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    role VARCHAR(20) NOT NULL DEFAULT 'USER',
    display_name VARCHAR(150) NULL,
    contact_phone VARCHAR(30) NULL,
    region VARCHAR(100) NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uk_users_email (email),
    CONSTRAINT chk_users_role CHECK (role IN ('USER', 'ADMIN'))
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci;

CREATE TABLE dogs (
    id CHAR(36) NOT NULL,
    owner_user_id BIGINT NOT NULL,
    name VARCHAR(100) NOT NULL,
    -- Dog registration API requires non-blank breed. The clean schema keeps
    -- this nullable for operational/import flexibility.
    breed VARCHAR(100) NULL,
    -- Dog registration API requires MALE, FEMALE, or UNKNOWN. UNKNOWN is an
    -- explicit API value and is not applied as a DB default.
    gender VARCHAR(10) NULL,
    birth_date DATE NULL,
    description TEXT NULL,
    status VARCHAR(30) NOT NULL DEFAULT 'PENDING',
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_dogs_owner_user_id (owner_user_id),
    KEY idx_dogs_status (status),
    CONSTRAINT fk_dogs_owner_user
        FOREIGN KEY (owner_user_id) REFERENCES users (id),
    CONSTRAINT chk_dogs_gender
        CHECK (gender IS NULL OR gender IN ('MALE', 'FEMALE', 'UNKNOWN')),
    CONSTRAINT chk_dogs_status
        CHECK (status IN ('PENDING', 'REGISTERED', 'DUPLICATE_SUSPECTED', 'REJECTED', 'ADOPTED', 'INACTIVE'))
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci;

CREATE TABLE dog_images (
    id BIGINT NOT NULL AUTO_INCREMENT,
    dog_id CHAR(36) NOT NULL,
    image_type VARCHAR(20) NOT NULL,
    file_path VARCHAR(500) NOT NULL,
    -- Service-created DogImage rows should include mime_type, file_size, and
    -- sha256. These remain nullable for migration/import flexibility.
    mime_type VARCHAR(100) NULL,
    file_size BIGINT NULL,
    sha256 CHAR(64) NULL,
    uploaded_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uk_dog_images_file_path (file_path),
    KEY idx_dog_images_dog_id (dog_id),
    KEY idx_dog_images_type (image_type),
    CONSTRAINT fk_dog_images_dog
        FOREIGN KEY (dog_id) REFERENCES dogs (id),
    CONSTRAINT chk_dog_images_type
        CHECK (image_type IN ('NOSE', 'PROFILE'))
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci;

CREATE TABLE verification_logs (
    id BIGINT NOT NULL AUTO_INCREMENT,
    dog_id CHAR(36) NOT NULL,
    dog_image_id BIGINT NULL,
    requested_by_user_id BIGINT NOT NULL,
    submitted_image_path VARCHAR(500) NULL,
    submitted_image_mime_type VARCHAR(100) NULL,
    submitted_image_file_size BIGINT NULL,
    submitted_image_sha256 CHAR(64) NULL,
    result VARCHAR(40) NOT NULL,
    purpose VARCHAR(40) NOT NULL DEFAULT 'DOG_REGISTRATION',
    similarity_score DECIMAL(6, 5) NULL,
    candidate_dog_id CHAR(36) NULL,
    model VARCHAR(100) NULL,
    dimension INT NULL,
    failure_reason VARCHAR(1000) NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_verification_logs_submitted_image_path (submitted_image_path),
    KEY idx_verification_logs_dog_id (dog_id),
    KEY idx_verification_logs_image_id (dog_image_id),
    KEY idx_verification_logs_user_id (requested_by_user_id),
    KEY idx_verification_logs_result (result),
    KEY idx_verification_logs_purpose (purpose),
    KEY idx_verification_logs_candidate (candidate_dog_id),
    KEY idx_verification_logs_expires_at (expires_at),
    KEY idx_verification_logs_consumed_by_post_id (consumed_by_post_id),
    CONSTRAINT fk_verification_logs_dog
        FOREIGN KEY (dog_id) REFERENCES dogs (id),
    CONSTRAINT fk_verification_logs_image
        FOREIGN KEY (dog_image_id) REFERENCES dog_images (id),
    CONSTRAINT fk_verification_logs_user
        FOREIGN KEY (requested_by_user_id) REFERENCES users (id),
    CONSTRAINT fk_verification_logs_candidate
        FOREIGN KEY (candidate_dog_id) REFERENCES dogs (id)
            ON DELETE SET NULL,
    CONSTRAINT chk_verification_logs_result
        CHECK (result IN ('PENDING', 'PASSED', 'DUPLICATE_SUSPECTED', 'EMBED_FAILED', 'QDRANT_SEARCH_FAILED', 'QDRANT_UPSERT_FAILED')),
    CONSTRAINT chk_verification_logs_purpose
        CHECK (purpose IN ('DOG_REGISTRATION', 'HANDOVER_COMPARE'))
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci;

CREATE TABLE adoption_posts (
    id BIGINT NOT NULL AUTO_INCREMENT,
    author_user_id BIGINT NOT NULL,
    dog_id CHAR(36) NOT NULL,
    title VARCHAR(200) NOT NULL,
    content TEXT NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'DRAFT',
    published_at TIMESTAMP NULL,
    closed_at TIMESTAMP NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    KEY idx_adoption_posts_author_user_id (author_user_id),
    KEY idx_adoption_posts_dog_id (dog_id),
    KEY idx_adoption_posts_status (status),
    KEY idx_adoption_posts_published_at (published_at),
    CONSTRAINT fk_adoption_posts_author_user
        FOREIGN KEY (author_user_id) REFERENCES users (id),
    CONSTRAINT fk_adoption_posts_dog
        FOREIGN KEY (dog_id) REFERENCES dogs (id),
    CONSTRAINT chk_adoption_posts_status
        CHECK (status IN ('DRAFT', 'OPEN', 'RESERVED', 'COMPLETED', 'CLOSED'))
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci;
