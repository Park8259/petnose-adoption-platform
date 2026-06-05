# API 계약 - Spring Boot ↔ Python Embed

> 문서 성격: 보조 참고 문서(Task Reference)
>
> Spring Boot ↔ Python Embed 연동, `/embed`, `/health`, embedding error mapping 작업에서 읽는다.
> active canonical 문서와 충돌하면 active canonical 문서가 우선한다.
> Flutter는 Python Embed, Qdrant, MySQL에 직접 접근하지 않는다.

Spring Boot(`spring-api`)가 Python 임베딩 서비스(`python-embed`)를 호출하는 MVP 기준 계약이다.

Base URL (내부): `http://python-embed:8000`
환경변수: `PYTHON_EMBED_URL=http://python-embed:8000`

## 1. 단건 임베딩 생성

비문 이미지 1장을 받아 embedding vector를 반환한다. Current MVP에서는 handover verification이 이 endpoint를 사용한다.

```http
POST /embed
Content-Type: multipart/form-data

Form fields:
  image: file (JPEG/PNG)

Response 200:
{
  "status": "ok",
  "vector": [0.12, -0.34, 0.56, ...],  // float 배열
  "dimension": 128,                    // 필드명은 dim이 아니라 dimension
  "model": "mock-v1"                   // 또는 dog-nose-identification2:s101_224
}

Response 400:
{
  "detail": {
    "error": "INVALID_IMAGE",
    "message": "이미지를 처리할 수 없습니다."
  }
}

Response 500:
{
  "detail": {
    "error": "EMBED_FAILED",
    "message": "임베딩 생성 중 오류가 발생했습니다."
  }
}

Response 503:
{
  "detail": {
    "error": "MODEL_NOT_READY",
    "message": "실제 모델이 아직 로드되지 않았습니다."
  }
}
```

## 2. Batch 임베딩 생성

비문 이미지 여러 장을 한 요청에서 받아 embedding vector list를 반환한다. Current dog nose v2 registration은 `POST /api/dogs/register`에서 정확히 5장의 `nose_images`를 받고, Spring Boot가 Python Embed `/embed-batch`를 1회 호출한다.

```http
POST /embed-batch
Content-Type: multipart/form-data

Form fields:
  images: file[] (JPEG/PNG, 1~5장)

Response 200:
{
  "status": "ok",
  "model": "dog-nose-identification2:s101_224",
  "dimension": 2048,
  "count": 5,
  "items": [
    {
      "index": 0,
      "filename": "nose-1.jpg",
      "vector": [0.12, -0.34, 0.56, ...]
    }
  ]
}
```

Python Embed `/embed-batch`는 내부 endpoint로 1~5장 입력을 허용하지만, backend dog registration API는 정확히 5장만 허용한다. Handover verification은 registration과 다르게 단건 `/embed`를 사용한다.

## 3. 헬스체크

Spring Boot가 `python-embed` dependency를 확인할 때 사용한다.

```http
GET /health

Response 200:
{
  "status": "ok",
  "model_loaded": true,
  "model": "mock-v1",
  "vector_dim": 128,
  "backend": "mock",
  "device": "cpu",
  "model_path_exists": null
}
```

실제 모델 모드 예시:

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

## 모델 선택

- `EMBED_MODEL=mock-v1`
  - 기본값, lightweight mock, deterministic output
  - 기본 dimension: `128`
- `EMBED_MODEL=dog-nose-identification2`
  - 실제 model checkpoint load
  - 현재 분석 기준 dimension: `2048`
  - `DOG_NOSE_MODEL_DIR` 또는 `DOG_NOSE_MODEL_PATH` 필요

## 호출 규약

### Spring Boot 측

- `RestTemplate` 또는 `WebClient`로 호출한다.
- `PYTHON_EMBED_URL` 환경변수에서 base URL을 읽는다.
- 요청 시 image byte를 multipart로 전송한다.

### Timeout

| 항목 | 권장값 |
|---|---|
| Connection timeout | 3s |
| Read timeout | 10s (모델 로딩 고려) |

### Retry

- 현재 `backend`의 `EmbedClient`에는 retry logic이 구현되어 있지 않다.
- retry를 추가할 경우 최대 2회, fail-fast 원칙을 유지한다.

### 에러 처리

- 400 response: 이미지 자체 문제 - Spring Boot가 client에 422 반환
- 503 response: 모델 미로딩/외부 dependency 오류 - Spring Boot가 503 처리
- 500 response / timeout: Python service 오류 - Spring Boot가 503 또는 500 반환
- 연결 불가: Python container down - Spring Boot가 503 반환

## 버전 관리

- model version이 바뀌면 vector dimension이 달라질 수 있다.
- model 변경 시 Qdrant collection dimension compatibility를 먼저 확인해야 한다.
- Qdrant dimension은 collection 생성 후 변경할 수 없으므로, real model test는 active collection `dog_nose_embeddings_real_v2` 또는 별도 test collection을 명시해 mock/dev collection과 섞지 않는다.
- `model` field를 response에 포함해 Spring Boot가 model version mismatch를 감지할 수 있게 한다.
