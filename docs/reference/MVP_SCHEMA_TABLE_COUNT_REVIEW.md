# MVP Schema Table Count Review: Resolved by Dog Id Centered Adoption Flow

## 결론

Resolved: `nose_verification_attempts` has been removed from the active runtime schema.

Current MVP app tables are 5:

- `users`
- `dogs`
- `dog_images`
- `verification_logs`
- `adoption_posts`

## Current Flow

- `POST /api/dogs/register` is the only active entrypoint for dog identity registration, nose duplicate search, and Qdrant upsert.
- `POST /api/adoption-posts` creates a post from an already registered `dog_id`.
- Adoption post creation does not create a dog, create dog images, call the embed service, or upsert Qdrant.
- Qdrant point id is always `dog_id`; `post_id` is never a Qdrant id.

## Verification Logs

`verification_logs` stores dog-centered verification history.

Active purposes:

- `DOG_REGISTRATION`
- `HANDOVER_COMPARE`

The previous pre-adoption ticket role is no longer active. The active API no longer returns or consumes a verification ticket for post creation.

## Migration Note

V3 remains in Flyway history for checksum safety. V4 aligns `verification_logs` with the dog-centered flow and drops the auxiliary table. Historical rows in `nose_verification_attempts` do not map to a registered `dog_id`, so they are not promoted into active verification history.
