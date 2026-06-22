# PetNose Firebase Current vs Local Readiness Audit

## Summary

- Audit time: 2026-06-23 KST
- Current develop SHA: `26dc982e15632031cda9dfb33b7969107f6a613b`
- Current server result: `APP_TEAM_READY_CORE_PASS`
- Firebase-specific verdict: `FIREBASE_SERVER_PASS_RULES_GAP`
- App team API base URL: `http://13.209.47.253/api`
- Health endpoint: `http://13.209.47.253/actuator/health`

The current EC2 server proves Firebase-enabled Spring API behavior, FCM token registration, chat room creation, message sending, mark-read, room list, MVP/profile-first APIs, and `/files` serving through the external URL. Firestore rules are stronger than the previous server summary because the current `docs/firebase/firestore.rules` emulator validation was re-run and passed locally. The remaining Firebase gap is live project rules deployment/client rules verification on `petnose-c6ec5`, plus app-device validation for Flutter realtime listeners and real push delivery.

No service account JSON, private key, full client email, JWT, Firebase custom token, FCM token value, password, `.env`, raw image, crop payload, or vector is included in this document.

## Evidence Inputs

### Past Local Firebase Evidence

- `docs/ops-evidence/firebase-chat-smoke-log.md`
  - Date: 2026-05-22T23:31:28+09:00
  - Environment: local-dev
  - Branch: `feature/firebase-chat-enabled-smoke-evidence`
  - Base develop SHA: `8070a6a35a02de882b065fb452cdbe3dffbfd469`
  - Firebase custom token: PASS, token not recorded
  - FCM token registration: PASS, token not recorded
  - Chat room creation: PASS
  - Message send: PASS
  - Mark read: PASS
  - Chat room list: PASS
  - Firestore rules emulator validation: PASS
  - Remaining gaps: Flutter realtime listener and real device push delivery

- `docs/ops-evidence/full-functional-regression-firebase-chat-log.md`
  - Date: 2026-05-23 01:48:02 +09:00
  - Environment: local compose runtime with Firebase enabled
  - Branch: `test/full-functional-regression-firebase-chat`
  - Base develop SHA: `6a35b3f7c97e45136433891c88a3b4d6d5e141f2`
  - Backend Gradle tests: PASS
  - Firestore rules emulator tests: PASS
  - Core MVP regression: PASS
  - Firebase chat regression: PASS
  - Remaining gaps: Flutter realtime listener, real device FCM push delivery, repeat smoke on target deployment if different from local-dev

### Current EC2 Evidence

- `C:\tmp\petnose-firebase-enabled-smoke\summary.json`
- `C:\tmp\petnose-firebase-enabled-smoke\api-transcript.md`
- `/opt/petnose-lab/evidence/sanitized/firebase-enabled-smoke-summary.md`
- `/opt/petnose-lab/evidence/sanitized/firebase-enabled-smoke-summary.json`

Current sanitized summary:

- Checked at: 2026-06-22T15:24:45Z, 2026-06-23T00:24:45+09:00
- Base URL: `http://13.209.47.253/api`
- Root URL: `http://13.209.47.253`
- Firebase enabled runtime: PASS
- Firebase credential mount/read: PASS
- Firebase API/chat scenario: PASS
- Dog registration/profile-first handover/files: PASS
- Evidence redaction checks: PASS

## Old vs Current Comparison

