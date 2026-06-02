ALTER TABLE users
    ADD COLUMN profile_image_path VARCHAR(500) NULL AFTER region,
    ADD COLUMN profile_image_mime_type VARCHAR(100) NULL AFTER profile_image_path,
    ADD COLUMN profile_image_file_size BIGINT NULL AFTER profile_image_mime_type,
    ADD COLUMN profile_image_sha256 CHAR(64) NULL AFTER profile_image_file_size;
