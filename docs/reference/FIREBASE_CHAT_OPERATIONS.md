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
