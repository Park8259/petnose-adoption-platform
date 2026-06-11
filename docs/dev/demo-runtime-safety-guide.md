# Demo runtime safety guide for ONNX/runtime and profile-nose detector POC

This guide keeps local demos from accidentally changing the production registration path.

## Default runtime

- Keep the demo default on the existing torch embedder.
- Use `DOG_NOSE_RUNTIME=torch`, or leave `DOG_NOSE_RUNTIME` unset.
- Do not set `DOG_NOSE_RUNTIME=onnxruntime` in shared demo, production, or compose defaults until CPU latency and vector parity are proven.
- Confirm the real model before any identity demo:

```bash
curl -s http://localhost:8080/api/dev/embed-sample
```

Expected real-model shape:

```text
model=dog-nose-identification2:s101_224
dimension=2048
vector_length=2048
```

`mock-v1` with 128 dimensions is useful for smoke tests only. It is not a substitute for real dog-nose verification.

## Profile-nose detector demo

Run the detector only against local/dev endpoints:

```text
POST /api/dev/profile-nose-preview
POST /api/dev/profile-nose-match
POST /api/dogs/profile-draft
POST /api/dogs/{dog_id}/nose-verification
```

or, when Spring is not running:

```text
POST /internal/nose/extract
POST /internal/nose/profile-match
POST /internal/nose/profile-match-batch
```

Use these variables only in the local demo shell or disposable container:

```bash
DOG_NOSE_EXTRACT_ENABLED=true
DOG_NOSE_DETECTOR_BACKEND=yolov5_legacy
DOG_NOSE_DETECTOR_WEIGHTS=/absolute/local/path/to/best.pt
DOG_NOSE_YOLOV5_REPO=/absolute/local/path/to/yolov5
PROFILE_NOSE_MATCH_THRESHOLD=0.65
PROFILE_NOSE_MATCH_MIN_PASS_COUNT=4
PROFILE_NOSE_MATCH_AGGREGATE=median
```

If `DOG_NOSE_DETECTOR_WEIGHTS` or the detector runtime is unavailable, the expected response is `extracted=false` with `failure_reason=DETECTOR_UNAVAILABLE`.

Do not use generic COCO YOLO dog/person weights as dog-nose detector weights.

## Local-only DI-LEE checkpoint

The DI-LEE `best.pt` checkpoint is local demo material only.

- Do not copy it into this repository.
- Do not commit `.pt`, `.pth`, `.onnx`, `.weights`, `.pb`, or generated crops/reports.
- Do not put detector weight paths into production compose or deploy config.
- Treat legacy YOLOv5 `.pt` loading as untrusted checkpoint execution. Use an isolated local container for validation.
- Production use requires separate license/security review or a retrained detector owned by this project.

## Registration boundary

Accepted-dog Qdrant upsert still happens only inside the Spring dog registration pipeline.

- `nose_image` is the canonical multipart field name.
- Repeated `nose_image` parts are accepted by the current multi-reference flow.
- `nose_images` is accepted only as a legacy alias.
- `profile_image` must not replace `nose_image`.
- A profile-derived crop must not be silently inserted into registration.
- Duplicate detection and conditional Qdrant upsert behavior must remain unchanged.
- In the profile-first flow, `POST /api/dogs/profile-draft` creates only `dogs.status=PENDING` plus a `PROFILE` image.
- `POST /api/dogs/{dog_id}/nose-verification` calls profile consistency first and enters Qdrant duplicate search/upsert only after the profile-vs-5-nose check passes.
- On profile mismatch, the dog remains `PENDING`, no `NOSE` images are stored, no `verification_logs` row is created, and Qdrant is not called.

## POC endpoint boundary

Profile-nose preview and profile-match are dev/local observation endpoints.

- They do not write `dogs`.
- They do not write `dog_images`.
- They do not write `verification_logs`.
- They do not write `adoption_posts`.
- They do not call Qdrant search or upsert.
- `threshold_calibrated=false` means the score is not a production identity decision.
- The batch profile-match endpoint requires real 2048-dim model output for a successful result. `mock-v1`/128-dim smoke output must not be treated as a valid identity decision.
- The profile-nose threshold defaults are `0.65`, min pass count `4`, and aggregate `median`. These are separate from the existing Qdrant duplicate threshold.

## Disposable E2E before merge

Run full Docker E2E only against a disposable DB/Qdrant stack:

```text
/api/dev/embed-sample returns vector_length=2048
POST /api/dogs/profile-draft with a profile image returns PENDING and one PROFILE dog_image
POST /api/dogs/{dog_id}/nose-verification with five accepted nose images returns profile_match_allowed=true
POST /api/dogs/register first registration returns HTTP 201 and registration_allowed=true
Duplicate same-image registration returns HTTP 200 and registration_allowed=false
Qdrant count includes only accepted registered dogs
/files URL for the uploaded image returns HTTP 200
```
