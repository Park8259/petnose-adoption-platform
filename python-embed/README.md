# python-embed — 비문 임베딩 서비스

## 역할
- Spring Boot에서만 호출되는 비문 임베딩 생성 서비스
- `/embed` 응답 계약 유지: `status`, `vector`, `dimension`, `model`
- `/embed-batch`는 여러 이미지를 한 요청에서 임베딩하되, backend 연동 전용 API로 유지
- Flutter는 직접 호출하지 않음

## 지원 모드
- `EMBED_MODEL=mock-v1` (기본)
- `EMBED_MODEL=dog-nose-identification2` (실제 모델)

## 모드별 의존성 정책
- 기본 `requirements.txt`는 mock 회귀/CI 경량 유지를 위한 최소 의존성과 profile nose crop POC용 Pillow만 포함
- 실제 모델 의존성은 `requirements-real.txt`로 분리
- Docker 빌드 인자 `PYTHON_EMBED_INSTALL_REAL_DEPS=1`일 때만 실제 모델 의존성 설치
- ONNX Runtime 의존성은 `requirements-onnx.txt`로 분리하며 Docker 빌드 인자 `INSTALL_ONNX_RUNTIME_DEPS=1`일 때만 설치
- Ultralytics 또는 legacy YOLOv5 local repo runtime은 custom dog-nose YOLO weights가 있는 로컬 POC에서만 별도 설치/참조

## 환경변수
- `EMBED_MODEL` (`mock-v1` | `dog-nose-identification2`)
- `EMBED_VECTOR_DIM` (mock 출력 차원, 기본 128)
- `EMBED_DEVICE` (기본 `cpu`)
- `DOG_NOSE_MODEL_DIR` (기본 `/models/dog_nose_identification2`)
- `DOG_NOSE_MODEL_PATH` (선택, checkpoint 직접 지정)
- `DOG_NOSE_RUNTIME` (`torch` | `onnxruntime`, 기본 `torch`)
- `DOG_NOSE_ONNX_PATH` (선택, `DOG_NOSE_RUNTIME=onnxruntime`일 때 exported `.onnx` 직접 지정)
- `DOG_NOSE_ORT_INTRA_OP_THREADS`, `DOG_NOSE_ORT_INTER_OP_THREADS` (선택, ONNX Runtime CPU thread 설정)
- `DOG_NOSE_CUDA_ALLOW_TF32` (`true` | `false`, 기본 `false`; CUDA PyTorch/ONNX parity 보존용)
- `DOG_NOSE_EXTRACT_ENABLED` (`true` | `false`, 기본 `false`)
- `DOG_NOSE_DETECTOR_WEIGHTS` (custom dog-nose YOLO weight 경로)
- `DOG_NOSE_DETECTOR_BACKEND` (`ultralytics` | `yolov5_legacy`, 기본 `ultralytics`)
- `DOG_NOSE_YOLOV5_REPO` (`DOG_NOSE_DETECTOR_BACKEND=yolov5_legacy`일 때 local YOLOv5 repo 경로, `hubconf.py` 필요)
- `DOG_NOSE_DETECTOR_DEVICE` (`cpu` | `cuda` | `cuda:0` | `auto`, 기본 `cpu`)
- `DOG_NOSE_DETECT_CONF_THRESHOLD` (기본 `0.35`)
- `DOG_NOSE_CROP_SIZE` (기본 `224`)
- `DOG_NOSE_BBOX_EXPAND` (기본 `1.40`)
- `DOG_NOSE_CLASS_ID` (기본 `0`)
- `DOG_NOSE_CLASS_NAMES` (기본 `nose,dog_nose,pet_nose`)
- `PROFILE_NOSE_MATCH_THRESHOLD` (기본 `0.65`, calibration 전 dev 값; registration duplicate threshold와 별도)
- `MAX_IMAGE_BYTES` (기본 20MB)
- `MAX_BATCH_IMAGES` (`/embed-batch` 요청당 최대 이미지 수, 기본 5)
- `MAX_BATCH_TOTAL_BYTES` (`/embed-batch` 요청 전체 이미지 크기 합계 제한, 기본 80MB)

