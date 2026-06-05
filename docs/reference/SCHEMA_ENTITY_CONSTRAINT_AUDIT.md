# Schema / Entity / Service Constraint Audit

## Status

Current MVP schema alignment:

- core/relationship tables: `users`, `dogs`, `dog_images`, `dog_nose_references`, `verification_logs`, `adoption_posts`, `adoption_post_likes`
- auth support table: `password_reset_tokens`
- dog registration verification history: stored in `verification_logs` with `purpose=DOG_REGISTRATION`
- future handover comparison history: reserved as `purpose=HANDOVER_COMPARE`
- adoption post creation: references an already registered `dog_id` and stores the required representative `profile_image`
- dog nose v2 references: tracked by `dog_nose_references`, with Qdrant UUID point ids that are not equal to `dogs.id`
- app-requested relationship/auth support: `adoption_post_likes`, `password_reset_tokens`, and `adoption_posts.adopter_user_id`/`adopted_at`
- Qdrant remains a vector search index only, not a source of truth

## Current Alignment Notes

- `adoption_posts.title` is 200 characters max.
- `adoption_posts.content` is required.
- `dogs.breed` and `dogs.gender` stay nullable at DB level for import flexibility, while dog registration requires values.
- `dog_images.mime_type`, `dog_images.file_size`, and `dog_images.sha256` stay nullable at DB level for import flexibility, while service-created rows normally include them.
- `verification_logs.submitted_image_*` fields are optional audit metadata for the image submitted to a verification event.
- Adoption post creation does not create dogs, NOSE dog images, verification logs, embeddings, or Qdrant points. It does create one `dog_images.image_type=PROFILE` row for the representative image.

## Runtime Migration Summary

- `V1__baseline.sql`: creates the original baseline.
- `V2__align_adoption_post_content_constraints.sql`: aligns title/content constraints.
- `V3__add_nose_verification_attempts.sql`: historical pre-refactor migration kept for Flyway checksum safety.
- `V4__remove_nose_verification_attempts_and_align_verification_logs.sql`: aligns `verification_logs` with dog-centered history and drops the auxiliary table.
- `V5__add_multi_reference_nose_references.sql`: adds dog nose v2 `dog_nose_references` and `score_breakdown_json`.
- `V6__add_user_profile_image_fields.sql`: adds optional `users.profile_image_*` metadata.
- `V7__add_password_reset_tokens.sql`: adds password reset token hash support.
- `V8__add_adoption_post_likes.sql`: adds the likes relationship table.
- `V9__add_adoption_completion_adopter.sql`: adds adoption completion adopter tracking.

## Verification Checklist

- Entity shape tests should assert that `VerificationLog` uses dog-centered submitted-image metadata and the `DOG_REGISTRATION` / `HANDOVER_COMPARE` purpose enum.
- Runtime migration checks should apply V1 through V9 and confirm the final develop submission table count is 7 core/relationship tables plus 1 auth support table.
- API tests should confirm that adoption post creation uses `dog_id`, stores a PROFILE image, and does not call embed service or Qdrant.
- Dog registration tests should confirm Qdrant upsert point ids are UUIDs tracked by `dog_nose_references`, and duplicate suspected flow skips upsert.
