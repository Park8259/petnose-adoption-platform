# Firebase Rules Tests

This directory contains emulator-only Firestore security rules tests for the optional PetNose Firebase chat layer.

The tests validate client rules only:

- participants can read their own `chat_rooms/{roomId}` documents
- participants can read messages under their rooms
- non-participants and unauthenticated clients cannot read rooms or messages
- clients cannot create, update, or delete chat rooms
- clients cannot create, update, or delete messages
- clients cannot read or write `user_devices` or token documents

Server writes are not tested here. Spring Boot uses the Firebase Admin SDK, and Admin SDK writes bypass Firestore client rules.

## Run

From the repository root:

```powershell
./scripts/verify-firestore-rules.ps1
```

The helper installs dependencies in this directory and runs `npm test`, which starts the Firestore emulator with the root `firebase.json` config. The test project id is `petnose-rules-test`.

No real Firebase project, service account, `.env`, or networked Firebase backend is required for the tests themselves.
