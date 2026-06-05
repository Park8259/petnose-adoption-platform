# Firebase Chat Stabilization Plan

Date: 2026-05-21

## Branch And Base

- Current branch: `feature/firebase-chat-stabilization`
- Base branch: latest `origin/develop`
- Base commit: `ade80c48dcc4d97b2365acad5832aa744b1baeca`
- Base commit summary: `ade80c4 Merge pull request #41 from jaaesung/feature/firebase-chat`
- This phase is audit/planning only. It intentionally does not implement Java, DB migration, Docker, Firebase rules, or test changes.

## Current Firebase Implementation Summary

The current `develop` branch includes a Firebase chat backend layer from PR #41.

- `FirebaseConfig` is enabled only when `firebase.enabled=true`.
- `FirebaseProperties` exposes `enabled`, `project-id`, and `credentials-path`.
- `application.yml` defaults Firebase to disabled through `FIREBASE_ENABLED:false`.
- `backend/src/test/resources/application.yml` also disables Firebase.
- `build.gradle.kts` adds `com.google.firebase:firebase-admin:9.9.0`.
- `ChatController` exposes Spring Boot APIs for:
  - Firebase custom token issue
  - FCM token registration
  - chat room create/list
  - text message send
  - read marking
- `FirebaseChatService` uses `ObjectProvider<Firestore>`, `ObjectProvider<FirebaseAuth>`, and `ObjectProvider<FirebaseMessaging>`, so the service can be constructed when Firebase beans are absent.
- Firestore collections currently used:
  - `chat_rooms/{room_id}`
  - `chat_rooms/{room_id}/messages/{message_id}`
  - `user_devices/{firebase_uid}/tokens/{token_hash}`
- Room IDs are deterministic: `post_{post_id}_user_{inquirer_user_id}`.
- Firebase UIDs are deterministic: `user_{mysql_user_id}`.
- MySQL remains the permission and domain source for users, dogs, and adoption posts.

## Confirmed Safe Parts

- Firebase is currently isolated from the core MySQL/Qdrant/Python Embed flow.
- No Firebase code writes canonical domain data into MySQL.
- No DB schema or migration was added for chat.
- `DogRegistrationService`, `HandoverVerificationService`, `EmbedClient`, and `QdrantDogVectorClient` are not called by the chat service.
- Chat room creation checks MySQL `users`, `adoption_posts`, and `dogs`.
- Message sending re-reads the MySQL adoption post and applies post status policy before writing to Firestore.
- Flutter is not expected to write chat messages directly to Firestore; Spring APIs perform room creation, message send, FCM token registration, and read marking.
- Firestore rules deny all client writes to `chat_rooms`, `messages`, and `user_devices`.
- Firestore rules allow client reads only for authenticated room participants.
- Firebase disabled mode should keep the backend bootable because Firebase beans are conditional and injected through `ObjectProvider`.
- Existing test config keeps Firebase disabled.
- The existing Firebase-specific test confirms `POST /api/firebase/custom-token` returns `FIREBASE_DISABLED` when Firebase is disabled.

## Confirmed Gaps

### Configuration And Docker

- `compose.yaml` does not pass `FIREBASE_ENABLED`, `FIREBASE_PROJECT_ID`, or `FIREBASE_CREDENTIALS_PATH` into `spring-api`.
- `compose.prod.yaml` does not define a production Firebase secret mount or credential strategy.
- `infra/docker/.env.example` does not document Firebase variables or service account handling.
- `.gitignore` does not explicitly ignore common Firebase service account JSON filename patterns.
- There is no documented Firebase rules deployment process.
- There is no documented Firebase enabled-mode smoke path for dev or prod.

### Status Sync

- `AdoptionPostService.updateStatus(...)` updates MySQL but does not sync existing Firestore rooms for the post.
- Existing room creation writes `post_status_snapshot`, but status changes after room creation are only refreshed when a message is sent.
- Existing rooms do not have the proposed stable fields:
  - `message_enabled`
  - `room_status`
  - `synced_at`

