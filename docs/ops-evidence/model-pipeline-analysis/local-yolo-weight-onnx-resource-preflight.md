# Local YOLO Weight + ONNX Resource Preflight

Date: 2026-06-21

Branch: `test/local-yolo-weight-onnx-resource-preflight`

Base develop SHA: `c912b3c0144491204bd05fec82897906dcdf3db8`

This is local technical validation only. It does not enable YOLO, ONNX Runtime, profile-first flow, or any production deployment default.

## Artifact Discovery

Safe roots searched:

- Original dirty PetNose worktree as read-only source.
- Original worktree `.codex_local/reference_repos`.
- Original worktree `backend/dogback` candidate path.
- PetNose/model-related directories under the original worktree parent.
- Explicit fixture directory referenced by prior local metadata.

Search terms included `DI-LEE`, `dognose_recognition_management_service`, `dogback`, `yolov05`, `yolov5`, `best.pt`, `last.pt`, `hubconf.py`, `DOG_NOSE_DETECTOR_WEIGHTS`, `DOG_NOSE_YOLOV5_REPO`, and `DOG_NOSE_DETECTOR_BACKEND`.

Unique selected artifacts:

| Kind | Safe id | Basename | Size bytes | SHA-256 | Status |
| --- | --- | ---: | ---: | --- | --- |
| YOLO repo | `reference_repos/dognose_recognition_management_service/backend/dogback/yolov05` | `hubconf.py` | 7880 | `31eb274fd9f25a32240005077ae105ddd160a461a2870d39a34f663faf983b20` | selected |
| YOLO weight | `reference_repos/dognose_recognition_management_service/crop_dognose_yoloV5/runs/train/dog_nose_yolov5n_14/weights` | `best.pt` | 3782269 | `a43cbdbb3da3346b93134f6ca1151eda3f75982f41262d6cd26c9163de42d402` | selected |
| YOLO alternate | same run weights directory | `last.pt` | 3782269 | `6c9d26a9c20636dbce937e056538dfdd64ce5a4903d72935ea25e073ec2bc417` | not selected |
| Embedding checkpoint | `dog_nose_identification2/logs/s101_224` | `model_final.pth` | 702987378 | `7868f51018b8f36b900302c0203ff14258db542925f69367f30711f65847bd4d` | selected |
| Exported ONNX | external temp output | `dog_nose_s101_224.onnx` | 185108431 | `a1afff51f868b077c114135c945ca92bcfbebeee7eb9c2bbd054fefec713019a` | generated outside repo |

Pairing basis:

- PetNose POC docs identify DI-LEE local clone and `backend/dogback/yolov05`.
- DI-LEE `crop_dognose_yoloV5/detect.py` defaults to `runs/train/dog_nose_yolov5n_14/weights/best.pt`.
- `hubconf.py` exists in the selected local YOLOv5 directory.
- Isolated load succeeded for `yolov5_legacy` with model names `{0: "dog_nose"}`.
- `best.pt` is tracked inside the imported reference repo, but ignored by the PetNose worktree through `.codex_local/`; it is not copied or staged.

License/provenance: `LICENSE_PARTIAL`. The imported repository has README provenance but no top-level license found. Included YOLOv5 source license files are present. The detector weight and dataset license remain unresolved for production use.

## Environment

Isolated runtime:

- Separate virtualenv under external temp storage.
- Python 3.12.13.
- PyTorch `2.3.1+cu121`, torchvision `0.18.1+cu121`.
- ONNX `1.16.1`, ONNX Runtime `1.18.1`.
- GPU observed: NVIDIA GeForce RTX 3070, 8192 MiB.
- Legacy YOLOv5 required `setuptools<81` because the source imports `pkg_resources`.

Local runtime variables used:

