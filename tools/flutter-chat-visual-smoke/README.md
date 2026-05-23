# PetNose Flutter Chat Visual Smoke

This Flutter project is a manual visual smoke harness for Firebase chat. It is
not the production PetNose app UI. Keep production app implementation work under
`app/` and use this tool only to verify the optional Firebase chat layer.

## Purpose

Use this harness to visually confirm:

- Firebase custom token sign-in from the Spring API.
- Chat room creation through the Spring API.
- Message sending through the Spring API.
- Realtime message display through a Firestore listener.
- Read marking through the Spring API.
- Room list refresh through the Spring API.

The harness reads Firestore through realtime listeners only. It must not write
chat messages directly to Firestore.

## Backend Requirements

- Firebase-enabled Spring backend is running.
- Firestore database exists and rules are deployed.
- Local/dev CORS allows the Flutter web origin to call `/api/**`.
- Fixture data has been prepared with the backend smoke script.

For local Docker runtime, use the existing Firebase-enabled compose stack from
the repository root.

## Firebase Client Setup

Do not use or copy the Firebase server service account JSON into this Flutter
tool. Flutter needs Firebase client app config only.

From this directory:

```powershell
firebase login
dart pub global activate flutterfire_cli
flutterfire configure
```

Choose:

- Firebase project: `petnose-c6ec5`
- Platforms: Web and Android as needed

Generated client config files are ignored by default:

- `lib/firebase_options.dart`
- `android/app/google-services.json`
- `ios/Runner/GoogleService-Info.plist`
- `macos/Runner/GoogleService-Info.plist`
- `firebase.json`
- `.firebase/`

Keep these local unless the project explicitly approves committing Firebase
client config.

## Prepare Fixture

From the repository root:

```powershell
$fixtureEnv = Join-Path $env:TEMP ("petnose-firebase-chat-visual-env-" + (Get-Date -Format "yyyyMMddHHmmss") + ".ps1")

pwsh -NoProfile -File scripts/prepare-firebase-chat-smoke-fixture.ps1 `
  -BaseUrl "http://localhost:8080" `
  -NoseImagePath "C:\Dev\sample\nose_test1.jpg" `
  -ProfileImagePath "C:\Dev\sample\profile3.jpg" `
  -OutputEnvFile $fixtureEnv `
  -ProjectAlias "dev-firebase" `
  -Environment "local-dev-visual" `
  -FcmToken "<dummy-fcm-token-for-local-smoke>" `
  -Platform "WEB"

. $fixtureEnv
```

Do not paste JWTs, Firebase custom tokens, FCM tokens, or fixture env contents
into commits, docs, chat, or evidence logs.

## Run

```powershell
cd tools/flutter-chat-visual-smoke
flutter pub get
flutter analyze
flutter run -d chrome --web-hostname localhost --web-port 58123
```

Use these API base URLs:

- Chrome/web: `http://localhost:8080`
- Android emulator: `http://10.0.2.2:8080`
- Real device: `http://<PC-LAN-IP>:8080`

## App Inputs

- API base URL: use the target-specific value above.
- Spring Bearer token: use `PETNOSE_FIREBASE_SMOKE_BEARER_TOKEN` from the fixture env.
- `post_id`: use `PETNOSE_FIREBASE_SMOKE_POST_ID` from the fixture env.
- `room_id`: leave blank initially.
- Message text: any short smoke-test text.

To copy fixture values locally:

```powershell
. "<fixture env path>"
$env:PETNOSE_FIREBASE_SMOKE_BEARER_TOKEN | Set-Clipboard
$env:PETNOSE_FIREBASE_SMOKE_POST_ID | Set-Clipboard
```

Do not print or save the bearer token.

## Manual Steps

1. Get Firebase Custom Token.
2. Create / Get Chat Room.
3. Send Message.
4. Mark Read.
5. Refresh Room List.

## PASS Criteria

- `firebase_uid` appears.
- Signed-in Firebase uid appears.
- `room_id` appears.
- Firestore Room values appear when visible.
- Sent message appears in Realtime Messages.
- Room appears in Spring Room List.
- Optional: run two Chrome windows or two sessions with breeder/inquirer tokens
  and confirm bidirectional realtime chat.

Do not record PASS evidence until a person has visually confirmed the result.

## Security Notes

- Do not commit `.env`.
- Do not commit Spring JWTs.
- Do not commit Firebase custom tokens.
- Do not commit FCM tokens.
- Do not commit Firebase server service account JSON or private keys.
- Do not write chat messages directly to Firestore from Flutter.
- Message writes must go through the Spring Boot API.
