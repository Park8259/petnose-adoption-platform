# Firebase Chat Release Readiness

## Scope

- Firebase chat/push is an optional communication layer.
- MySQL remains source of truth.
- Firebase does not replace canonical MySQL domain tables.
- This readiness check covers backend/API/Firestore/runtime validation.
- This readiness check does not prove full Flutter UI behavior or real device push delivery.

## Completed Backend/Firebase Validation

- [x] Firebase runtime env/secret wiring added.
- [x] Firebase disabled mode tested.
- [x] Firebase custom token API implemented and smoke-tested.
- [x] FCM token registration implemented and smoke-tested.
- [x] Chat room creation implemented and smoke-tested.
- [x] Message send implemented and smoke-tested.
- [x] Mark read implemented and smoke-tested.
- [x] Chat room list implemented and smoke-tested.
- [x] Firestore room state fields added:
  - `room_status`
  - `message_enabled`
  - `synced_at`
- [x] AdoptionPost status after-commit sync implemented.
- [x] Firestore `participant_user_ids` parsing fixed.
- [x] Firestore rules emulator tests passed.
- [x] Firebase enabled runtime smoke PASS evidence recorded.
- [x] Backend Gradle tests passed.
- [x] No Firebase credentials or tokens committed.

## Evidence References

- `docs/ops-evidence/full-functional-regression-firebase-chat-log.md`
- `docs/ops-evidence/firebase-chat-smoke-log.md`
- `scripts/verify-firebase-chat-smoke.ps1`
- `scripts/prepare-firebase-chat-smoke-fixture.ps1`
- `scripts/verify-firestore-rules.ps1`
- `docs/firebase/firestore.rules`
- `docs/reference/FIREBASE_CHAT_OPERATIONS.md`

## Security Checks

- No service account JSON committed.
- No `.env` committed.
- No JWT/FCM/custom token committed.
- Firestore client writes remain blocked.
- Server writes use Firebase Admin SDK.
- Firestore chat docs do not store:
  - nose image URL
  - contact phone
  - email
  - Qdrant payloads
  - verification details

## Main Promotion Strategy

- Safe to merge code into main with Firebase remaining optional.
- Default runtime remains Firebase OFF unless `compose.firebase.yaml` and Firebase env are supplied.
- For production Firebase ON, require service account secret mounted outside repo.
- For rollback, remove `compose.firebase.yaml` from compose invocation or set Firebase disabled.
- Firebase ON should be treated as environment opt-in, not mandatory for baseline backend boot.

## Remaining Gaps

- Flutter realtime listener app-side verification remains.
- Real device FCM push delivery remains.
- Production/shared-dev Firebase enabled smoke should be repeated after deployment if environment differs from local-dev.
- Device push delivery with a real token is not proven by dummy FCM token smoke.

## Readiness Verdict

Backend/API Firebase chat readiness: PASS for optional deployment.

Full product readiness: PARTIAL until Flutter realtime listener and real-device push delivery are verified.
