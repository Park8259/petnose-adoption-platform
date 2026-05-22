# PetNose Full Functional Regression — Real Model + Firebase Chat

## Date/time

- 2026-05-23 01:48:02 +09:00

## Branch

- `test/full-functional-regression-firebase-chat`

## Develop base commit SHA

- `6a35b3f7c97e45136433891c88a3b4d6d5e141f2`

## Runtime

- Docker compose files:
  - `infra/docker/compose.yaml`
  - `infra/docker/compose.dev.yaml`
  - `infra/docker/compose.real-model.yaml`
  - `infra/docker/compose.firebase.yaml`
- Runtime reset used: yes
- Firebase project alias: `dev-firebase`
- Service account path: redacted

## Automated tests

- Backend Gradle tests: PASS
- Firestore rules emulator tests: PASS

## Runtime health

- Spring actuator: PASS
- Python embed: PASS, `model_loaded=true`, `vector_dim=2048`
- Qdrant: PASS

## Core MVP regression

- Auth/register/login/me: PASS
- Dog registration first pass: PASS
- Duplicate detection: PASS
- Adoption post create/list/detail/owner/status: PASS
- Handover verification/status flow: PASS
- DB/Qdrant/file checks: PASS

## Firebase chat regression

- Fixture creation: PASS
- Firebase custom token: PASS
- FCM token registration: PASS
- Chat room creation: PASS
- Message send: PASS
- Mark read: PASS
- Chat room list: PASS
- Optional enabled-runtime post-status send gate check: not run separately; post status sync and message status policy are covered by backend tests and prior Firebase readiness evidence.

## Security

- No secrets committed.
- No `.env` committed.
- No service account JSON committed.
- No JWT/FCM/custom token committed.
- MySQL remains source of truth.
- Firebase remains optional chat/push layer.

## Result

PASS

## Remaining gaps

- Flutter realtime listener app-side verification.
- Real device FCM push delivery validation.
- Repeat smoke on target deployment environment if different from local-dev.
