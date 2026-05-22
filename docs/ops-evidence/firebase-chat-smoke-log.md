# Firebase Chat Enabled Smoke Log Template

This is a template for recording manual Firebase-enabled runtime smoke validation. Do not store real tokens, service account JSON, private project secrets, `.env` values, or raw credential paths in this document.

## Date

- `<YYYY-MM-DD HH:mm timezone>`

## Environment

- Environment: `<dev | staging | prod | other>`
- Backend URL: `<redacted or internal alias>`
- Operator: `<name or initials>`

## Branch/Commit

- Branch: `<branch>`
- Commit: `<commit_sha>`
- Image/tag: `<image or release tag>`

## Firebase Project

- Project id or alias: `<redacted-project-id-or-alias>`
- Service account path: `<redacted path; do not include filename if sensitive>`
- Credential mounted in container: `<yes | no>`

## Compose Files Used

- `infra/docker/compose.yaml`
- `<compose override>`
- `<compose.firebase.yaml included: yes | no>`

## Backend Healthcheck Result

- Command/check: `<health endpoint or command>`
- Result: `<PASS | FAIL>`
- Notes: `<sanitized notes>`

## Firebase Custom Token Result

- Endpoint: `POST /api/firebase/custom-token`
- Result: `<PASS | FAIL>`
- Evidence: `<status code and sanitized fields only>`

## FCM Token Registration Result

- Endpoint: `PUT /api/users/me/fcm-token`
- Result: `<PASS | FAIL>`
- Evidence: `<status code and sanitized fields only>`

## Chat Room Creation Result

- Endpoint: `POST /api/chat/rooms`
- Post id: `<redacted or test post id>`
- Result: `<PASS | FAIL>`
- Evidence: `<room id shape and sanitized fields only>`

## Message Send Result

- Endpoint: `POST /api/chat/rooms/{room_id}/messages`
- Result: `<PASS | FAIL>`
- Evidence: `<message id shape and sanitized fields only>`

## Mark Read Result

- Endpoint: `PATCH /api/chat/rooms/{room_id}/read`
- Result: `<PASS | FAIL>`
- Evidence: `<status code and sanitized fields only>`

## Chat Room List Result

- Endpoint: `GET /api/chat/rooms`
- Result: `<PASS | FAIL>`
- Evidence: `<status code, count, and sanitized fields only>`

## Firestore Document Verification

- Room document exists: `<yes | no>`
- Room participant uids correct: `<yes | no>`
- Message document exists: `<yes | no>`
- `post_status_snapshot` present: `<yes | no>`
- `room_status` present: `<yes | no>`
- `message_enabled` present: `<yes | no>`
- `synced_at` present: `<yes | no>`
- No prohibited fields observed: `<yes | no>`
- Notes: `<no contact phone, email, nose image URL, Qdrant payload, or verification detail>`

## Firestore Rules Deployed Version/Check

- Rules source: `docs/firebase/firestore.rules`
- Deploy/check command: `<sanitized command or release reference>`
- Result: `<PASS | FAIL>`
- Notes: `<sanitized notes>`

## Result

- Overall result: `<PASS | FAIL>`

## Notes

- `<sanitized notes>`

## Rollback

- Rollback performed: `<yes | no>`
- Rollback action: `<removed compose.firebase.yaml | FIREBASE_ENABLED=false | none | other>`
- Rollback result: `<PASS | FAIL | not applicable>`
