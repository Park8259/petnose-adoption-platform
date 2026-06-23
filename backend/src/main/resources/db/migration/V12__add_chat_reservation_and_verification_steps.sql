ALTER TABLE adoption_posts
  ADD COLUMN reserved_by_user_id BIGINT NULL AFTER adopter_user_id,
  ADD COLUMN reserved_at TIMESTAMP NULL AFTER reserved_by_user_id,
  ADD COLUMN verification_step1_completed BOOLEAN NOT NULL DEFAULT FALSE AFTER adopted_at,
  ADD COLUMN verification_step2_completed BOOLEAN NOT NULL DEFAULT FALSE AFTER verification_step1_completed,
  ADD COLUMN verification_step3_completed BOOLEAN NOT NULL DEFAULT FALSE AFTER verification_step2_completed,
  ADD KEY idx_adoption_posts_reserved_by_user_id (reserved_by_user_id),
  ADD KEY idx_adoption_posts_reserved_status_reserved_at (reserved_by_user_id, status, reserved_at),
  ADD CONSTRAINT fk_adoption_posts_reserved_by_user
    FOREIGN KEY (reserved_by_user_id) REFERENCES users(id);
