-- =============================================================================
-- V4__remove_nose_verification_attempts_and_align_verification_logs.sql
-- Remove the retired pre-adoption ticket table and keep verification_logs as
-- dog-centered verification history.
--
-- V3 is kept unchanged for Flyway checksum safety. Fresh databases apply V3,
-- then this migration drops the auxiliary nose_verification_attempts table.
-- Historical attempt rows do not map to the dog_id-centered product flow because
-- they are not tied to a registered dog identity.
-- =============================================================================

ALTER TABLE verification_logs
    DROP FOREIGN KEY fk_verification_logs_image;

ALTER TABLE verification_logs
    MODIFY dog_image_id BIGINT NULL,
    ADD COLUMN submitted_image_path VARCHAR(500) NULL AFTER requested_by_user_id,
    ADD COLUMN submitted_image_mime_type VARCHAR(100) NULL AFTER submitted_image_path,
    ADD COLUMN submitted_image_file_size BIGINT NULL AFTER submitted_image_mime_type,
    ADD COLUMN submitted_image_sha256 CHAR(64) NULL AFTER submitted_image_file_size,
    ADD COLUMN purpose VARCHAR(40) NOT NULL DEFAULT 'DOG_REGISTRATION' AFTER result;

ALTER TABLE verification_logs
    ADD KEY idx_verification_logs_purpose (purpose),
    ADD KEY idx_verification_logs_submitted_image_path (submitted_image_path),
    ADD CONSTRAINT fk_verification_logs_image
        FOREIGN KEY (dog_image_id) REFERENCES dog_images (id),
    ADD CONSTRAINT chk_verification_logs_purpose
        CHECK (purpose IN ('DOG_REGISTRATION', 'HANDOVER_COMPARE'));

DROP TABLE nose_verification_attempts;
