CREATE TABLE adoption_post_likes (
    id BIGINT NOT NULL AUTO_INCREMENT,
    user_id BIGINT NOT NULL,
    post_id BIGINT NOT NULL,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id),
    UNIQUE KEY uk_adoption_post_likes_user_post (user_id, post_id),
    KEY idx_adoption_post_likes_user_created_at (user_id, created_at),
    KEY idx_adoption_post_likes_post_id (post_id),
    CONSTRAINT fk_adoption_post_likes_user
        FOREIGN KEY (user_id) REFERENCES users(id),
    CONSTRAINT fk_adoption_post_likes_post
        FOREIGN KEY (post_id) REFERENCES adoption_posts(id)
) ENGINE = InnoDB
  DEFAULT CHARSET = utf8mb4
  COLLATE = utf8mb4_unicode_ci;
