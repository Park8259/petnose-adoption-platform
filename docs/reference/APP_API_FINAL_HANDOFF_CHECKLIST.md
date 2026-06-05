# App API Final Handoff Checklist

This checklist is the app-team connection summary for the APIs implemented through PR 0-7 and finalized in PR 8. Detailed request/response examples and error codes remain in `docs/PETNOSE_MVP_API_CONTRACT.md`; flow notes remain in `docs/PETNOSE_APP_API_HANDOFF.md`.

## Global Rules

- Use `Authorization: Bearer <JWT>` for every private endpoint.
- Use `Content-Type: application/json` for JSON requests.
- Use `Content-Type: multipart/form-data` for file upload requests.
- Keep request and response field names in `snake_case`.
- Treat nullable image fields such as `profile_image_url` as null-safe UI inputs.
- Do not log or screenshot JWTs, reset tokens, Firebase custom tokens, FCM tokens, service account JSON, `.env` values, private email, or private phone values.
- Firebase chat/push is optional communication runtime only. MySQL remains the domain source of truth.

## 회원가입

- JSON signup: `POST /api/auth/register`
- Multipart signup with optional user image: `POST /api/auth/register`
- Multipart fields: `email`, `password`, `display_name`, `contact_phone`, `region`, optional file `profile_image`.
- Response fields include `user_id`, `email`, `role`, `display_name`, `contact_phone`, `region`, nullable `profile_image_url`, `is_active`.
- `role` is always public `USER`; app must not send or expect `ADOPTER`.

## 로그인

- Endpoint: `POST /api/auth/login`
- Request fields: `email`, `password`.
- Response fields: `access_token`, `token_type`, `expires_in`, `user`.
- Use `user.profile_image_url` null-safely.

## 마이페이지

- Current user: `GET /api/users/me`
- Profile text update: `PATCH /api/users/me/profile`
- Profile image update: `PATCH /api/users/me/profile-image`
- Password change: `PATCH /api/users/me/password`
- Profile update JSON fields: `display_name`, `contact_phone`, `region`.
- Profile image multipart field: required file `profile_image`.
- Password change JSON fields: `current_password`, `new_password`.
- Password and `password_hash` are never response fields.

## 비밀번호 찾기

- Request reset: `POST /api/auth/password-reset/request`
- Confirm reset: `POST /api/auth/password-reset/confirm`
- Request reset field: `email`.
- Confirm reset fields: `reset_token`, `new_password`.
- The app must show the same reset-request message regardless of whether the email exists.
- In shared-dev expose mode, `reset_token` can appear only for test flow; never record it in logs, screenshots, PRs, or evidence.

## 강아지 등록/분양글 작성

- Dog registration: `POST /api/dogs/register`
- Adoption post create: `POST /api/adoption-posts`
- Dog registration multipart fields: `name`, `breed`, `gender`, optional `birth_date`, optional `description`, exactly five `nose_images` file parts.
- Store `dog_id` only when `registration_allowed=true`.
- Adoption post multipart fields: `dog_id`, `title`, `content`, optional `status`, required file `profile_image`.
- Adoption post `profile_image` is the representative dog/post image stored as `dog_images.image_type=PROFILE`.
- User profile image storage and dog/adoption representative image storage are separate.

## 분양글 목록/상세

- Public list: `GET /api/adoption-posts`
- Public detail: `GET /api/adoption-posts/{post_id}`
- Owner list: `GET /api/adoption-posts/me`
- Public list/detail may be called without Authorization and then return `liked=false`.
- With a valid Authorization header, public list/detail compute `liked` for the current user.
- Public list/detail do not expose `nose_image_url`.

## 좋아요/찜 목록

- Like: `PUT /api/adoption-posts/{post_id}/like`
- Unlike: `DELETE /api/adoption-posts/{post_id}/like`
- My liked posts: `GET /api/adoption-posts/liked/me`
- Like/unlike require Authorization and are idempotent.
- Liked list items include `liked=true` and `liked_at`.
- The app must not expect a `users.liked` JSON/map field.

## 채팅

- Firebase custom token: `POST /api/firebase/custom-token`
- FCM token registration: `PUT /api/users/me/fcm-token`
- Chat room create/get: `POST /api/chat/rooms`
- Chat room list: `GET /api/chat/rooms`
- Message send: `POST /api/chat/rooms/{room_id}/messages`
- Mark read: `PATCH /api/chat/rooms/{room_id}/read`
- App writes chat rooms/messages/read/device-token changes through Spring APIs, not direct Firestore writes.
- `FIREBASE_DISABLED` after Spring authentication means server Firebase runtime is disabled; it is not evidence that the API route is missing.
- Shared dev-server app developers do not receive service account JSON.

## 입양 완료 처리

- Endpoint: `PATCH /api/adoption-posts/{post_id}/status`
- Completing request fields: `status=COMPLETED`, required `adopter_user_id`.
- The app may pass the chat room `inquirer_user_id` as `adopter_user_id`.
- Success response includes `adopter_user_id` and `adopted_at`.
- Server sets `dogs.status=ADOPTED`.
- Server does not reassign `dogs.owner_user_id`; owner remains original registrant/author.

## 내가 입양한 강아지 목록

- Endpoint: `GET /api/dogs/adopted/me`
- Query basis: `adoption_posts.status=COMPLETED AND adoption_posts.adopter_user_id=current_user_id`.
- Response includes dog/post summary fields such as `post_id`, `dog_id`, `post_title`, `dog_name`, `profile_image_url`, `verification_status`, `adopted_at`, `status`.
- Response excludes `nose_image_url`, `author_contact_phone`, `author_user_id`, `adopter_user_id`, and `embedding_status`.
- Post-adoption 1-week/3-month/6-month nose verification is not implemented in this API.

## Excluded Scope

- No post-adoption periodic nose verification API.
- No `post_adoption_verifications` table.
- No post-adoption schedule, deadline, notification, or automatic re-verification.
- No `ADOPTER` role/enum.
- No `dogs.owner_user_id` reassignment to adopter.
- No Firebase replacement for MySQL domain data.