### Firestore Schema And Flutter UI

- Current room fields are enough for a basic room and message listener, but not enough for a stable official UI state policy.
- Current room docs use `status: "ACTIVE"` only; this is not expressive enough for read-only or disabled chat states.
- Current API list response always returns `unread_count=0`, so Flutter should not treat it as a real unread badge yet.
- `docs/firebase/chat-firestore-schema.md` says message documents include `post_id`, but the current service does not write `post_id` on message documents.
- The room list endpoint reads rooms from Firestore, then loads post title/status and user display name from MySQL, which preserves source-of-truth behavior but is not yet optimized or fully tested.

### API And Error Quality

- Firebase disabled behavior is only tested for custom token issue, not every chat endpoint.
- Some chat failures reuse broad error codes such as `CHAT_MESSAGE_SEND_FAILED` for room creation or FCM token storage.
- There is no official API contract section for chat endpoints.
- There is no official statement in canonical docs that Firebase chat is an optional layer now present behind a feature flag.

### Docs

Several canonical docs are now inconsistent with the code from PR #41:

- `docs/PETNOSE_MVP_FINAL_PROJECT_SPEC.md` still says Firebase, chat, and push are excluded.
- `docs/PETNOSE_MVP_API_CONTRACT.md` still says Firebase, chat, and push APIs are not added.
- `docs/PROJECT_KNOWLEDGE_INDEX.md` still says Firebase chat/push is not active and not implemented.
- `docs/README.md` does not route Firebase chat work to the new Firebase reference docs.
- `docs/firebase/chat-firestore-schema.md` describes the new layer, but it is not yet reconciled with canonical docs.

### Tests

Current Firebase-specific coverage is minimal:

- Present:
  - `ChatControllerFirebaseDisabledTest`
- Missing:
  - disabled-mode tests for all chat endpoints
  - service-level tests for room creation, duplicate room return, message send, read marking, FCM token storage, and custom token issue
  - post status policy tests for `OPEN`, `RESERVED`, `COMPLETED`, `CLOSED`, and `DRAFT`
  - status sync tests from `AdoptionPostService`
  - Firestore rules tests or emulator smoke tests
  - Docker enabled-mode smoke docs/tests
  - docs/API contract consistency checks

## Required Stabilization Phases

### Phase 0: Audit And Plan

This document only.

### Phase 1: Runtime Configuration And Secret Safety

- Keep Firebase disabled by default.
- Add Firebase env pass-through to Docker only after the secret strategy is documented.
- Add read-only service account mount support for dev/prod.
- Add `.gitignore` patterns for Firebase service account JSON files.
- Document Firebase rules deployment and enabled-mode smoke steps.

### Phase 2: Firestore Room State Policy

- Add stable room fields:
  - `post_status_snapshot`
  - `message_enabled`
  - `room_status`
  - `synced_at`
- Keep MySQL `adoption_posts.status` as the authority.
- Use Firestore fields only as UI snapshots.
- Keep Flutter writes disabled.

### Phase 3: Adoption Post Status Sync

- Sync existing Firestore rooms after a MySQL adoption post status change succeeds.
- Prefer an after-commit event/listener so Firestore is not updated before the MySQL transaction commits.
- A Firestore sync failure must not make Firebase the source of truth and must not silently change MySQL state.

### Phase 4: Tests And Contract Hardening

- Add focused unit/integration tests around disabled mode, service policy, status sync, and rules.
- Update canonical docs and API contract only after implementation behavior is stable.

## P0 Tasks For Stable Official Chat

1. Define and implement room status fields:
   - `post_status_snapshot`
   - `message_enabled`
   - `room_status`
   - `synced_at`
