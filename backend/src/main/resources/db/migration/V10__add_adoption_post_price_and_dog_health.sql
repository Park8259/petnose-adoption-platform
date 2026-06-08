ALTER TABLE adoption_posts
  ADD COLUMN price BIGINT NULL AFTER content,
  ADD CONSTRAINT chk_adoption_posts_price CHECK (price IS NULL OR price >= 0);

ALTER TABLE dogs
  ADD COLUMN health TEXT NULL AFTER description;