`DOG_NOSE_DETECTOR_BACKEND=yolov5_legacy`는 local POC 전용입니다. local YOLOv5 repo code와 PyTorch `.pt` checkpoint를 실행/역직렬화하므로, public checkpoint는 격리된 컨테이너에서만 검증하고 production 반영 전 라이선스/보안 검토가 필요합니다.
`DOG_NOSE_DETECTOR_DEVICE`는 local/dev detector 실행 장치만 제어합니다. 기본값은 기존 동작과 같은 `cpu`이며, `cuda` 또는 `cuda:0`을 명시했는데 CUDA를 사용할 수 없으면 CPU로 조용히 fallback하지 않고 detector load가 실패합니다. `auto`는 CUDA가 있으면 `cuda:0`, 없으면 `cpu`를 선택합니다.
CUDA PyTorch embedding은 ONNX Runtime CPU와의 strict parity를 위해 TF32를 기본적으로 끕니다. 성능 탐색용으로만 `DOG_NOSE_CUDA_ALLOW_TF32=true`를 사용할 수 있으며, 이 경우 ONNX parity gate를 별도로 재확인해야 합니다.

## Health 응답
기존 키(`status`, `model_loaded`, `model`, `vector_dim`)는 유지하며 디버깅 필드를 추가합니다.

```json
{
  "status": "ok",
  "model_loaded": true,
  "model": "dog-nose-identification2:s101_224",
  "vector_dim": 2048,
  "backend": "torch+timm",
  "device": "cpu",
  "model_path_exists": true
}
```

## Mock-v1 회귀 실행
```bash
docker compose --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.dev.yaml \
  up -d --build
```

```bash
curl -X POST http://localhost:8000/embed -F "image=@/path/to/nose.jpg"
```

기대:
- `model=mock-v1`
- `dimension=128`

Batch 요청:

```bash
curl -X POST http://localhost:8000/embed-batch \
  -F "images=@/path/to/nose-1.jpg" \
  -F "images=@/path/to/nose-2.jpg"
```

응답:

```json
{
  "status": "ok",
  "model": "mock-v1",
  "dimension": 128,
  "count": 2,
  "items": [
    {
      "index": 0,
      "filename": "nose-1.jpg",
      "vector": "<2048-dim vector omitted>"
    }
  ]
}
```

## 실제 모델 실행 (Docker)
1. `infra/docker/.env` 설정
- `EMBED_MODEL=dog-nose-identification2`
- `PYTHON_EMBED_INSTALL_REAL_DEPS=1`
- `DOG_NOSE_MODEL_DIR_HOST=<host-model-dir>`
- `QDRANT_COLLECTION=dog_nose_embeddings_real_v1` (권장)
- `QDRANT_VECTOR_DIM=2048` (현재 분석 기준)

2. 오버라이드 파일 포함 실행
```bash
docker compose --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.dev.yaml \
  -f infra/docker/compose.real-model.yaml \
  up -d --build
```

3. 확인
```bash
curl http://localhost:8000/health
curl -X POST http://localhost:8000/embed -F "image=@/path/to/nose.jpg"
curl -X POST http://localhost:8000/embed-batch \
  -F "images=@/path/to/nose-1.jpg" \
  -F "images=@/path/to/nose-2.jpg"
```

## Qdrant 차원 주의
- Qdrant collection 차원은 변경 불가
- mock(128)과 real(2048) 혼용 금지
- real 테스트는 별도 collection 권장

## 같은 이미지 2회 등록 테스트 (Spring 파이프라인)
seed user(`user_id=1` 등)가 이미 존재한다고 가정:

```powershell
curl.exe -i -X POST "http://localhost/api/dogs/register" `
  -F "user_id=1" `
  -F "name=초코" `
  -F "breed=말티즈" `
  -F "gender=MALE" `
  -F "birth_date=2023-01-01" `
  -F "description=real model first register" `
  -F "nose_image=@<sample-dir>\1.jpg;type=image/jpeg"
```

```powershell
curl.exe -i -X POST "http://localhost/api/dogs/register" `
  -F "user_id=1" `
  -F "name=초코-중복시도" `
  -F "breed=말티즈" `
  -F "gender=MALE" `
  -F "birth_date=2023-01-01" `
  -F "description=real model duplicate test" `
  -F "nose_image=@<sample-dir>\1.jpg;type=image/jpeg"
```

기대:
- 1회차 `registration_allowed=true`, `embedding_status=COMPLETED`
- 2회차 `registration_allowed=false`, `verification_status=DUPLICATE_SUSPECTED`