| Item | Past Local Validation | Current EC2 Validation | Difference | Current Judgment | App Team Note |
| --- | --- | --- | --- | --- | --- |
| External URL basis | Local compose runtime only | External HTTP through `http://13.209.47.253/api` | Current result covers app-team network path | PASS | Use `/api` base URL for app APIs; health is at root `/actuator/health`. |
| Firebase enabled runtime | PASS locally | PASS on EC2 deploy with Firebase compose included | Stronger environment coverage now | PASS | Server runtime is Firebase-enabled. |
| Firebase custom token | PASS, token not recorded | PASS 200, token redacted | Same API behavior; now deployed on EC2 | PASS | App signs into Firebase client using the returned custom token; do not log it. |
| FCM token registration | PASS, token not recorded | PASS 200, token redacted | Same API behavior; current smoke used dummy token | PASS | Real device delivery still needs a real device token test. |
| Chat room creation | PASS | PASS 201 | Same behavior | PASS | App should create rooms through Spring API, not direct Firestore writes. |
| Message send | PASS | PASS 201 | Same behavior | PASS | App sends messages through Spring API. |
| Mark read | PASS | PASS 200 | Same behavior | PASS | App marks read through Spring API. |
| Room list | PASS | PASS 200 | Same behavior | PASS | Server list API works; app can also attach Firestore read listeners after Firebase client sign-in. |
| Firestore rules emulator | PASS | PASS, rerun with `JAVA_HOME\bin` on PATH; 10 tests passed | Current emulator validation restored | PASS | Rules allow participant reads and block client writes. |
| Live Firestore rules deploy | Not recorded as target-project deploy evidence | NOT_RUN | Live project rules state was not changed in this audit | GAP | Requires approved deploy of `docs/firebase/firestore.rules` to `petnose-c6ec5`. |
| Live client direct write/read test | Past emulator only | NOT_RUN against live project | No live client SDK verification | GAP | App-side listener and blocked-write behavior should be checked on the target Firebase project. |
| Flutter realtime listener | Not verified | Not verified | No change | App-side gap | App team should verify listener against `chat_rooms/{room_id}/messages`. |
| Real device push | Not verified | Not verified; dummy FCM token only | No change | App-side gap | Requires real device FCM token and push receipt validation. |
| MVP/profile-first API | Full local regression PASS | External EC2 smoke PASS | Current result covers deployed GPU/profile-first runtime | PASS | Dog registration, post creation/list/detail, handover, and files serving worked externally. |

## Firestore Rules Result

Current rules source: `docs/firebase/firestore.rules`

Current policy:

- Signed-in participants may read their own `chat_rooms/{room_id}` documents.
- Signed-in participants may read messages under their own rooms.
- Non-participants and unauthenticated clients cannot read rooms or messages.
- Clients cannot create, update, or delete chat rooms.
- Clients cannot create, update, or delete messages.
- Clients cannot read or write `user_devices` token documents.
- Server writes use Firebase Admin SDK and bypass client security rules.

Current emulator command:

```powershell
$env:PATH = (Join-Path $env:JAVA_HOME 'bin') + ';' + $env:PATH
pwsh -NoProfile -File .\scripts\verify-firestore-rules.ps1
```

Current emulator result:

- Node.js: available
- npm: available
- Firebase CLI through npm dependency: available
- Java: available through `JAVA_HOME`, not initially on PATH
- Test result: PASS, 10 passed, 0 failed

Live deploy status:

- Firebase CLI login: present
- `petnose-c6ec5` project visibility: present
- Live deploy to `petnose-c6ec5`: NOT_RUN
- Reason: live deploy is a persistent security-rules change and was not performed in this audit without separate explicit deploy approval after reviewing blast radius.

## Firebase Change Diff Review

Primary comparison range: `6a35b3f7c97e45136433891c88a3b4d6d5e141f2..26dc982e15632031cda9dfb33b7969107f6a613b`

Changed Firebase-related files:

- `backend/src/main/java/com/petnose/api/service/chat/FirebaseChatService.java`
- `scripts/verify-firebase-chat-smoke.ps1`
- `infra/scripts/deploy-real-model.sh`
- `docs/reference/FIREBASE_CHAT_DEPLOYMENT.md`
- `docs/reference/FIREBASE_CHAT_OPERATIONS.md`
- `docs/PETNOSE_MVP_API_CONTRACT.md`
- `docs/firebase/chat-firestore-schema.md`

No changes in this range:

