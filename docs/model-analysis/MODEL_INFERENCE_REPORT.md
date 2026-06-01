# Dog Nose Identification2 Inference Report

작성일: 2026-05-24 KST

## 대상

- PetNose repository: `C:\Dev\_petnose_fix`
- Model repository: `C:\Dev\dog_nose_identification2\dog_nose_identification2`
- 실제 PetNose embedder: `python-embed/app/embedding/dog_nose_identification2_embedder.py`
- 원 모델 근거: `dog_nose_inference_colab.ipynb`

## 핵심 결론

현재 PetNose의 real model inference는 `dog-nose-identification2:s101_224` checkpoint를 `torch+timm`으로 로드해 2048차원 L2-normalized embedding을 반환한다. classifier/logits는 inference에 사용하지 않는다.

동일 cropped nose 이미지/동일 dog 샘플의 score 분포가 충분히 높게 나왔기 때문에, 낮은 similarity의 1차 원인은 모델 로딩 자체보다는 입력 전처리/촬영 조건 불일치다. 특히 현재 서비스에는 nose detection, crop, alignment가 없고 업로드된 전체 이미지를 그대로 224x224로 resize한다.

## 모델 로딩 구조

| 항목 | 확인 결과 |
|---|---|
| 실제 embedder | `python-embed/app/embedding/dog_nose_identification2_embedder.py` |
| env 분기 | `EMBED_MODEL=mock-v1`이면 mock, `EMBED_MODEL=dog-nose-identification2`이면 real |
| 기본 model dir | `/models/dog_nose_identification2` |
| host model dir 예시 | `C:\Dev\dog_nose_identification2\dog_nose_identification2` |
| checkpoint 직접 지정 | `DOG_NOSE_MODEL_PATH`가 있으면 그 파일 우선 |
| checkpoint 탐색 우선순위 | `logs/s101_224/model_final.pth`, `logs/s101_256/model_final.pth`, `logs/s101_288/model_final.pth`, `logs/S200_224/model_final.pth`, 이후 `model_final.pth`/weight 확장자 rglob |
| 실제 사용 checkpoint | `C:\Dev\dog_nose_identification2\dog_nose_identification2\logs\s101_224\model_final.pth` |
| model tag | `s101_224` |
| response model | `dog-nose-identification2:s101_224` |
| vector dimension | 2048 |
| device | `EMBED_DEVICE` 기본 `cpu`; `cuda*` 요청 시 CUDA 가능할 때만 CUDA, 아니면 CPU |
| Docker real override | `compose.real-model.yaml`이 `EMBED_MODEL=dog-nose-identification2`, `EMBED_VECTOR_DIM=2048`, `QDRANT_VECTOR_DIM=2048`, `QDRANT_COLLECTION=dog_nose_embeddings_real_v1` 강제 |

실제 점검 결과:

- Docker image `petnose-python-embed:latest`에서 real deps 사용 가능: `torch 2.3.1`, `timm 1.0.3`, CUDA unavailable, CPU 사용.
- checkpoint top-level keys: `model`, `optimizer`, `lr_sched`, `warmup_sched`, `epoch`, `metric`.
- checkpoint state tensor 수: 940.
- 현재 모델에 매칭 로드된 tensor: 939/940.
- parameter loaded ratio: 79.05%.
- 미매칭 tensor: `heads.weight (6000, 2048)`. classifier weight로 보이지만 현재 inference는 logits를 쓰지 않으므로 score에는 영향이 없다.

## mock-v1 vs real model

`python-embed/app/embedding/__init__.py`에서 `EMBED_MODEL`로 분기한다.

- `mock-v1`: SHA256 기반 deterministic vector를 만들고 L2 normalize한다. 기본 dimension은 `EMBED_VECTOR_DIM=128`.
- `dog-nose-identification2`: `DogNoseIdentification2Embedder`를 만들고 checkpoint를 로드한다. 실제 dimension은 2048.

`/health`는 `model_loaded`, `model`, `vector_dim`, `backend`, `device`, `model_path_exists`, `image_size`를 반환한다. `/embed`는 `status`, `vector`, `dimension`, `model`만 반환한다.

## 모델 아키텍처

현재 adapter와 notebook의 구조가 일치한다.

| 항목 | 확인 결과 |
|---|---|
| backbone | `timm.create_model("resnest101e", pretrained=False, num_classes=0, global_pool="")` |
| feature extraction | `backbone.forward_features(x)` |
| pooling | GeM pooling, trainable `p`, default 3.0 |
| BNNeck | 사용. `BatchNorm1d(2048)` |
| classifier | `Linear(2048, 6000, bias=False)` 정의는 있으나 inference 미사용 |
| logits 사용 여부 | 미사용. `model(tensor, return_logits=False)` |
| 최종 embedding | `forward_features` feature map -> GeM -> BNNeck output |
| normalize 여부 | `torch.nn.functional.normalize(feature, p=2, dim=1)` |
| cosine 사용 가능 여부 | 가능. 반환 vector는 L2-normalized 2048차원 float list |

