# Profile Nose Extraction POC

This is a local/dev POC for checking whether a close-up dog profile or face image can produce a usable nose crop before a later close-up nose image is compared.

Pipeline:

```text
profile dog face image
-> custom dog-nose YOLO bbox detection
-> padded square crop
-> resize to 224x224 RGB/PNG
-> existing dog-nose embedding pipeline for profile-vs-nose consistency check
```

## Boundaries

- This does not change backward compatibility for `POST /api/dogs/register`.
- The profile-first product flow uses `POST /api/dogs/profile-draft` followed by `POST /api/dogs/{dog_id}/nose-verification`.
- `nose_image` remains the canonical registration multipart field. Repeated `nose_image` parts are accepted for the current multi-reference flow; `nose_images` is a legacy alias for compatibility.
- Registration still requires user-provided close-up nose image input; `profile_image` is separate and cannot replace `nose_image`.
- The profile-derived crop is not silently substituted into registration.
- Python preview/profile-match endpoints write no rows to `dogs`, `dog_images`, `verification_logs`, or any other DB table.
- No Qdrant search or upsert happens from preview or profile-match endpoints.
- In the two-step flow, Qdrant search/upsert happens only after Spring verifies profile consistency and then runs the existing 5-image registration pipeline.
- No DB enum or schema value such as `NOSE_CROP`, `CROP`, or `PROFILE_DERIVED` is introduced.

`DI-LEE/dognose_recognition_management_service` was used only as a conceptual reference for the high-level idea: dog face/profile image -> YOLO nose bbox -> crop -> noseprint model. No source code, weights, assets, datasets, or license text from that repository are copied here. If a local POC points at a DI-LEE clone and checkpoint through environment variables, that is local validation only and must not be vendored into this repository.

Generic COCO YOLO dog/person weights are not sufficient for dog nose detection. This POC expects a custom dog-nose YOLO-compatible weight file.

## Python Internal Endpoints

Run inside `python-embed`.

```text
POST /internal/nose/extract
multipart/form-data:
  image: file required
```

Returns snake_case JSON with `extracted`, `crop_width`, `crop_height`, `confidence`, `bbox_xyxy`, `bbox_expand`, `detector`, `crop_base64`, and `failure_reason`.

```text
POST /internal/nose/profile-match
multipart/form-data:
  profile_image: file required
  nose_image: file required
```

This endpoint extracts a profile-derived nose crop, embeds that crop with the existing embedder, embeds the close-up `nose_image` with the same embedder, and returns cosine similarity JSON. It does not call Qdrant and does not persist images.

```text
POST /internal/nose/profile-match-batch
multipart/form-data:
  profile_image: file required
  nose_image: file repeated exactly 5
```

This endpoint extracts the profile-derived nose crop once, embeds that crop, embeds the 5 close-up nose images, and returns per-image cosine similarity scores plus aggregate diagnostics:

- `threshold=0.65`
- `threshold_calibrated=false`
- `required_pass_count=4`
- `aggregate=median`
- `pass_count`, `median_score`, `mean_score`, `min_score`, `max_score`
- `profile_nose_extracted`, `profile_confidence`, `profile_crop_width`, `profile_crop_height`
- `model`, `dimension`, `scores[]`, `failure_reason`

It returns a stable failure body instead of crashing when the detector is unavailable. It also treats non-2048 profile-match embeddings as `EMBEDDING_DIMENSION_MISMATCH`; `mock-v1`/128-dim output is not accepted as a successful profile consistency result.

## Spring Dev Endpoints

These are available only through the existing dev-profile controller:

```text
POST /api/dev/profile-nose-preview
multipart/form-data:
  profile_image: file required

POST /api/dev/profile-nose-match
multipart/form-data:
  profile_image: file required
  nose_image: file required
```

Spring only proxies to `python-embed` through `EmbedClient`; Flutter still does not call Python Embed or Qdrant directly.

## Spring Product Endpoints

These endpoints are release-gated. Production default is
`PETNOSE_PROFILE_FIRST_ENABLED=false`; disabled requests return HTTP `404` with
`PROFILE_FIRST_DISABLED` before auth resolution, DB writes, file writes, or Python
Embed calls. Use `404` so the default-off flow is not advertised as an active
production API surface.

```text
POST /api/dogs/profile-draft
multipart/form-data:
  user_id: long optional when Bearer token is present
  name: string required
  breed: string required
  gender: MALE | FEMALE | UNKNOWN required
  birth_date: YYYY-MM-DD optional
  description: string optional
  profile_image: file required

POST /api/dogs/{dog_id}/nose-verification
multipart/form-data:
  user_id: long optional when Bearer token is present
  nose_image: file repeated exactly 5
  nose_images: legacy alias, file repeated exactly 5
```

`profile-draft` stores `dogs.status=PENDING` and a single `dog_images.image_type=PROFILE`. It does not save `NOSE` images, does not create `verification_logs`, and does not call Qdrant.

`nose-verification` reads the stored profile image, calls Python `profile-match-batch`, and applies the Spring-side profile consistency policy before running the existing 5-image duplicate detection/registration flow. On profile mismatch, it leaves the dog `PENDING`, saves no `NOSE` images, writes no verification log, and does not call Qdrant.