- `backend/src/main/java/com/petnose/api/controller/ChatController.java`
- `backend/src/main/java/com/petnose/api/dto/chat/*`
- `docs/firebase/firestore.rules`
- `infra/docker/compose.firebase.yaml`

Detailed risk assessment:

- API path change: none found. Current routes remain `POST /api/firebase/custom-token`, `PUT /api/users/me/fcm-token`, `POST /api/chat/rooms`, `GET /api/chat/rooms`, `POST /api/chat/rooms/{room_id}/messages`, and `PATCH /api/chat/rooms/{room_id}/read`.
- Request/response shape change: none found in controller/DTO files since the latest full regression base SHA.
- Firestore rules change: none found since the latest full regression base SHA.
- Firestore field contract change: no client-facing field change found. Schema documentation expanded MySQL source-of-truth wording; Firestore chat fields remain `participant_uids`, `participant_user_ids`, `room_status`, `message_enabled`, `last_message`, and message fields such as `sender_uid`, `client_message_id`, and `created_at`.
- Custom token behavior change: `FirebaseChatService` now creates the custom token with only the deterministic UID and no `user_id` custom claim. This matches the deployment guidance because `user_id` is a reserved Firebase claim name. Current EC2 custom-token smoke passed.
- Env/deploy behavior change: `infra/scripts/deploy-real-model.sh` now supports explicit `--firebase`, `--gpu`, and `--profile-first-yolo` flags and validates runtime policy before deploy. Current EC2 deploy used the official script and passed.
- Disabled/enabled behavior: docs and smoke script still treat `FIREBASE_DISABLED` as expected only for disabled runtime. Current FirebaseMode enabled smoke did not see `FIREBASE_DISABLED`.

Initial smoke comparison range: `8070a6a35a02de882b065fb452cdbe3dffbfd469..26dc982e15632031cda9dfb33b7969107f6a613b`

- `ChatParticipantUserIds` was added after the first local smoke and was covered by the later full regression evidence.
- ChatController, chat DTOs, Firestore rules, and Firebase compose overlay still show no route/rules/shape change.

## Current Gaps Before App-Team Handoff

1. Live Firestore rules deploy to `petnose-c6ec5` is not recorded as completed in this audit.
2. Live client direct write/read tests against `petnose-c6ec5` were not run.
3. Flutter realtime listener behavior is not verified from the app.
4. Real device FCM push delivery is not verified because current smoke used a dummy FCM token.
5. Android cleartext HTTP must be allowed for the current HTTP API endpoint during this validation phase.

These gaps do not block app-team HTTP API integration against the current EC2 server. They do block claiming full Firebase client-side readiness.

## App-Team Handoff Text

Use the shared dev API base URL `http://13.209.47.253/api`. Firebase server APIs are enabled on the current EC2 runtime: custom token issue, FCM token registration, chat room creation, room list, message send, and mark-read all passed external HTTP smoke. Dog registration/profile-first GPU runtime, adoption posts, handover verification, and `/files` serving also passed.

For Firebase chat, the app must authenticate to Spring first, call `POST /api/firebase/custom-token`, sign into Firebase with that custom token, and use Spring APIs for room creation, message send, read marking, and FCM token registration. The app may read Firestore room/message snapshots through realtime listeners, but must not write rooms, messages, or device tokens directly to Firestore.

Remaining client-side checks are Flutter realtime listener behavior and real device FCM push delivery. The current Firestore rules file passes emulator validation, but live rules deploy/client direct-write verification on `petnose-c6ec5` still needs an approved operational run.

## Final Firebase Verdict

`FIREBASE_SERVER_PASS_RULES_GAP`

Current EC2 Firebase server API readiness is good for app-team API integration. Firestore rules emulator validation is now PASS, and no route/DTO/rules regression was found since the latest full local regression evidence. The remaining risk is live Firebase project rules deployment/client behavior plus real app-device listener and push validation.
