# App-Requested API PR Plan

## Purpose

This document fixes the PR split for app-team follow-up API requests before implementation begins. PR 0 is documentation-only and must not change Java code, Flyway migrations, DB runtime state, or backend tests.

Canonical endpoint drafts live in `../PETNOSE_MVP_API_CONTRACT.md`. App connection order lives in `../PETNOSE_APP_API_HANDOFF.md`.

`docs/db/petnose_mvp_schema.dbml` 및 `docs/db/V20260508__mvp_canonical_schema.sql`은 backend canonical schema tests의 입력이므로 planned schema는 여기에 기록하지 않고, 실제 Flyway/entity/test 구현 PR에서 함께 갱신한다.

## Global Scope Rules

Included follow-up scope:

- Firebase chat disabled-mode handling through runtime/ops verification.
- Multipart signup with optional user `profile_image`.
- User profile image storage and replacement.
- Logged-in user password change.
- Reset-token-based password reset request/confirm.
- Adoption post likes through `adoption_post_likes`, not `users.liked` JSON/map.
- Adoption completion with `adoption_posts.adopter_user_id`.
- My adopted dogs list through `GET /api/dogs/adopted/me`.

Excluded follow-up scope:

- Post-adoption 1-week/3-month/6-month nose verification.
- `post_adoption_verifications` table.
- Post-adoption verification schedule, deadline, notification, or automatic re-verification.
- Reassigning `dogs.owner_user_id` to the adopter.
- Replacing MySQL domain data with Firebase.

Core policy:

- `dogs.owner_user_id` remains original registrant/author ownership.
- Adopter identity is tracked by `adoption_posts.adopter_user_id`.
- `COMPLETED` still sets `dogs.status = ADOPTED`.
- User password lookup APIs must not exist.
- `password_hash` must never be exposed in responses.
- User profile images use `users.profile_image_*` fields once PR 2 lands.
- Adoption post representative images continue to use `dog_images.image_type=PROFILE`.

## PR 0 docs/app-api-delta-plan

Purpose:

- Freeze the API, schema delta, excluded scope, and PR split before backend implementation.

Included files:

- `docs/README.md`
- `docs/PROJECT_KNOWLEDGE_INDEX.md`
- `docs/PETNOSE_MVP_API_CONTRACT.md`
- `docs/PETNOSE_APP_API_HANDOFF.md`
- `docs/db/petnose_mvp_schema.dbml`
- `docs/db/V20260508__mvp_canonical_schema.sql`
- `docs/reference/FIREBASE_CHAT_OPERATIONS.md`
- `docs/reference/APP_REQUESTED_API_PR_PLAN.md`

Excluded scope:

- Java code, Flyway migration, backend tests, runtime config changes.

Acceptance criteria:

- API delta endpoints A-J are documented as planned.
- Included/excluded scope and core ownership/password/profile-image policies are explicit.
- Schema docs contain planned-change notes only.
- PR body states that tests are unnecessary because this is docs-only.

## PR 1 chore/firebase-chat-runtime-check

Purpose:

- Confirm and document shared/local Firebase runtime behavior for app-team testing.

Included files:

- Firebase runtime/ops docs.
- Smoke evidence docs, if a sanitized runtime check is executed.
- Optional script notes only if existing script behavior needs clarification.

Excluded scope:

- No service account JSON in repo.
- No Firebase replacement for MySQL domain data.
- No Flutter UI implementation.

Acceptance criteria:

- Disabled runtime returns `FIREBASE_DISABLED` after Spring auth.
- Shared dev-server testing does not require app developers to receive service account JSON.
- Local Firebase-enabled testing documents required env values and external credential path.

## PR 2 feat/user-profile-image-storage

Purpose:

- Add the backend users profile image storage foundation.

Included files:

- User entity/schema migration for `users.profile_image_*` fields.
- User profile image storage service method and user payload `profile_image_url` response mapping.
- Active `docs/db` schema docs updated with the implemented columns in the same PR.
- File-storage policy docs, if needed.

Excluded scope:

- No signup multipart handling yet.
- No `PATCH /api/users/me/profile-image` endpoint yet.
- No adoption post representative image policy changes.

Acceptance criteria:

- `users.profile_image_*` columns exist in Flyway runtime migration, entity, DBML, and canonical SQL.
- `FileStorageService` can store user profile images under `users/{user_id}/profile`.
- `GET /api/users/me`, login/current-user payloads, and profile update responses can expose nullable `profile_image_url` without exposing internal file paths.
- `password_hash` remains hidden.