주의: checkpoint의 `heads.weight` classifier weight는 현재 `heads.classifier.weight`로 매핑되지 않는다. 그러나 현재 `/embed`는 `return_logits=False`라 classifier를 호출하지 않는다. 향후 logits/classifier 기반 판정을 추가하면 이 mapping부터 고쳐야 한다.

## 이미지 전처리

| 항목 | 현재 inference |
|---|---|
| decode | `PIL.Image.open(BytesIO(image_bytes))` |
| color | `.convert("RGB")`; BGR 아님 |
| resize | `(224, 224)` |
| interpolation | Bicubic |
| tensor 변환 | `ToTensor()` |
| normalize | ImageNet mean `[0.485, 0.456, 0.406]`, std `[0.229, 0.224, 0.225]` |
| crop | 없음 |
| nose detection | 없음 |
| alignment | 없음 |
| 품질 검사 | 없음 |

원 notebook도 deterministic inference에서 `Image.open(...).convert("RGB")`, `Resize((224,224), BICUBIC)`, `ToTensor`, ImageNet normalization, `F.normalize`를 사용한다. 따라서 입력이 이미 cropped nose라면 학습/검증용 notebook inference와 현재 service inference는 대체로 맞다.

하지만 PetNose runtime은 업로드된 파일 bytes를 그대로 저장하고 그대로 Python embedder에 보낸다. `FileStorageService`는 `file.getBytes()`를 저장/반환할 뿐 crop/resize/detection을 하지 않는다. 즉 현재 코드는 "코 영역만 crop"이 아니라 "업로드 이미지 전체 resize"다.

## Spring Boot 연동

`POST /api/dogs/register` 흐름:

1. `DogRegistrationController`가 `nose_image` multipart를 받는다.
2. `DogRegistrationService.register()`가 pending dog/image/log row를 만든다.
3. `FileStorageService.storeNoseImage()`가 원본 bytes를 저장한다.
4. `EmbedClient`가 Python `/embed`에 multipart field `image`로 bytes를 보낸다.
5. 응답의 `vector`, `dimension`, `model`을 파싱한다.
6. `qdrant.vector-dimension`과 response `dimension`을 비교한다.
7. Qdrant search를 먼저 수행한다.
8. `NoseVerificationPolicy`가 Qdrant result score의 max를 계산한다.
9. duplicate면 DB 상태를 `DUPLICATE_SUSPECTED`로 바꾸고 Qdrant upsert를 생략한다.
10. duplicate가 아니면 Qdrant upsert 후 `REGISTERED`로 확정한다.

Qdrant search/upsert:

- Collection default: `dog_nose_embeddings`
- Real model override: `dog_nose_embeddings_real_v1`
- Dimension default: mock 128, real override 2048
- Distance metric: `Cosine`
- Search endpoint: `/collections/{collection}/points/search`
- Search payload: `vector`, `limit`, optional `score_threshold`, `with_payload=true`, `filter=is_active true`
- Upsert endpoint: `/collections/{collection}/points?wait=true`
- 현재 point id: `dog_id`
- 현재 payload: `dog_id`, `user_id`, `breed`, `nose_image_path`, `registered_at`, `is_active`

Threshold:

- Qdrant pre-filter: `QDRANT_SEARCH_SCORE_THRESHOLD`, default `0.70`
- Spring final duplicate threshold: `NOSE_DUPLICATE_THRESHOLD`, default `0.70`
- `max_similarity_score`는 model이 반환하는 값이 아니다. Qdrant search result 중 가장 큰 `score`다.
- `duplicate = maxScore >= duplicateThreshold`.

## 낮은 similarity의 유력 원인 분류

| 원인 | 가능성 | 근거 |
|---|---:|---|
| 모델 로딩 문제 | 낮음 | 같은 이미지 score가 1.0, 같은 dog cropped sample 평균이 높음, checkpoint/backbone/BNNeck 로드 확인 |
| embedding normalize 문제 | 낮음 | service와 notebook 모두 L2 normalize 후 반환 |
| Qdrant score 방향 문제 | 낮음 | Cosine score를 높을수록 유사하게 쓰며 Spring도 `>= threshold` |
| 전처리/crop 문제 | 매우 높음 | runtime에 detection/crop/alignment 없음. 전체 이미지를 224로 축소하면 nose print detail이 손실됨 |
| 촬영 품질 문제 | 높음 | 모델 샘플은 close-up cropped nose 중심. 실제 blur, glare, 각도, 거리 변화는 score 하락 가능 |
| threshold 문제 | 중간 | cropped sample에서는 0.70이 충분하지만, manual review band를 만들려면 Qdrant pre-filter를 0.60 이하로 낮춰야 함 |

현재 관찰되는 "동일 비문인데 낮은 similarity"는 모델보다 입력 도메인 mismatch가 가장 유력하다. 특히 앱/운영에서 full face, muzzle, 어두운 사진, 반사광, 초점 흐림이 들어오면 같은 모델이라도 score가 급락할 수 있다.
