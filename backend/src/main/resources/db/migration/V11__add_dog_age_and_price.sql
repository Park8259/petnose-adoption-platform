ALTER TABLE dogs
  ADD COLUMN age INT NULL AFTER birth_date,
  ADD COLUMN price BIGINT NULL AFTER health,
  ADD CONSTRAINT chk_dogs_age CHECK (age IS NULL OR age >= 0),
  ADD CONSTRAINT chk_dogs_price CHECK (price IS NULL OR price >= 0);
