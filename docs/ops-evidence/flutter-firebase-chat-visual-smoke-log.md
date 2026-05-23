# Flutter Firebase Chat Visual Smoke Log

> Template only. Do not mark PASS unless the manual visual test was actually performed on an emulator or real device.
> Do not include Spring JWTs, Firebase custom tokens, FCM token values, service account JSON, `.env` values, or private keys.

## Run Metadata

- Date:
- Device/emulator:
- OS / API level:
- App branch/commit:
- Backend URL:
- Firebase project alias:
- Firebase client config source:
- User roles tested:
- Post id:
- Room id:

## Checklist

| Area | Expected | Result | Evidence / Notes |
| --- | --- | --- | --- |
| Custom token sign-in | Firebase custom token is fetched through Spring API and Firebase Auth sign-in succeeds. Custom token is not displayed. | NOT RUN | |
| Firestore listener | `chat_rooms/{room_id}` and `chat_rooms/{room_id}/messages` listener starts for a participant user. | NOT RUN | |
| Chat room creation | `POST /api/chat/rooms` creates or returns a room for the fixture `post_id`. | NOT RUN | |
| Message send | `POST /api/chat/rooms/{room_id}/messages` succeeds with a generated `client_message_id`. | NOT RUN | |
| Realtime receive | Sent message appears through the Firestore listener without a client Firestore write. | NOT RUN | |
| Mark read | `PATCH /api/chat/rooms/{room_id}/read` succeeds. | NOT RUN | |
| Room list | `GET /api/chat/rooms` shows room id/status/preview fields. | NOT RUN | |
| FCM token registration | `PUT /api/users/me/fcm-token` succeeds without recording the full token. | NOT RUN | |
| Real push delivery | A real device receives a push notification for the other participant. | NOT RUN | |

## PASS / FAIL

- Overall result: NOT RUN

## Notes

-
