# App-requested API regression log

## Scope

- Auth/User profile image and password APIs.
- Adoption post likes.
- Adoption completion adopter tracking.
- My adopted dogs API.
- Firebase disabled/enabled runtime notes.
- Excluded: post-adoption periodic nose verification.

## Environment

- Date/time: `2026-06-03T12:01:40+09:00`.
- Branch: `test/app-api-regression-and-handoff`.
- Base develop SHA: `406a0f733250e76e2cc9df64fa2ab1043f03ebf3`.
- Working tree base before PR 8 docs commit: `406a0f733250e76e2cc9df64fa2ab1043f03ebf3`.
- Runtime:
  - Local backend test: PASS.
  - GitHub Actions CI: NOT_RUN locally; expected to run after PR creation.
  - Docker compose smoke: NOT_RUN; PR 8 did not start a compose runtime.
  - Real model/image smoke: NOT_RUN; no real dog nose image fixture was added or used.
- Secrets:
  - No real JWT, reset token, Firebase custom token, FCM token, API key, service account JSON, private email, or private phone is recorded here.
  - Any token-like value in examples must remain placeholder-only, for example `<redacted-jwt>` or `<redacted-reset-token>`.

## Automated tests

- Command: `cd backend && gradle test --no-daemon --stacktrace --rerun-tasks`
- Result: PASS.
- Notes:
  - `AuthUserApiIntegrationTest` covered JSON register, multipart register without/with `profile_image`, login/current user payload, profile update, profile image update, password change, and default password reset request token hiding.
  - Password reset confirm flow is covered by `PasswordResetApiIntegrationTest`.
  - Adoption post create/list/detail/status/like coverage is split across `AdoptionPostCreateControllerTest`, `AdoptionPostOwnerManagementControllerTest`, and `AdoptionPostPublicQueryControllerTest`. The older aggregate filename `AdoptionPostControllerTest.java` is not present on current `develop`.
  - `DogQueryControllerTest` covered `GET /api/dogs/me`, `GET /api/dogs/{dog_id}`, and `GET /api/dogs/adopted/me`, including forbidden adopted-list response fields.
  - `ChatControllerFirebaseDisabledTest` covered authenticated Firebase-disabled responses with `FIREBASE_DISABLED`.

## Static checks

- `git diff --check`: PASS.
- No migration in PR 8: PASS; no changed path under `backend/src/main/resources/db/migration`.
- No `docs/db` active schema change: PASS; no changed path under `docs/db`.
- No Java/backend test code change: PASS; no changed path under `backend/src/main` or `backend/src/test`.
- No workflow change: PASS; no changed path under `.github/workflows`.
- Excluded-scope scan: PASS with expected documentation-only mentions of excluded `post_adoption_verifications`; backend hits were existing normal owner assignment/test fixture lines, not adopter reassignment.
- Secret scan: PASS with expected field names/placeholders/config variable names only; no raw token, private key, service account JSON, `.env`, private email, or private phone value was recorded.

## App flow checklist

- JSON register: PASS by automated backend test.
- Multipart register without `profile_image`: PASS by automated backend test.
- Multipart register with `profile_image`: PASS by automated backend test.
- Login: PASS by automated backend test.
- `GET /api/users/me`: PASS by automated backend test.
- `PATCH /api/users/me/profile`: PASS by automated backend test.
- `PATCH /api/users/me/profile-image`: PASS by automated backend test.
- `PATCH /api/users/me/password`: PASS by automated backend test.
- Password reset request/confirm: PASS by automated backend tests.
- Dog register: PASS by automated backend tests.
- Adoption post create: PASS by automated backend test.
- Public adoption post list/detail `liked` field: PASS by automated backend test.
- Like add/delete: PASS by automated backend test.
- Liked list: PASS by automated backend test.
- Adoption completed with `adopter_user_id`: PASS by automated backend test.
- My adopted dogs list: PASS by automated backend test.
- Firebase disabled smoke: PASS by automated backend test; runtime API smoke NOT_RUN because no local server runtime was started.
- Firebase enabled smoke: NOT_RUN; credentials and enabled Firebase runtime are intentionally required outside the repository.

## Runtime/API smoke

- Docker/API smoke: NOT_RUN.
- Reason: PR 8 scope is regression/evidence/docs, and no local Docker compose runtime, disposable fixture users, real nose images, or Firebase credentials were prepared for this run.
- Firebase enabled mode: NOT_RUN because service account JSON and enabled runtime credentials are external secrets and were not available in this workspace.
- Firebase disabled behavior has automated coverage through `ChatControllerFirebaseDisabledTest`, but no live HTTP server smoke was run.

## Excluded scope confirmation

- Post-adoption periodic nose verification was not implemented.
- `post_adoption_verifications` table was not added.
- 1-week/3-month/6-month verification API/table/schedule fields were not added.
- `ADOPTER` role/enum was not added.
- `dogs.owner_user_id` was not reassigned to adopter.
- Firebase remains optional chat/push only and does not replace MySQL domain data.
