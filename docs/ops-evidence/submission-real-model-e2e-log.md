# Submission Real-Model E2E Log

## Scope
- Final develop submission smoke
- Real dog nose model
- MySQL/Qdrant/Python/Spring/Nginx end-to-end
- No raw image/model/secret committed

## Environment
- Date/time KST: 2026-06-03T17:05:17+09:00
- Branch name: test/submission-real-model-e2e-evidence
- Commit SHA: 2f94897b156a863d7bbda9f1d10f76fb50b892fb
- Base develop SHA: 2f94897b156a863d7bbda9f1d10f76fb50b892fb
- Compose files: infra/docker/compose.yaml, infra/docker/compose.dev.yaml, infra/docker/compose.real-model.yaml
- Runtime mode: real-model
- Model: dog-nose-identification2:s101_224
- Vector dimension: 2048
- Qdrant collection: dog_nose_embeddings_real_v2
- Qdrant distance: Cosine
- Evidence redaction policy: tokens/passwords/raw images/raw vectors/full payloads are not written

## Preflight
| Check | Result | Observed |
| --- | --- | --- |
| Spring health | PASS | UP |
| Python health | PASS | dog-nose-identification2:s101_224 |
| model_loaded | PASS | True |
| vector_dim | PASS | 2048 |
| Qdrant collection exists | PASS | dog_nose_embeddings_real_v2 |
| collection dimension | PASS | 2048 |
| collection distance | PASS | Cosine |
| DB migrated | PASS | flyway_max_version=9 |

## Scenario Results
| Scenario | Result | Note |
| --- | --- | --- |
| Auth register/login/me | PASS |  |
| Dog registration normal | PASS |  |
| Duplicate suspected | PASS |  |
| Adoption post create | PASS |  |
| Public privacy | PASS |  |
| Dog query owner/public | PASS |  |
| Handover verification | PASS |  |
| Adoption completion | PASS |  |
| My adopted dogs | PASS |  |
| File serving | PASS |  |
| Reconciliation | PASS |  |

## Count Assertions
| Assertion | Value |
| --- | --- |
| owner_user_id_fixture | <redacted-fixture-user-id-present> |
| adopter_user_id_fixture | <redacted-fixture-user-id-present> |
| normal_nose_images | 5 |
| normal_references_total | 6 |
| normal_references_reference | 5 |
| normal_references_centroid | 1 |
| qdrant_active_point_count_after_normal | 6 |
| normal_latest_verification_result | PASSED |
| normal_dog_status | REGISTERED |
| duplicate_nose_images | 5 |
| duplicate_references_total | 0 |
| duplicate_latest_verification_result | DUPLICATE_SUSPECTED |
| qdrant_active_point_count_after_duplicate | 6 |
| qdrant_duplicate_unchanged | True |
| profile_images_after_post | 1 |
| qdrant_after_post_unchanged | True |
| handover_created_dog_images | 0 |
| handover_created_verification_logs | 0 |
| handover_post_status_unchanged | True |
| handover_dog_status_unchanged | True |
| adoption_posts_status | COMPLETED |
| adoption_posts_adopter_user_id_matches | True |
| adoption_posts_adopted_at_present | True |
| dogs_status_after_completion | ADOPTED |
| dogs_owner_user_id_unchanged | True |
| profile_image_file_serving_http_status | 200 |
| owner_nose_image_file_serving_http_status | 200 |

## Reconciliation Summary
- consistent=True
- missing/orphan/mismatch counts: 0/0/0
- output JSON path: docs/ops-evidence/submission-real-model-e2e-local/reconciliation-summary.json
- no raw Qdrant vector stored

## Redaction
- JWT redacted
- password redacted
- reset token redacted
- Firebase token redacted
- FCM token redacted
- service account not used/not committed
- real images not committed
- model checkpoint not committed
- private email/phone fixture-only or redacted

## Validation Commands
| Command | Result |
| --- | --- |
| GET /actuator/health | PASS |
| GET /health (Python Embed) | PASS |
| GET /collections/dog_nose_embeddings_real_v2 | PASS |
| MySQL flyway/table preflight | PASS |
| pwsh ./scripts/check-qdrant-reference-consistency.ps1 -FailOnDrift -OutputPath <local-output-json> | PASS |
| git diff --check | PASS |
| pwsh -NoProfile -File ./scripts/verify-submission-real-model-e2e.ps1 -Help | PASS |
| pwsh -NoProfile -Command scriptblock parse | PASS |
| docker compose --env-file infra/docker/.env -f infra/docker/compose.yaml -f infra/docker/compose.dev.yaml -f infra/docker/compose.real-model.yaml config | PASS |
| gradle test | PASS |
| secret/redaction grep | PASS; field-name-only hits for access_token/reset_token, existing ignore/doc marker for firebase-adminsdk |

## Fixture Inputs
- Nose image source: local path outside repository, basename/count/hash only recorded
- Nose image count: 5
- Profile image source: local path outside repository, basename/hash only recorded
- Profile image basename: profile1.jpg
