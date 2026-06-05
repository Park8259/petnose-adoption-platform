# Firebase Chat Operations

## Purpose

Firebase chat is an optional realtime chat and push layer for PetNose.

MySQL remains the source of truth for the canonical domain data: `users`, `dogs`, `dog_images`, `verification_logs`, and `adoption_posts`. Firestore stores chat room, message, and device token snapshots only. Firebase does not replace MySQL, Qdrant, Python Embed, or the dog registration trust pipeline.

Spring Boot remains the authority for chat room creation, message sending, FCM token registration, read marking, and post-status-based chat permission decisions. Flutter may read Firestore through realtime listeners, but must not write chat rooms, messages, or device tokens directly to Firestore.

## Runtime Enablement

Firebase is off by default.

Enable Firebase chat runtime wiring with:

- `infra/docker/compose.firebase.yaml`
- `FIREBASE_PROJECT_ID`
- `FIREBASE_CREDENTIALS_HOST_PATH`

The Firebase service account JSON must live outside the repository. Do not commit it and do not copy it into the image.

The container credential path is:

```text
/run/secrets/firebase-service-account.json
```

## FIREBASE_DISABLED Troubleshooting

Symptoms:

- `POST /api/firebase/custom-token`
- `POST /api/chat/rooms`
- `GET /api/chat/rooms`
- `POST /api/chat/rooms/{room_id}/messages`
- `PATCH /api/chat/rooms/{room_id}/read`
- `PUT /api/users/me/fcm-token`

When these endpoints return `503` with `FIREBASE_DISABLED` after authentication, the request reached Spring Boot and Spring authentication passed, but Firebase Admin SDK runtime wiring is off. This is a server runtime configuration result, not an app-code problem and not evidence that the route is missing.

Most common causes:

- `infra/docker/compose.firebase.yaml` was not included in the compose command.
- `FIREBASE_ENABLED=true` is missing from the running container.
- `FIREBASE_PROJECT_ID` is missing.
- `FIREBASE_CREDENTIALS_HOST_PATH` is missing.
- The service account JSON does not exist at the host path.
- The host path is mounted to the wrong container path.
- `FIREBASE_CREDENTIALS_PATH` inside the container is not `/run/secrets/firebase-service-account.json`.

Firebase chat/push is an optional communication layer. MySQL remains the source of truth, and Firestore stores only chat room, message, and device token runtime snapshots. Spring Boot remains authoritative for custom token issue, chat room creation, message send, read marking, FCM token registration, and post-status permission checks.

## Shared dev server policy for app developers

App developers do not receive the Firebase service account JSON when they call only the shared dev server API.

The service account JSON stays with the server operator and is placed only on the server secret path. App developers need:

- API base URL
- Spring login credential or Spring JWT
- Firebase client app configuration
- The Firebase sign-in flow that uses the result of `POST /api/firebase/custom-token`

Do not put Firebase custom tokens or service account JSON in logs, screenshots, issue comments, or PR descriptions.

## Local backend Firebase test policy

App developers need Firebase server credentials only when they run the backend locally and need to test real Firebase chat connectivity from that local backend.

Required local backend values:

- `FIREBASE_PROJECT_ID`
- `FIREBASE_CREDENTIALS_HOST_PATH`
- `firebase-service-account.json`
- explicit inclusion of `infra/docker/compose.firebase.yaml`

Store the service account JSON outside the repository.

Example host paths:

- `/opt/petnose/secrets/firebase-service-account.json`
- `C:/Dev/petnose-secrets/firebase-service-account.json`

## Runtime verification commands

Start a Firebase-enabled dev runtime:

```bash
docker compose \
  --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.dev.yaml \
  -f infra/docker/compose.firebase.yaml \
  up -d --build
```

Check Firebase-related container environment variables:

```bash
docker compose \
  --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.dev.yaml \
  -f infra/docker/compose.firebase.yaml \
  exec spring-api printenv | grep FIREBASE
```

Check the credential mount:

```bash
docker compose \
  --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.dev.yaml \
  -f infra/docker/compose.firebase.yaml \
  exec spring-api ls -l /run/secrets/firebase-service-account.json
```

Smoke test examples:

```powershell
./scripts/verify-firebase-chat-smoke.ps1 -Mode disabled -BaseUrl http://localhost:8080 -BearerToken "<jwt>"
./scripts/verify-firebase-chat-smoke.ps1 -Mode enabled -BaseUrl http://localhost:8080 -BearerToken "<jwt>" -PostId 123
```

## Dev Run Command

```bash
docker compose \
  --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.dev.yaml \
  -f infra/docker/compose.firebase.yaml \
  up -d --build
```

## Prod Run Command

```bash
docker compose \
  --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.prod.yaml \
  -f infra/docker/compose.firebase.yaml \
  up -d --no-build
```

## Real Model Prod Run Command

```bash
docker compose \
  --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.prod.yaml \
  -f infra/docker/compose.prod-real-model.yaml \
  -f infra/docker/compose.firebase.yaml \
  up -d --no-build
```

## Firestore Rules Deployment Note

`docs/firebase/firestore.rules` is the intended Firestore rules source for this repository.