2. Apply this status policy:
   - `OPEN`: new room allowed, existing messages allowed
   - `RESERVED`: new room blocked, existing messages allowed for MVP
   - `COMPLETED`: new room blocked, existing messages disabled/read-only
   - `CLOSED`: new room blocked, existing messages disabled/read-only
   - `DRAFT`: chat disabled
3. Add status sync from `AdoptionPostService.updateStatus(...)` to Firestore chat rooms for the same `post_id`.
4. Keep all permission checks tied to MySQL `users`, `dogs`, and `adoption_posts`.
5. Ensure `sendMessage(...)` enforces MySQL status and writes the same room state snapshot.
6. Add Docker/env/secret strategy for Firebase enabled mode without committing secrets.
7. Add `.gitignore` protection for Firebase service account JSON files.
8. Align `docs/firebase/chat-firestore-schema.md` with actual fields.
9. Update canonical docs to say Firebase chat/push is an optional feature-flagged layer, not a MySQL replacement.
10. Add tests for disabled-mode endpoint behavior and status-policy enforcement.
11. Add tests for status sync on adoption post transitions.
12. Verify Firestore rules preserve client read-only/server-write-only behavior.

## P1 Tasks

- Replace broad chat error codes with endpoint-specific codes.
- Decide whether `unread_count` is supported now; either compute it correctly or document it as unsupported until implemented.
- Add optional Firebase emulator smoke tests.
- Add Firestore rules CI/emulator validation.
- Add push notification token cleanup and invalid-token handling.
- Add logout/token deletion API if Flutter needs it.
- Add pagination/cursor strategy for Firestore room listing.
- Add operational logging/metrics for Firestore sync failures.
- Add a manual backfill/resync command for existing rooms if production data exists.
- Consider a retry strategy for Firestore status sync without adding canonical domain tables.

## P2 Out Of Scope

The stabilization work must not add these features:

- `reserved_user_id`
- `selected_inquirer_user_id`
- reservation feature
- payment feature
- contract feature
- report feature
- admin dashboard feature
- image messages
- message delete/edit
- Flutter direct Firestore writes
- MySQL chat message tables
- Firebase replacement of MySQL domain data
- Qdrant replacement or alternate vector store

This phase explicitly does not add reservation, payment, contract, report, or admin features.

## Exact Files Expected To Change In Later Implementation PRs

Likely P0 implementation files:

- `backend/src/main/java/com/petnose/api/service/chat/FirebaseChatService.java`
- `backend/src/main/java/com/petnose/api/service/AdoptionPostService.java`
- `backend/src/main/java/com/petnose/api/service/chat/ChatPostStatusSyncService.java` new
- `backend/src/main/java/com/petnose/api/service/chat/ChatRoomStatusPolicy.java` new
- `backend/src/main/java/com/petnose/api/event/AdoptionPostStatusChangedEvent.java` new, if using event/listener sync
- `backend/src/main/java/com/petnose/api/config/FirebaseConfig.java`
- `backend/src/main/java/com/petnose/api/config/FirebaseProperties.java`
- `backend/src/main/resources/application.yml`
- `backend/src/test/resources/application.yml`
- `backend/src/test/java/com/petnose/api/controller/ChatControllerFirebaseDisabledTest.java`
- `backend/src/test/java/com/petnose/api/service/chat/FirebaseChatServiceTest.java` new
- `backend/src/test/java/com/petnose/api/service/chat/ChatPostStatusSyncServiceTest.java` new
- `backend/src/test/java/com/petnose/api/service/AdoptionPostChatStatusSyncTest.java` new
- `infra/docker/compose.yaml`
- `infra/docker/compose.dev.yaml`
- `infra/docker/compose.prod.yaml`
- `infra/docker/.env.example`
- `.gitignore`
- `docs/firebase/chat-firestore-schema.md`
- `docs/firebase/firestore.rules`
- `docs/PETNOSE_MVP_FINAL_PROJECT_SPEC.md`
- `docs/PETNOSE_MVP_API_CONTRACT.md`
- `docs/PROJECT_KNOWLEDGE_INDEX.md`
- `docs/README.md`

