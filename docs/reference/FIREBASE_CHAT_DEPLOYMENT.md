# Firebase Chat Deployment

> 문서 성격: 보조 참고 문서(Task Reference)
>
> production Firebase chat/push runtime을 enable할 때 server-only credential 배치,
> compose 조합, Firestore rules, smoke evidence 기준을 확인한다.
> active canonical 문서와 충돌하면 active canonical 문서가 우선한다.

---

## Scope

Firebase chat/push는 optional communication layer다. MySQL은 계속 source of truth이며, Firestore는 realtime UI/runtime snapshot으로만 사용한다.

Production Firebase ON requires:

- `infra/docker/compose.firebase.yaml`
- `FIREBASE_ENABLED=true`
- `FIREBASE_PROJECT_ID=petnose-c6ec5`
- `FIREBASE_CREDENTIALS_HOST_PATH=/opt/petnose/secrets/firebase-service-account.json`
- Firestore rules deployed from `docs/firebase/firestore.rules`

---

## Server Credential Placement

Firebase Admin SDK service account JSON은 server-only secret이다.

```text
/opt/petnose/secrets/firebase-service-account.json
```

The Spring container sees it at:

```text
/run/secrets/firebase-service-account.json
```

`compose.firebase.yaml` mounts the host file read-only. Do not copy the JSON into an image and do not commit it to GitHub.

---

## Production Env Keys

```dotenv
FIREBASE_ENABLED=true
PETNOSE_INCLUDE_FIREBASE=true
FIREBASE_PROJECT_ID=petnose-c6ec5
FIREBASE_CREDENTIALS_HOST_PATH=/opt/petnose/secrets/firebase-service-account.json
```

`google-services.json` is for the Android client only. It is not a substitute for the server Admin SDK service account.

---

## Compose Combination

Firebase ON production real-model config:

```bash
docker compose --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.prod.yaml \
  -f infra/docker/compose.prod-real-model.yaml \
  -f infra/docker/compose.firebase.yaml \
  config
```

Pull images:

```bash
docker compose --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.prod.yaml \
  -f infra/docker/compose.prod-real-model.yaml \
  -f infra/docker/compose.firebase.yaml \
  pull
```

Start runtime:

```bash
docker compose --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.prod.yaml \
  -f infra/docker/compose.prod-real-model.yaml \
  -f infra/docker/compose.firebase.yaml \
  up -d
```

Equivalent deploy script:

```bash
bash infra/scripts/deploy-real-model.sh --firebase
```

---

## Firestore Rules Example

Policy:

- Apps may read only participating chat rooms and their messages.
- Client writes are forbidden.
- `user_devices` client access is forbidden.
- Server writes use Firebase Admin SDK through service account/IAM.

```javascript
rules_version = '2';

service cloud.firestore {
  match /databases/{database}/documents {
    function signedIn() {
      return request.auth != null;
    }

    function isRoomParticipant(roomId) {
      return signedIn()
        && request.auth.uid in get(/databases/$(database)/documents/chat_rooms/$(roomId)).data.participant_uids;
    }

    match /chat_rooms/{roomId} {
      allow read: if signedIn() && request.auth.uid in resource.data.participant_uids;
      allow create, update, delete: if false;

      match /messages/{messageId} {
        allow read: if isRoomParticipant(roomId);
        allow create, update, delete: if false;
      }
    }

    match /user_devices/{userUid} {
      allow read, create, update, delete: if false;

      match /tokens/{tokenHash} {
        allow read, create, update, delete: if false;
      }
    }
  }
}
```

The canonical rules file is `docs/firebase/firestore.rules`.

---

## Firestore Paths

Room:

```text
chat_rooms/{room_id}
```

Messages:

```text
chat_rooms/{room_id}/messages/{message_id}
```

Device tokens:

```text
user_devices/{firebase_uid}/tokens/{token_hash}
```

The app listens to `chat_rooms/{room_id}/messages`. It does not write room, message, or device token documents directly.

---

## Server API Responsibilities

Spring Boot remains responsible for:

- `POST /api/firebase/custom-token`
- `PUT /api/users/me/fcm-token`
- `POST /api/chat/rooms`
- `GET /api/chat/rooms`
- `POST /api/chat/rooms/{room_id}/messages`
- `PATCH /api/chat/rooms/{room_id}/read`

Spring Boot also re-checks MySQL `adoption_posts.status` before allowing message sends.

Firebase custom tokens use only the deterministic Firebase UID `user_{id}`. Do not add `user_id` as a custom token additional claim because Firebase reserves that claim name.

---

## Smoke And Evidence

Firebase enabled smoke should prove:

- service account JSON is mounted and readable by Spring
- `POST /api/firebase/custom-token` succeeds
- `PUT /api/users/me/fcm-token` succeeds
- `POST /api/chat/rooms` succeeds
- `POST /api/chat/rooms/{room_id}/messages` succeeds
- `PATCH /api/chat/rooms/{room_id}/read` succeeds
- `GET /api/chat/rooms` succeeds
- Firestore rules block client writes
- no credential/token/private key is recorded

Existing references:

- `docs/ops-evidence/firebase-chat-release-readiness.md`
- `docs/ops-evidence/firebase-chat-smoke-log.md`
- `docs/reference/FIREBASE_CHAT_OPERATIONS.md`
- `docs/firebase/chat-firestore-schema.md`
- `scripts/verify-firebase-chat-smoke.ps1`
- `scripts/prepare-firebase-chat-smoke-fixture.ps1`
- `scripts/verify-firestore-rules.ps1`

---

## Rollback

To disable Firebase without rolling back the whole release:

- Remove `infra/docker/compose.firebase.yaml` from compose invocation, or
- Set `FIREBASE_ENABLED=false` and restart Spring.

MySQL remains authoritative before, during, and after Firebase rollback. Firestore snapshots can be ignored or cleaned later under an approved operational policy.
