# Schema / Entity / Service Constraint Audit

## Status

Current MVP schema alignment:

- app domain tables: `users`, `dogs`, `dog_images`, `verification_logs`, `adoption_posts`
- dog registration verification history: stored in `verification_logs` with `purpose=DOG_REGISTRATION`
- future handover comparison history: reserved as `purpose=HANDOVER_COMPARE`
- adoption post creation: references an already registered `dog_id` and stores the required representative `profile_image`
- Qdrant remains a vector search index only, with `dogs.id` as point id

## Current Alignment Notes

- `adoption_posts.title` is 200 characters max.
- `adoption_posts.content` is required.
- `dogs.breed` and `dogs.gender` stay nullable at DB level for import flexibility, while dog registration requires values.
- `dog_images.mime_type`, `dog_images.file_size`, and `dog_images.sha256` stay nullable at DB level for import flexibility, while service-created rows normally include them.
- `verification_logs.submitted_image_*` fields are optional audit metadata for the image submitted to a verification event.
- Adoption post creation does not create dogs, NOSE dog images, verification logs, embeddings, or Qdrant points. It does create one `dog_images.image_type=PROFILE` row for the representative image.

## Runtime Migration Summary

- `V1__baseline.sql`: creates the 5-table baseline.
- `V2__align_adoption_post_content_constraints.sql`: aligns title/content constraints.
- `V3__add_nose_verification_attempts.sql`: historical pre-refactor migration kept for Flyway checksum safety.
- `V4__remove_nose_verification_attempts_and_align_verification_logs.sql`: aligns `verification_logs` with dog-centered history and drops the auxiliary table.

## Verification Checklist

- Entity shape tests should assert that `VerificationLog` uses dog-centered submitted-image metadata and the `DOG_REGISTRATION` / `HANDOVER_COMPARE` purpose enum.
- Runtime migration checks should apply V1 -> V2 -> V3 -> V4 and confirm the final app table count is 5.
- API tests should confirm that adoption post creation uses `dog_id`, stores a PROFILE image, and does not call embed service or Qdrant.
- Dog registration tests should confirm Qdrant upsert point id is `dog_id` and duplicate suspected flow skips upsert.