```text
DOG_NOSE_EXTRACT_ENABLED=true
DOG_NOSE_DETECTOR_BACKEND=yolov5_legacy
DOG_NOSE_DETECTOR_WEIGHTS=<selected best.pt>
DOG_NOSE_YOLOV5_REPO=<selected yolov05 repo>
DOG_NOSE_DETECTOR_DEVICE=cpu or cuda:0
EMBED_MODEL=dog-nose-identification2
DOG_NOSE_RUNTIME=torch or onnxruntime
EMBED_DEVICE=cpu or cuda:0
DOG_NOSE_ONNX_PATH=<external temp ONNX>
PROFILE_NOSE_MATCH_THRESHOLD=0.65
PROFILE_NOSE_MATCH_MIN_PASS_COUNT=4
PROFILE_NOSE_MATCH_AGGREGATE=median
```

## YOLO Load And Detection

| Case | Actual device | Load | Class names | Positive profile | Close-up detector attempts | Invalid image |
| --- | --- | --- | --- | --- | --- | --- |
| YOLO CPU | `cpu` | PASS | `{0: "dog_nose"}` | extracted, confidence `0.954840`, crop `224x224` | 5 close-up nose inputs returned `NO_NOSE_DETECTED` | `INVALID_IMAGE` |
| YOLO CUDA | `cuda:0` | PASS | `{0: "dog_nose"}` | extracted, confidence `0.954842`, crop `224x224` | 5 close-up nose inputs returned `NO_NOSE_DETECTED` | not repeated |

Only one profile/face positive fixture was found in the allowed local roots. The five close-up nose fixtures are valid embedding/profile-match inputs, not positive face/profile detector fixtures.

Detection latency and resources:

| Case | Runs | Total p50 ms | Total p95 ms | YOLO predict p50 ms | YOLO predict p95 ms | Process RSS peak MiB | GPU util peak | VRAM peak MiB |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| YOLO CPU | 177 | 82.237 | 96.270 | 55.262 | 69.154 | 783.434 | observed background | observed background |
| YOLO CUDA | 338 | 42.816 | 53.079 | 15.839 | 24.055 | 1237.234 | 45% | 2530 |

CPU-only runs still sampled `nvidia-smi`; GPU readings there are not attributed to the CPU detector workload.

## ONNX Export And Parity

ONNX export:

- Opset: 17.
- Dynamic batch: yes.
- `onnx.checker`: PASS.
- Input shape: dynamic batch with `3x224x224` image tensor.
- Output dimension: 2048.
- NaN/Inf: none observed in vector compare outputs.
- Artifact was written outside the repository and is not committed.

Vector parity:

| Compare | Fixtures | Min cosine | Max abs diff | Max L2 diff | Gate |
| --- | ---: | ---: | ---: | ---: | --- |
| PyTorch CPU vs ONNX CPU | 5 | 1.0 | `6.50761649e-08` | `6.51844573e-07` | PASS |
| PyTorch CUDA vs ONNX CPU | 5 | 1.0 | `1.08033419e-07` | `7.44004240e-07` | PASS |

Investigation note: default CUDA TF32 math initially produced max absolute difference above `1e-5`. TF32 is now disabled by default in the PyTorch CUDA embedder, with `DOG_NOSE_CUDA_ALLOW_TF32=true` reserved for exploratory performance checks that must re-run parity.

## Direct Embedding Benchmark

| Runtime | Device | Batch | Total p50 ms | Total p95 ms | Per-image p50 ms | Per-image p95 ms |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| PyTorch | CPU | 1 | 1365.589 | 1804.893 | 1365.589 | 1804.893 |
| PyTorch | CPU | 5 | 3380.324 | 4056.352 | 676.065 | 811.270 |
| PyTorch | CUDA | 1 | 30.742 | 34.767 | 30.742 | 34.767 |
| PyTorch | CUDA | 5 | 66.394 | 68.689 | 13.279 | 13.738 |
| ONNX Runtime | CPU | 1 | 109.360 | 126.542 | 109.360 | 126.542 |
| ONNX Runtime | CPU | 5 | 411.888 | 452.188 | 82.378 | 90.438 |

CUDA timings call `torch.cuda.synchronize()` before and after measured PyTorch work.

## Integrated Pipeline

Profile fixture plus five close-up nose fixtures:

| Case | Runs | Total p50 ms | Total p95 ms | YOLO p50 ms | Embed p50 ms | Pass count | Median score | Resource peak |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| YOLO CPU -> PyTorch CPU | 30 | 4055.302 | 4288.071 | 32.745 | 3987.190 | 5/5 | 0.772269 | RSS 1130.945 MiB |
| YOLO CUDA -> PyTorch CUDA | 129 | 116.561 | 127.486 | 14.162 | 70.069 | 5/5 | 0.772269 | GPU 76%, VRAM 4254 MiB |
| YOLO CUDA -> ONNX CPU | 30 | 539.025 | 621.981 | 14.478 | 498.822 | 5/5 | 0.772269 | RSS 1600.195 MiB |

Stage latency for the recommended CUDA path:

| Stage | p50 ms | p95 ms |
| --- | ---: | ---: |
| image decode | 5.398 | 5.882 |
| YOLO model predict | 14.162 | 18.491 |
| bbox filtering | 0.007 | 0.009 |
| square crop | 0.073 | 0.101 |
| resize/PNG encode | 14.627 | 19.951 |
| embedding preprocessing | 7.221 | 9.826 |
| embedding inference | 70.069 | 74.948 |
| L2 normalization | 0.596 | 0.859 |
| similarity aggregation | 1.369 | 1.452 |
| total | 116.561 | 127.486 |

## FastAPI Endpoint Validation

Each runtime was started on a separate localhost port and stopped after validation.

| Runtime case | `/health` | `/health/ready` | `/embed` | `/embed-batch` | `/internal/nose/extract` | `/internal/nose/profile-match` | `/internal/nose/profile-match-batch` |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| YOLO + PyTorch CPU | 200 | 200 | 200 | 200 | 200 | 200 | 200 |
| YOLO + PyTorch CUDA | 200 | 200 | 200 | 200 | 200 | 200 | 200 |
| YOLO + ONNX Runtime CPU | 200 | 503 policy | 200 | 200 | 200 | 200 | 200 |

ONNX `/health/ready` remains `not_ready` with `BACKEND_MISMATCH` because current production readiness policy requires `torch+timm`. The ONNX inference endpoints returned 200 and valid 2048-dimensional outputs.

Profile-match-batch result for all three runtime cases:

- `profile_nose_extracted=true`
- `dimension=2048`
- `scores=5`
- `pass_count=5`
- `median_score=0.772269`
- `min_score=0.693301`
- `failure_reason=null`

## Decisions

| Area | Verdict | Notes |
| --- | --- | --- |
| YOLO weight discovery | PASS | Imported repo, documented `best.pt`, hubconf pairing, isolated load all confirmed. |
| YOLO functional | PASS with fixture limit | One positive profile fixture succeeds; close-up fixtures are not detector positives. |
| YOLO GPU | PASS | Actual device `cuda:0`, GPU utilization/VRAM observed, no silent CPU fallback, OOM 0. |
| ONNX embedding | PASS | Export/checker/parity/direct benchmark and endpoint contract validated; production readiness remains policy-blocked. |
| PyTorch CUDA embedding | PASS | Actual device `cuda:0`, dimension 2048, GPU/VRAM observed, OOM 0. |

Recommended AWS g4dn runtime to revalidate on T4: **YOLO CUDA + PyTorch CUDA**.

Basis:

- Best integrated latency among tested combinations.
- Profile-match-batch passed with `pass_count=5` and median score above 0.65.
- Strict ONNX parity passes after disabling CUDA TF32 by default.
- ONNX Runtime CPU is much faster than PyTorch CPU for model-only embedding, but slower than PyTorch CUDA for integrated local GPU runtime.
- Detector/license provenance is only partial, so production use requires separate license/security review or owned retraining.
- Local GPU is RTX 3070; these numbers are not T4/g4dn performance and must be re-run on AWS.

Production configuration status:

- No production `.env` default was changed.
- `deploy-real-model.sh` production guardrails were not changed.
- CD/release production defaults were not changed.
- Model artifacts, weights, crops, raw images, raw vectors, `.env`, and secrets were not committed.