## Environment

```bash
PETNOSE_PROFILE_FIRST_ENABLED=true
DOG_NOSE_RUNTIME=torch
DOG_NOSE_EXTRACT_ENABLED=true
DOG_NOSE_DETECTOR_WEIGHTS=/absolute/path/to/dog_nose_yolo.pt
DOG_NOSE_DETECTOR_BACKEND=ultralytics
DOG_NOSE_YOLOV5_REPO=/absolute/path/to/local/yolov5/repo
DOG_NOSE_DETECTOR_DEVICE=cpu
DOG_NOSE_DETECT_CONF_THRESHOLD=0.35
DOG_NOSE_CROP_SIZE=224
DOG_NOSE_BBOX_EXPAND=1.40
DOG_NOSE_CLASS_ID=0
DOG_NOSE_CLASS_NAMES=nose,dog_nose,pet_nose
PROFILE_NOSE_MATCH_THRESHOLD=0.65
PROFILE_NOSE_MATCH_MIN_PASS_COUNT=4
PROFILE_NOSE_MATCH_AGGREGATE=median
```

`PETNOSE_PROFILE_FIRST_ENABLED` defaults to `false`. Keep it false for production
until detector availability, latency, threshold calibration, and regression gates
are complete.

`DOG_NOSE_EXTRACT_ENABLED` defaults to `false`. If Ultralytics is not installed, the env var is false, the legacy local YOLOv5 repo is missing, or the custom weight file is missing, the service still starts and extraction returns `DETECTOR_UNAVAILABLE`.

`DOG_NOSE_DETECTOR_BACKEND` defaults to `ultralytics` to preserve the original optional adapter behavior. `yolov5_legacy` is only for local POC validation of legacy YOLOv5 checkpoints and requires `DOG_NOSE_YOLOV5_REPO` to point at a local YOLOv5 directory containing `hubconf.py`. For the DI-LEE clone checked in `.codex_local/reference_repos`, the working local YOLOv5 directory is `backend/dogback/yolov05`.

`DOG_NOSE_DETECTOR_DEVICE` defaults to `cpu` for backward-compatible local behavior. For local benchmark only, set `cuda`, `cuda:0`, or `auto`; explicit CUDA requests fail instead of silently falling back to CPU when CUDA is unavailable.

`PROFILE_NOSE_MATCH_THRESHOLD` is an uncalibrated local dev value. The current dev observation threshold is `0.65`; the earlier POC value `0.75` was temporary. It must be tuned later with positive and negative dog-pair data before any production identity decision depends on it. This setting is separate from production registration duplicate thresholds and does not change the existing Qdrant duplicate threshold.

Current ddubi local POC result with DI-LEE dog-nose YOLOv5 `best.pt`:

| input | profile crop similarity |
| --- | ---: |
| `1.png` | `0.771138` |
| `2.png` | `0.772269` |
| `3.png` | `0.693301` |
| `4.png` | `0.816335` |
| `5.png` | `0.777755` |

Detector confidence was `0.95484`; auto crop size was `224x224`. All five scores pass the dev/demo `0.65` threshold. This is not production calibration evidence.

Ultralytics is intentionally optional and not installed by the default requirements file:

```bash
pip install ultralytics
```

Legacy YOLOv5 checkpoint loading executes local YOLOv5 Python code and deserializes a PyTorch `.pt` checkpoint. Treat public checkpoints as untrusted pickle input: run this only in an isolated local POC container. DI-LEE has no top-level license in the cloned repository, and the included YOLOv5 code is GPL-3.0, so production use requires license/security review or retraining with our own labels.

## Local Checks

Python tests:

```bash
cd python-embed
pytest -q
```

Spring tests:

```bash
cd backend
gradle test
```

Manual extraction check, only when custom dog-nose YOLO weights are available:

```bash
curl -s -X POST http://localhost:8000/internal/nose/extract \
  -F "image=@/absolute/path/to/profile_dog_face.jpg" | jq .
```

Expected with valid custom weights:

- `extracted=true`
- `crop_width=224`
- `crop_height=224`
- `confidence` is present
- `crop_base64` is present

Manual profile-vs-nose match check, only when the detector and embed model are loaded:

```bash
curl -s -X POST http://localhost:8000/internal/nose/profile-match \
  -F "profile_image=@/absolute/path/to/profile_dog_face.jpg" \
  -F "nose_image=@/absolute/path/to/nose_closeup.jpg" | jq .
```

Manual profile-vs-5-nose batch check:

```bash
curl -s -X POST http://localhost:8000/internal/nose/profile-match-batch \
  -F "profile_image=@/absolute/path/to/profile_dog_face.jpg" \
  -F "nose_image=@/absolute/path/to/1.png" \
  -F "nose_image=@/absolute/path/to/2.png" \
  -F "nose_image=@/absolute/path/to/3.png" \
  -F "nose_image=@/absolute/path/to/4.png" \
  -F "nose_image=@/absolute/path/to/5.png" | jq .
```