Files not expected for P0:

- `backend/src/main/resources/db/migration/**`
- DB schema docs, unless only clarifying that no chat DB tables exist
- Qdrant client/config files
- Python Embed files

## Proposed Test List

Disabled mode:

- Backend context boots with `firebase.enabled=false`.
- Each chat endpoint returns `FIREBASE_DISABLED` after authentication when Firebase is disabled.
- Existing non-chat controller tests continue to pass with Firebase disabled.

Firebase service policy:

- custom token uses `user_{id}` and rejects inactive/missing users.
- FCM token registration writes only through Spring service.
- room creation succeeds only for `OPEN` posts.
- room creation rejects self-inquiry.
- room creation rejects unregistered dogs.
- room creation returns the existing deterministic room id.
- message send allows only participants.
- message send rejects empty or overlong text.
- message send is idempotent for the same `client_message_id`.
- message send allows `OPEN` and `RESERVED`.
- message send rejects `COMPLETED`, `CLOSED`, and `DRAFT`.
- read marking allows only participants.

Status sync:

- `OPEN -> RESERVED` sets `post_status_snapshot=RESERVED`, `message_enabled=true`, `room_status=ACTIVE`, and updates `synced_at`.
- `RESERVED -> OPEN` re-enables active messaging.
- `OPEN/RESERVED -> COMPLETED` sets `message_enabled=false`, `room_status=READ_ONLY`, and updates `synced_at`.
- `OPEN/RESERVED -> CLOSED` sets `message_enabled=false`, `room_status=READ_ONLY`, and updates `synced_at`.
- `DRAFT -> OPEN` needs no room sync unless rooms already exist unexpectedly.
- Firestore sync runs after MySQL commit.

Firestore rules:

- participant can read own room.
- non-participant cannot read room.
- participant can read messages in own room.
- any client create/update/delete on room is denied.
- any client create/update/delete on message is denied.
- any client access to `user_devices` is denied.

Docker/config:

- Firebase disabled compose path starts without Firebase credentials.
- Firebase enabled compose path starts only when project id and credential path are supplied.
- Service account JSON is mounted read-only and is not copied into the image.

## Proposed Dev/Prod Docker And Secret Strategy

Default policy:

- Firebase remains disabled unless `FIREBASE_ENABLED=true`.
- CI and normal local development keep Firebase disabled.
- No Firebase service account JSON is committed.
- No Firebase secret is baked into Docker images.

Dev enabled mode:

- Store local service account JSON outside tracked files, for example under an ignored `infra/secrets/` path.
- Mount it read-only into `spring-api`, for example at `/run/secrets/firebase-service-account.json`.
- Set:
  - `FIREBASE_ENABLED=true`
  - `FIREBASE_PROJECT_ID=<dev firebase project id>`
  - `FIREBASE_CREDENTIALS_PATH=/run/secrets/firebase-service-account.json`

Prod enabled mode:

- Store the service account JSON outside the repository on the server or in a managed secret store.
- Mount it read-only into the container at a stable path.
- Keep production `.env` on the server only.
- Prefer immutable image tags for deploys; do not rebuild images with secrets.
- Deploy Firestore rules separately through Firebase tooling with approved credentials.

Suggested later `.gitignore` additions:

- `infra/secrets/`
- `infra/docker/secrets/`
- `firebase-service-account*.json`
- `serviceAccountKey*.json`
- `*-firebase-adminsdk-*.json`

## P0-1 Docker/Secret Wiring

This phase adds safe runtime wiring only. It does not make chat an official stable feature, does not change Java chat logic, does not add DB schema, and does not change Firestore rules.

Firebase OFF remains the default:

- Base compose usage without `infra/docker/compose.firebase.yaml` keeps Firebase disabled.
- Normal CI/local development does not need Firebase credentials.

Firebase ON requires:

