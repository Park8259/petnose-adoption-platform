# nosetag_app

NoseTag Flutter app.

## Profile Draft Nose Preview Check

The dog registration screen keeps the normal display profile image flow and
adds one separate front-facing face/nose check image. The app sends that
face/nose check image to the Spring Boot profile draft endpoint as
`profile_image`, then moves to the existing five-image nose capture screen when
the backend confirms `profile_nose_preview.extracted=true`.

The display profile image remains in Flutter state and is passed to the
existing registration/post flow. If the backend must persist both the display
profile image and the face/nose check image in the draft step, the API needs a
separate field in a later backend task.

Run the backend stack first. To enable detector-backed preview on the server,
configure the backend environment outside git:

```bash
DOG_NOSE_EXTRACT_ENABLED=true
DOG_NOSE_DETECTOR_BACKEND=yolov5_legacy
DOG_NOSE_DETECTOR_WEIGHTS=<absolute-local-best.pt>
DOG_NOSE_YOLOV5_REPO=<absolute-local-yolov5-dir>
```

If detector settings or weights are missing, a
`profile_nose_preview.failure_reason` of `DETECTOR_UNAVAILABLE` is expected and
does not mean the Flutter request failed.

Android emulator:

```bash
cd app
flutter run \
  --dart-define=API_BASE_URL=http://3.35.4.4/api \
  --dart-define=FILE_BASE_URL=http://3.35.4.4/files/ \
  --dart-define=ENABLE_FIREBASE=false \
  --dart-define=DEV_USER_ID=1
```

Physical device:

```bash
cd app
flutter run \
  --dart-define=API_BASE_URL=http://3.35.4.4/api \
  --dart-define=FILE_BASE_URL=http://3.35.4.4/files/ \
  --dart-define=ENABLE_FIREBASE=false \
  --dart-define=DEV_USER_ID=1
```

`DEV_USER_ID` is only a local fallback for the current profile-draft dev flow.
When login stores `user_id`, the app uses that value first. Firebase, chat,
push, and the backend five-image nose verification implementation are outside
this profile draft preview check.
