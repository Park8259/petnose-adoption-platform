# PetNose Firebase Chat Layer

Firebase is an optional chat and push layer. MySQL remains the canonical domain store for users, dogs, dog_images, verification_logs, and adoption_posts. Flutter reads Firestore through realtime listeners, but message writes must go through the Spring Boot API.

## Collections

### `chat_rooms/{room_id}`

- `room_id`: deterministic room id, `post_{post_id}_user_{inquirer_user_id}`
- `post_id`: MySQL `adoption_posts.id`
- `dog_id`: MySQL `dogs.id`
- `author_user_id`: MySQL `users.id`
- `inquirer_user_id`: MySQL `users.id`
- `author_uid`: Firebase Auth uid for the post author
- `inquirer_uid`: Firebase Auth uid for the inquirer
- `participant_user_ids`: numeric user ids
- `participant_uids`: Firebase Auth uids issued by Spring, formatted as `user_{id}`
- `participants`: display-only participant metadata without email/contact
- `post_snapshot`: display-only post/dog metadata; not source of truth
- `post_status_snapshot`: latest status observed by Spring while creating/sending
- `last_message`: text preview, sender uid, and server timestamp
- `last_read_at`: map keyed by Firebase uid
- `status`: `ACTIVE`
- `created_at`, `updated_at`: server timestamps

Do not store nose image URLs, Qdrant payloads, verification details, contacts, or emails in chat documents.

### `chat_rooms/{room_id}/messages/{message_id}`

- `message_id`
- `room_id`
- `post_id`
- `sender_user_id`
- `sender_uid`
- `type`: `TEXT`
- `text`
- `client_message_id`
- `created_at`

### `user_devices/{firebase_uid}/tokens/{token_hash}`

- `platform`: `ANDROID`, `IOS`, or `WEB`
- `fcm_token`
- `created_at`
- `updated_at`
- `last_seen_at`

Flutter does not write this collection directly. `PUT /api/users/me/fcm-token` stores the token through Spring Boot.

## Status Rules

- `OPEN`: new room creation allowed, existing room messages allowed
- `DRAFT`, `RESERVED`: new room creation blocked
- `RESERVED`: existing room messages allowed
- `COMPLETED`, `CLOSED`: read-only

## API

- `POST /api/firebase/custom-token`: exchanges Spring JWT authentication for a Firebase custom token
- `PUT /api/users/me/fcm-token`: stores the user's FCM token in Firestore `user_devices`
- `POST /api/chat/rooms`: creates or returns a room for an `OPEN` post
- `GET /api/chat/rooms`: lists rooms where the current user is a participant
- `POST /api/chat/rooms/{roomId}/messages`: writes a message to Firestore through Spring
- `PATCH /api/chat/rooms/{roomId}/read`: updates `last_read_at` for the current user
