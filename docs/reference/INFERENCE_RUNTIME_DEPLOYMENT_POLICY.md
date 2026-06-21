# Inference Runtime Deployment Policy

> 문서 성격: 운영 배포 정책(Task Reference)
>
> ONNX/YOLO optional 코드가 main에 포함되어도 현재 production 서버에서 어떤
> inference runtime을 실제로 켤 수 있는지 판단할 때 이 문서를 우선 확인한다.

---

## Current Demo Production

현재 시연 production은 단일 서버 구성을 기준으로 한다.

- Nginx
- Spring Boot
- MySQL
- Qdrant
- Python Embed

현재 production inference path는 Python Embed의 PyTorch `/embed-batch` runtime이다.

```dotenv
EMBED_MODEL=dog-nose-identification2
EMBED_VECTOR_DIM=2048
DOG_NOSE_RUNTIME=torch
DOG_NOSE_EXTRACT_ENABLED=false
PETNOSE_PROFILE_FIRST_ENABLED=false
PETNOSE_REGISTRATION_TIMING_LOG_ENABLED=false
PYTHON_EMBED_INSTALL_REAL_DEPS=1
```

Production image는 반드시 immutable main tag를 사용한다.

```dotenv
SPRING_API_IMAGE=ghcr.io/jaaesung/petnose-spring-api:main-<sha7>
PYTHON_EMBED_REAL_IMAGE=ghcr.io/jaaesung/petnose-python-embed-real:main-<sha7>
```

g4dn.xlarge GPU 배포는 같은 PyTorch runtime을 NVIDIA T4 CUDA device에서
실행하는 명시적 opt-in 경로다. 이 경로도 ONNX/YOLO/profile-first를 켜지 않는다.

```dotenv
PYTHON_EMBED_GPU_REAL_IMAGE=ghcr.io/jaaesung/petnose-python-embed-gpu-real:main-<sha7>
EMBED_DEVICE=cuda:0
EMBED_DEVICE_REQUIRED=true
PETNOSE_INCLUDE_GPU=true
```

현재 production release에서는 아래 값을 허용하지 않는다.

- `DOG_NOSE_RUNTIME=onnxruntime`
- `DOG_NOSE_EXTRACT_ENABLED=true`
- `PETNOSE_PROFILE_FIRST_ENABLED=true`
- `PETNOSE_REGISTRATION_TIMING_LOG_ENABLED=true`
- `main-latest`
- `develop-latest`
- `develop-<sha7>`
- local image tag
- generated ONNX artifact
- YOLO weight

Production GPU 배포에서도 `PYTHON_EMBED_GPU_REAL_IMAGE`는 immutable
`main-<sha7>`만 허용한다. `main-latest`와 `develop-*` GPU image tag는
production에서 금지한다.

---

## Code Inclusion vs Runtime Activation

ONNX source/test가 main에 존재하는 것과 production에서 ONNX runtime을 활성화하는 것은 다르다.

YOLO/profile-first source가 main에 존재하는 것과 production에서 detector/profile-first API를 활성화하는 것도 다르다.

현재 production 서버는 ONNX와 YOLO/profile-first를 default-off로 유지한다. 운영 활성화는 별도 승인된 inference deployment path에서만 다룬다.

---

## Artifact Policy

아래 artifact와 secret은 Git commit 금지다.

- `*.pth`
- `*.pt`
- `*.ckpt`
- `*.onnx`
- YOLO weights
- raw dog images
- raw vectors
- `.env`
- service account JSON

현재 production artifact는 서버 파일시스템에만 존재한다.

```text
/opt/petnose/models/dog_nose_identification2/logs/s101_224/model_final.pth
```

ONNX artifact와 YOLO weight는 현재 production 서버에 배치하지 않는다.

---

## Rollback

Release rollback은 image tag와 env policy를 되돌리는 방식으로 수행한다.

1. 이전 known-good `main-<sha7>` image tag로 `SPRING_API_IMAGE`와 `PYTHON_EMBED_REAL_IMAGE`를 복귀한다.
2. `DOG_NOSE_RUNTIME=torch`를 확인한다.
3. ONNX/YOLO/profile-first/timing flags가 disabled인지 확인한다.
4. `docker compose config`를 확인한다.
5. `docker compose pull` 후 `docker compose up -d --no-build`를 실행한다.
6. Spring actuator health를 확인한다.
7. Python Embed runtime health를 확인한다.
8. 최소 smoke를 수행한다.
9. MySQL/Qdrant/uploads volume은 삭제하지 않는다.

---

## Future Split Architecture

향후 트래픽이나 latency 요구가 단일 서버 구성을 넘어가면 API/Data server와 Inference server를 분리한다.

API/Data server:

- Nginx
- Spring Boot
- MySQL
- Qdrant

Inference server:

- Python Embed
- PyTorch 또는 ONNX Runtime
- YOLO
- model artifacts

보안 정책:

- inference endpoint는 private IP/VPC 내부에서만 접근한다.
- inference port는 public internet에 노출하지 않는다.
- security group source는 API server만 허용한다.
- Spring `PYTHON_EMBED_URL`은 private endpoint를 가리킨다.
- model artifact는 read-only mount로 제공한다.

최소 시작점은 non-burstable compute optimized 계열의 4 vCPU / 8 GiB 이상이다. 최종 사양은 YOLO + embedding benchmark 결과로 결정한다.

---

## ONNX Production Enablement Gate

향후 ONNX를 production에서 활성화하려면 아래 근거가 모두 필요하다.

- real model parity
- local Docker HTTP benchmark
- non-burstable server benchmark
- registration/duplicate/handover regression
- p50/P95 latency
- vector drift 분석
- rollback drill

이 gate를 통과하기 전까지 production runtime은 PyTorch로 유지한다.