- `FIREBASE_PROJECT_ID`
- `FIREBASE_CREDENTIALS_HOST_PATH`
- the service account JSON stored outside the repository
- explicit inclusion of `infra/docker/compose.firebase.yaml`

The service account JSON is mounted into the container at:

```text
/run/secrets/firebase-service-account.json
```

Dev Firebase enabled:

```bash
docker compose \
  --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.dev.yaml \
  -f infra/docker/compose.firebase.yaml \
  up -d --build
```

Prod Firebase enabled:

```bash
docker compose \
  --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.prod.yaml \
  -f infra/docker/compose.firebase.yaml \
  up -d --no-build
```

Real model prod Firebase enabled:

```bash
docker compose \
  --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.prod.yaml \
  -f infra/docker/compose.prod-real-model.yaml \
  -f infra/docker/compose.firebase.yaml \
  up -d --no-build
```

Secret safety notes:

- Do not commit the real Firebase service account JSON.
- Do not bake Firebase credentials into Docker images.
- `FIREBASE_CREDENTIALS_HOST_PATH` is a host path used by Compose only.
- The Spring container always sees credentials at `/run/secrets/firebase-service-account.json`.
- This phase only enables safe runtime wiring for later Firebase enabled-mode validation.

## P0-2 Room State Fields

This phase adds Firestore chat room state snapshots and a small backend policy abstraction only.

Room documents written by chat APIs now include:

- `room_status`
- `message_enabled`
- `synced_at`

The existing `post_status_snapshot` field remains and is updated alongside the new state fields during room creation and successful message send.

Policy:

- `OPEN`: `room_status=ACTIVE`, `message_enabled=true`
- `RESERVED`: `room_status=ACTIVE`, `message_enabled=true`; new room creation remains blocked elsewhere, but existing messages remain allowed for MVP
- `COMPLETED`: `room_status=READ_ONLY`, `message_enabled=false`
- `CLOSED`: `room_status=READ_ONLY`, `message_enabled=false`
- `DRAFT`: `room_status=DISABLED`, `message_enabled=false`

Explicit non-goals for this PR:

- AdoptionPost after-commit Firestore sync is not implemented.
- No DB schema changes or migrations.
- No Docker/runtime wiring changes.
- No Firestore rules changes.
- No reservation, payment, contract, report, admin, `reserved_user_id`, or `selected_inquirer_user_id` scope is added.

## P0-3 AdoptionPost Status Sync

This phase implements after-commit Firestore room status synchronization from `AdoptionPostService.updateStatus(...)`.

Implemented behavior:

- Successful MySQL adoption post status changes schedule `ChatRoomPostStatusSyncService.syncPostStatus(postId, status)` after transaction commit.
- Same-status no-op updates, validation failures, authorization failures, and invalid transitions do not schedule sync.
- Firebase disabled mode is a no-op because the Firebase implementation uses optional Firestore injection.
- Firestore query/write failures are logged and isolated from the MySQL transaction and API response.
- Matching `chat_rooms` for the post receive:
  - `post_status_snapshot`
  - `room_status`
  - `message_enabled`
  - `synced_at`
- Pure post-status sync does not update `last_message` or `updated_at`, so message activity ordering is not changed by status-only events.

Explicit non-goals for this PR:

- No DB schema changes or migrations.
- No Docker/runtime wiring changes.
- No Firestore rules changes.
- No reservation, payment, contract, report, admin, `reserved_user_id`, or `selected_inquirer_user_id` scope is added.

## P0-4 Contract, Disabled Tests, and Runtime Smoke

This phase makes Firebase chat ready as an official optional feature from the API/docs/validation perspective.

Implemented behavior:

- Canonical and API docs are aligned with Firebase chat/push as an optional implemented communication layer.
- Firebase-disabled endpoint coverage is expanded across custom token issue, FCM token registration, room creation, room listing, message send, and read marking.
- A manual Firebase chat smoke script is added for disabled-mode safety checks and enabled-mode runtime verification.
- A Firebase chat operations runbook is added for enablement, verification, rollback, and security guardrails.
- MySQL remains the source of truth and the current canonical schema remains unchanged: 7 core/relationship tables plus the `password_reset_tokens` auth support table.