## 모델 파일 커밋 금지
- `.pt`, `.pth`, `.ckpt`, `.onnx`, `.h5`, `.keras` 등 weight 파일은 git 커밋 금지
- 모델은 외부 경로/볼륨 마운트로 주입

## Local benchmark tooling

`scripts/onnx_runtime_experiment.py`는 PR #108의 batch inference 및 ONNX Runtime 근거를 로컬에서 다시 생성하기 위한 benchmark 도구입니다. production runtime을 켜는 절차가 아니며, 현재 production 기본값은 `DOG_NOSE_RUNTIME=torch`입니다.

범위:
- `export`, `compare`, `benchmark`: `benchmark_scope=local-model-only`
- `batch-compare`: `benchmark_scope=local-direct-embedder`
- FastAPI, Spring Boot, Docker, AWS end-to-end latency는 포함하지 않음

Optional dependencies:
- PyTorch/timm 실제 모델 실행: `requirements-real.txt`
- ONNX export/checker/runtime 실험: `requirements-onnx.txt`

```bash
pip install -r requirements-real.txt -r requirements-onnx.txt
```

PR #108 evidence 재현 예시:

```bash
python scripts/onnx_runtime_experiment.py batch-compare \
  --model-dir <model-dir> \
  --model-path <checkpoint-path> \
  --fixtures <fixture-dir> \
  --batch-size 5 \
  --warmup 2 \
  --runs 10 \
  --output-dir <output-dir>
```

```bash
python scripts/onnx_runtime_experiment.py export \
  --model-dir <model-dir> \
  --model-path <checkpoint-path> \
  --output <output-dir>/dog_nose_s101_224.onnx \
  --summary-json <output-dir>/export_summary.json

python scripts/onnx_runtime_experiment.py compare \
  --model-dir <model-dir> \
  --model-path <checkpoint-path> \
  --onnx <output-dir>/dog_nose_s101_224.onnx \
  --fixtures <fixture-dir> \
  --output-dir <output-dir>

python scripts/onnx_runtime_experiment.py benchmark \
  --model-dir <model-dir> \
  --model-path <checkpoint-path> \
  --onnx <output-dir>/dog_nose_s101_224.onnx \
  --fixtures <fixture-dir> \
  --batch-sizes 1,5 \
  --warmup 3 \
  --runs 20 \
  --output-dir <output-dir>
```

출력:
- `<output-dir>/*_summary.json`
- `<output-dir>/*.csv`
- console JSON summary

Sanitization policy:
- fixture label 기본값은 `--label-mode index`이며, 안전한 파일명만 필요할 때 `--label-mode basename`을 사용할 수 있음
- JSON/CSV/console summary에는 절대 fixture/model/checkpoint/ONNX 경로를 쓰지 않음
- raw image bytes와 raw embedding vector를 저장하지 않음
- 생성된 `.onnx`, checkpoint(`.pt`, `.pth`, `.ckpt`), raw image, raw vector, benchmark temp output은 Git commit 금지

## Optional ONNX Runtime readiness

- Production 기본값은 `DOG_NOSE_RUNTIME=torch`이며 ONNX는 optional/default-off 경로입니다.
- ONNX dependency는 기본 Python/Docker image에 설치하지 않으며, 명시적으로 `pip install -r requirements-onnx.txt` 또는 Docker build arg `INSTALL_ONNX_RUNTIME_DEPS=1`을 사용한 경우에만 설치합니다.
- 실제 checkpoint와 exported `.onnx` artifact는 Git commit 금지입니다. production server에서 export 또는 benchmark를 실행하지 않습니다.
- CI의 optional ONNX smoke는 test temp directory와 runner temp directory에 synthetic ONNX graph를 생성해 adapter, Docker dependency, `/health`, `/embed`, `/embed-batch` contract만 검증합니다.
- Synthetic smoke는 실제 dog-nose 모델 정확도, PyTorch parity, latency를 검증하지 않습니다. 실제 ONNX parity/latency 근거는 PR #108 evidence를 참고합니다.

통계 정의:
- Mean: 모든 측정 latency의 산술 평균
- P50: 측정 latency의 중앙값
- P95: 측정값의 95번째 백분위
- Warm-up run: 통계 집계에서 제외
- Percentile: 정렬된 측정값 사이를 linear interpolation으로 계산
