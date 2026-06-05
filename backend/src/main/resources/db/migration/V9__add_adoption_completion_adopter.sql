ALTER TABLE adoption_posts
  ADD COLUMN adopter_user_id BIGINT NULL AFTER author_user_id,
  ADD COLUMN adopted_at TIMESTAMP NULL AFTER closed_at,
  ADD KEY idx_adoption_posts_adopter_user_id (adopter_user_id),
  ADD KEY idx_adoption_posts_adopter_status_adopted_at (adopter_user_id, status, adopted_at),
  ADD CONSTRAINT fk_adoption_posts_adopter_user
    FOREIGN KEY (adopter_user_id) REFERENCES users(id);