Explicit non-goals for this PR:

- No DB schema changes or migrations.
- No Docker runtime file changes.
- No Firestore rules changes.
- No Flutter changes.
- No Python Embed changes.
- No reservation, payment, contract, report, admin, `reserved_user_id`, or `selected_inquirer_user_id` scope is added.

## P0-5 Firestore Rules Validation and Runtime Evidence

This phase adds emulator-based Firestore client rules validation and a safe runtime evidence workflow.

Implemented behavior:

- Firestore emulator configuration is added through `firebase.json`.
- A dedicated `tools/firebase-rules` test project validates participant reads and client write blocking for Firebase chat.
- A repository helper script runs the rules tests locally without Firebase credentials.
- A Firebase-enabled smoke evidence template is added for sanitized manual runtime validation records.
- Firebase Admin SDK server writes remain outside client rules tests because Admin SDK writes bypass Firestore rules.

Explicit non-goals for this PR:

- No real Firebase credentials, service account JSON, `.env`, tokens, or secrets are committed.
- No DB schema changes or migrations.
- No Docker runtime file changes.
- No Java chat logic changes.
- No Flutter changes.
- No Python Embed changes.
- No reservation, payment, contract, report, admin, `reserved_user_id`, or `selected_inquirer_user_id` scope is added.

Readiness note:

- Real Firebase-enabled smoke still must be run on a Firebase-enabled server and recorded in the evidence template before claiming full production readiness.

## P0-6 Fixture Preparation for Firebase Enabled Smoke

This phase adds a fixture preparation helper for Firebase-enabled chat smoke validation.

Implemented behavior:

- A fixture script creates distinct author and inquirer users through Spring APIs.
- The script registers a dog with runtime image input, then creates an `OPEN` adoption post owned by the author.
- The script writes sensitive smoke environment values to an output file outside the repository and rejects repository-internal output paths.
- The generated inquirer JWT can be used by `scripts/verify-firebase-chat-smoke.ps1 -Mode enabled`.

Explicit non-goals for this PR:

- No credentials, JWTs, Firebase tokens, `.env`, service account JSON, or local images are committed.
- No DB schema changes or migrations.
- No Docker runtime file changes.
- No Java backend logic changes.
- No Firestore rules changes.
- No Flutter changes.
- No Python Embed changes.
- No reservation, payment, contract, report, admin, `reserved_user_id`, or `selected_inquirer_user_id` scope is added.

Readiness note:

- Enabled Firebase chat evidence can be recorded only after backend tests pass, Firestore rules tests pass, fixture preparation succeeds, and enabled smoke passes against a Firebase-enabled backend.

## P0-7 Firebase Enabled Runtime Smoke Evidence

This phase completes local Firebase-enabled runtime smoke validation for the Spring-authoritative chat flow.

Implemented behavior:

- Firebase enabled smoke passed against the local compose runtime.
- Backend tests passed.
- Firestore rules emulator validation passed.
- Firestore `participant_user_ids` parsing is fixed without relying on generic `List.class` deserialization.
- No credentials, JWTs, Firebase tokens, `.env`, service account JSON, service account paths, or local images are committed.

Remaining gaps:

- Flutter realtime listener app-side verification.
- Real device push delivery validation.

## P0-8 Release Readiness Audit

This phase adds the release readiness audit for deciding whether `develop` can be promoted to `main` with Firebase chat as an optional backend feature.

Implemented behavior:

- P0-8 Release readiness audit added.
- Backend/API readiness PASS.
- Product readiness remains PARTIAL until Flutter listener and real device push delivery are verified.

Explicit non-goals for this PR:

- No DB schema changes or migrations.
- No Java backend logic changes.
- No Docker runtime file changes.
- No Firestore rules changes.
- No Flutter changes.
- No Python Embed changes.
- No reservation, payment, contract, report, or admin scope is added.

## P0-9 Full Functional Regression

This phase records the full local functional regression before any `develop` to `main` promotion decision.

Implemented behavior:

- P0-9 Full functional regression completed.
- Backend/API + core MVP + Firebase chat local regression PASS.
- Backend Gradle tests passed.
- Firestore rules emulator validation passed.
- Real-model runtime health passed with Python Embed `model_loaded=true` and `vector_dim=2048`.
- Core MVP real-model flow passed, including auth, dog registration, duplicate detection, adoption post flow, handover/status checks, DB checks, Qdrant checks, and file URL checks.
- Firebase chat smoke passed, including fixture creation, custom token issue, FCM token registration, room creation, message send, read marking, and room listing.

Remaining gaps:

- Flutter realtime listener app-side verification.
- Real device push delivery validation.

## Proposed Firestore Room Fields

Every `chat_rooms/{room_id}` document should contain:

- `post_status_snapshot`: current MySQL `adoption_posts.status` observed by Spring.
- `message_enabled`: boolean. `true` only when messages are allowed by the status policy.
- `room_status`: UI state string. Suggested values:
  - `ACTIVE`
  - `READ_ONLY`
  - `DISABLED`
- `synced_at`: Firestore server timestamp for the last Spring status sync.

Compatibility note:

- Existing `status: "ACTIVE"` can remain temporarily for older clients, but new Flutter UI should use `room_status` and `message_enabled`.

## Proposed Status Policy

| MySQL adoption post status | New room creation | Existing messages | Firestore snapshot |
|---|---:|---:|---|
| `OPEN` | allowed | allowed | `post_status_snapshot=OPEN`, `message_enabled=true`, `room_status=ACTIVE` |
| `RESERVED` | blocked | allowed for MVP | `post_status_snapshot=RESERVED`, `message_enabled=true`, `room_status=ACTIVE` |
| `COMPLETED` | blocked | disabled/read-only | `post_status_snapshot=COMPLETED`, `message_enabled=false`, `room_status=READ_ONLY` |
| `CLOSED` | blocked | disabled/read-only | `post_status_snapshot=CLOSED`, `message_enabled=false`, `room_status=READ_ONLY` |
| `DRAFT` | blocked | disabled | `post_status_snapshot=DRAFT`, `message_enabled=false`, `room_status=DISABLED` |

## Audit Answers

1. Firebase currently stays isolated from MySQL/Qdrant/Python Embed authority. It reads MySQL for permissions and snapshots, and writes only Firestore chat/push data.
2. Disabled mode should keep boot and existing APIs unaffected; this is supported by conditional config and `ObjectProvider`, but coverage should expand beyond the single custom-token disabled test.
3. Firebase enabled Docker/dev/prod is missing env pass-through, read-only secret mounts, `.env.example` entries, `.gitignore` protection, and deployment docs.
4. Official stable chat needs room state fields, adoption status sync, docs/API alignment, expanded tests, and enabled-mode operational guidance.
5. Adoption post status should sync after `AdoptionPostService.updateStatus(...)` commits, updating all Firestore rooms for the post.
6. Firestore room fields are sufficient for a basic listener, but not for stable official UI state until `message_enabled`, `room_status`, and `synced_at` are added.
7. Firestore rules align with client read-only/server-write-only intent, but need emulator/rules tests and deployment docs.
8. Docs are inconsistent: canonical docs still say Firebase/chat/push are excluded or not implemented, while code and `docs/firebase/**` now exist.
9. Tests currently cover only one Firebase-disabled endpoint. Service behavior, status policy, status sync, rules, and Docker enabled mode are missing.
10. Minimal safe implementation sequence is: secrets/config first, room state fields second, status sync third, tests/docs fourth. Do not add DB schema or broader product features.