## PR 3 feat/auth-register-multipart-profile-image

Status:

- Implemented in this PR.

Purpose:

- Add multipart signup and user profile image update wiring while preserving existing JSON signup compatibility.

Included files:

- Auth controller/service request handling.
- Optional multipart signup storage reuse from PR 2.
- `PATCH /api/users/me/profile-image` endpoint/service wiring that stores and replaces the current user's profile image.
- Auth API tests.

Excluded scope:

- No removal of `application/json` signup.
- No adoption post image behavior changes.

Acceptance criteria:

- [x] `POST /api/auth/register` accepts multipart fields `email`, `password`, `display_name`, `contact_phone`, `region`, optional `profile_image`.
- [x] Existing JSON signup still works.
- [x] Response can include `profile_image_url`.
- [x] `PATCH /api/users/me/profile-image` stores and replaces the current user's image.

## PR 4 feat/user-password-apis

Status:

- Implemented in this PR.

Purpose:

- Add logged-in password change and reset-token-based password reset APIs.

Included files:

- Auth/user password controller/service code.
- Reset token schema/migration.
- Password API tests.

Excluded scope:

- No password lookup endpoint.
- No password hash exposure.
- No real email/SMS provider integration. Delivery provider wiring is a follow-up operating hardening scope.

Acceptance criteria:

- [x] `PATCH /api/users/me/password` validates `current_password` and updates to `new_password`.
- [x] `POST /api/auth/password-reset/request` does not expose whether email exists in the default response.
- [x] `POST /api/auth/password-reset/confirm` resets via valid token.
- [x] reset token 원문은 DB에 저장하지 않고 SHA-256 hash만 저장한다.
- [x] `password_hash` is never serialized.

## PR 5 feat/adoption-post-likes

Purpose:

- Follow PR 4 by adding like/unlike and my-liked adoption post list.

Included files:

- `adoption_post_likes` migration/entity/repository.
- Adoption post like APIs and tests.
- List response mapping for `liked` and `liked_at`.

Excluded scope:

- No `users.liked` JSON/map implementation.
- No recommendation/ranking system.

Acceptance criteria:

- `PUT /api/adoption-posts/{post_id}/like` is idempotent and returns `liked=true`.
- `DELETE /api/adoption-posts/{post_id}/like` is idempotent and returns `liked=false`.
- `GET /api/adoption-posts/liked/me` returns list items aligned with public adoption post list plus `liked=true` and `liked_at`.

## PR 6 feat/adoption-completion-adopter

Purpose:

- Store adopter identity during adoption completion.

Included files:

- `adoption_posts.adopter_user_id` and `adopted_at` migration/entity fields.
- Status transition service validation.
- Adoption status API tests.

Excluded scope:

- No `dogs.owner_user_id` reassignment.
- No post-adoption verification table or schedule.

Acceptance criteria:

- `COMPLETED` transition requires `adopter_user_id`.
- `adopter_user_id` must be an active user and must not equal `author_user_id`.
- `dogs.status = ADOPTED` remains unchanged behavior.
- `adoption_posts.adopter_user_id` stores the adopter.

## PR 7 feat/my-adopted-dogs-api

Purpose:

- Add current user's adopted dogs list.

Included files:

- Dog/adoption query repository or service.
- `GET /api/dogs/adopted/me` controller and tests.
- Response mapping docs/tests.

Excluded scope:

- No `nose_image_url` exposure.
- No `author_contact_phone` in this list response.
- No post-adoption periodic verification fields.

Acceptance criteria:

- Query uses `adoption_posts.status = COMPLETED AND adoption_posts.adopter_user_id = current_user_id`.
- Response includes dog/post summary and `adopted_at`.
- Response excludes nose image and author contact phone.

## PR 8 test/app-api-regression-and-handoff

Purpose:

- Run focused regression after app-requested API implementation PRs land.

Included files:

- API regression tests or smoke scripts.
- Updated handoff/evidence docs.
- Any final contract clarifications discovered during verification.

Excluded scope:

- No new product features beyond PRs 1-7.
- No post-adoption periodic nose verification.

Acceptance criteria:

- Existing MVP signup/login/dog registration/adoption post/handover flow still passes.
- New profile image, password, likes, adopter completion, and adopted dogs APIs pass regression checks.
- App handoff doc matches implemented endpoint behavior.