Client direct writes to `chat_rooms`, `chat_rooms/{room_id}/messages`, and `user_devices` must remain blocked. Participants may read their own rooms and messages. Server writes use the Firebase Admin SDK and bypass client rules.

Deploy rules through approved Firebase tooling and credentials for the target project. Do not store Firebase CLI credentials, service account JSON, or generated secrets in this repository.

## Firestore Rules Emulator Validation

Run the client security rules tests locally with:

```powershell
./scripts/verify-firestore-rules.ps1
```

The helper runs the test project in `tools/firebase-rules` against the Firestore emulator using `firebase.json` and `docs/firebase/firestore.rules`.

These emulator tests validate client rules only:

- signed-in participants can read their own chat rooms and messages
- non-participants and unauthenticated clients cannot read chat rooms or messages
- clients cannot create, update, or delete chat rooms
- clients cannot create, update, or delete messages
- clients cannot read or write `user_devices` or token documents

The tests do not validate Firebase Admin SDK writes. Spring Boot server writes use the Firebase Admin SDK and bypass Firestore client rules.

## Manual Smoke Test

Disabled mode verifies default/dev safety when Firebase is off and authenticated chat endpoints should return `FIREBASE_DISABLED`:

```powershell
./scripts/verify-firebase-chat-smoke.ps1 -Mode disabled -BaseUrl http://localhost:8080 -BearerToken "<jwt>"
```

Enabled mode requires:

- a running backend with Firebase enabled
- a valid Firebase service account mounted at `/run/secrets/firebase-service-account.json`
- a valid Spring JWT for an inquirer user
- an existing `OPEN` adoption post owned by another user

```powershell
./scripts/verify-firebase-chat-smoke.ps1 -Mode enabled -BaseUrl http://localhost:8080 -BearerToken "<jwt>" -PostId 123
```

The script never requires a Firebase client SDK, never writes `.env`, and does not contain real Firebase credentials.

Record real Firebase-enabled runtime smoke evidence in:

```text
docs/ops-evidence/firebase-chat-smoke-log.md
```

Use the template only with sanitized status codes, ids, aliases, and PASS/FAIL evidence. Do not record real tokens, service account JSON, `.env` values, or private Firebase project secrets.

## Latest Firebase Enabled Smoke Evidence

- Evidence file: `docs/ops-evidence/firebase-chat-smoke-log.md`
- Date/time: `2026-05-22T23:31:28+09:00`
- Result: PASS
- Runtime: local compose runtime with Firebase enabled
- Fixture: existing fixture base URL and post id were reused; the stale local auth session was refreshed in memory and no token was recorded
- Credentials are not stored in the repository.
- Rollback: remove `infra/docker/compose.firebase.yaml` from the compose invocation or disable Firebase with `FIREBASE_ENABLED=false`.

## Release Readiness Evidence

- Release readiness evidence: `docs/ops-evidence/firebase-chat-release-readiness.md`
- Latest full regression evidence: `docs/ops-evidence/full-functional-regression-firebase-chat-log.md`

## Preparing Smoke Fixtures

Use `scripts/prepare-firebase-chat-smoke-fixture.ps1` to create the runtime data required by enabled-mode Firebase chat smoke testing.

The fixture helper creates:

- an author user
- an inquirer user
- a registered dog owned by the author
- an `OPEN` adoption post owned by the author
- a sensitive PowerShell env setup file for `scripts/verify-firebase-chat-smoke.ps1`

Required image inputs:

- five close-up cropped dog nose images for active dog nose v2 registration
- a profile image for adoption post creation

The generated output env file contains a Spring JWT for the inquirer user. Treat it as sensitive, keep it outside the repository, and do not commit it.
By default, the output env file is written under the current user's temp directory. The helper rejects output env file paths inside the repository before creating any parent directory.

Local fixture creation should follow `docs/ops-evidence/dog-nose-v2-smoke-plan.md`: create a registered dog through `POST /api/dogs/register` with exactly five `nose_images`, then create the `OPEN` adoption post with a required `profile_image`.

If dog registration returns `registration_allowed=false`, reset the disposable dev runtime/Qdrant data or use a different nose image before retrying. The author and inquirer are generated as different users, so the created `OPEN` post is owned by a different user than the smoke JWT holder. The helper does not query MySQL or Firestore directly; it only uses the public Spring APIs and lets the running backend own Firebase connectivity.

## Rollback

To disable Firebase chat, remove `infra/docker/compose.firebase.yaml` from the compose invocation or set `FIREBASE_ENABLED=false`.

The backend should remain bootable without Firebase credentials. Firebase chat APIs continue to require a Spring Bearer token and return `503` with `FIREBASE_DISABLED` when Firebase is disabled.

MySQL data remains authoritative during and after rollback. Firestore chat snapshots can be ignored or cleaned up separately if an operational policy requires it.

## Security Checklist

- No service account JSON in the repository.
- No `.env` in the repository.
- Firestore client writes disabled for chat rooms, messages, and device tokens.
- MySQL remains the source of truth.
- Spring JWT required for server chat APIs.
- Do not store nose image URLs, contact phone, email, Qdrant payloads, or verification details in Firestore chat docs.
- Do not expose Firebase custom tokens in logs, PR descriptions, screenshots, or smoke-test output.
