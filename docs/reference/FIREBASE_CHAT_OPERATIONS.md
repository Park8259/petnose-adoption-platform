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

## Preparing Smoke Fixtures

Use `scripts/prepare-firebase-chat-smoke-fixture.ps1` to create the runtime data required by enabled-mode Firebase chat smoke testing.

The fixture helper creates:

- an author user
- an inquirer user
- a registered dog owned by the author
- an `OPEN` adoption post owned by the author
- a sensitive PowerShell env setup file for `scripts/verify-firebase-chat-smoke.ps1`

Required image inputs:

- a nose image for dog registration
- a profile image for adoption post creation

The generated output env file contains a Spring JWT for the inquirer user. Treat it as sensitive, keep it outside the repository, and do not commit it.
By default, the output env file is written under the current user's temp directory. The helper rejects output env file paths inside the repository before creating any parent directory.

Local example:

```powershell
.\scripts\prepare-firebase-chat-smoke-fixture.ps1 `
  -BaseUrl "http://localhost:8080" `
  -NoseImagePath "C:\Dev\sample\nose_test1.jpg" `
  -ProfileImagePath "C:\Dev\sample\profile3.jpg" `
  -RunSmoke
```

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
