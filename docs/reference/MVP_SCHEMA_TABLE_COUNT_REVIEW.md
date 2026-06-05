# MVP Schema Table Count Review: Resolved by Dog Nose v2 Submission Schema

## 결론

Resolved: `nose_verification_attempts` has been removed from the active runtime schema, and dog nose v2 multi-reference metadata is tracked by `dog_nose_references`.

Current develop submission MySQL tables are 8 total.

Core domain/relationship tables are 7:

- `users`
- `dogs`
- `dog_images`
- `dog_nose_references`
- `verification_logs`
- `adoption_posts`
- `adoption_post_likes`

Auth support table is 1:

- `password_reset_tokens`

## Current Flow

- `POST /api/dogs/register` is the only active entrypoint for dog identity registration, nose duplicate search, and Qdrant upsert.
- Registration receives exactly 5 `nose_images` and calls Python `/embed-batch` once.
- Normal registration creates 5 Qdrant `REFERENCE` points and 1 `CENTROID` point.
- `POST /api/adoption-posts` creates a post from an already registered `dog_id`.
- Adoption post creation does not create a dog, create dog images, call the embed service, or upsert Qdrant.
- Qdrant point ids are UUIDs and are not equal to `dog_id`. `post_id` is never a Qdrant id.
- Qdrant point ids and reference metadata are tracked by MySQL `dog_nose_references`.

## Verification Logs

`verification_logs` stores dog-centered verification history.

Active purposes:

- `DOG_REGISTRATION`
- `HANDOVER_COMPARE`

The previous pre-adoption ticket role is no longer active. The active API no longer returns or consumes a verification ticket for post creation.

## Migration Note

V3 remains in Flyway history for checksum safety. V4 aligns `verification_logs` with the dog-centered flow and drops the auxiliary table. V5 adds multi-reference nose metadata, V6 adds user profile image metadata, V7 adds password reset support, V8 adds adoption post likes, and V9 adds adoption completion adopter fields. Historical rows in `nose_verification_attempts` do not map to a registered `dog_id`, so they are not promoted into active verification history.
