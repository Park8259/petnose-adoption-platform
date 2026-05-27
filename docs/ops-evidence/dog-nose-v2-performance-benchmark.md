# Dog Nose v2 Performance Benchmark

## Run

- Executed at: `2026-05-26T18:57:30+09:00` to `2026-05-26T19:00:48+09:00`
- Branch: `feature/nose-v2-calibrated-policy-performance`
- Source commit at benchmark start: `8db31eee9cc3e2d85ac06337a60c642dad9d7e26` plus this PR working tree changes
- Compose project: `petnose_v2_perf_20260526_184826`
- Raw evidence dir: `C:\tmp\petnose-v2-performance\20260526_184826`
- Verdict: `WARN`

`WARN` is only for the expected moca duplicate borderline case: image `6.png` produced `final_score=0.643942`, which is below the calibrated auto threshold `0.65` and therefore returned `REVIEW_REQUIRED`.

## Runtime

- OS: `Windows-11-10.0.26200-SP0`
- CPU: `Intel(R) Core(TM) i5-14600KF`, 14 cores / 20 logical processors
- Docker: client/server `29.3.1`, Docker Desktop `4.67.0`, WSL2 Linux engine
- Python benchmark runtime: `3.13.11`
- Model device: `cpu`

Model health:

- `model_loaded=true`
- `model=dog-nose-identification2:s101_224`
- `vector_dim=2048`
- `backend=torch+timm`
- `model_path_exists=true`
- `load_error=null`

Qdrant collection:

- Collection: `dog_nose_embeddings_real_v2`
- Vector size: `2048`
- Distance: `Cosine`
- Final point count after functional smoke: `24`

## Calibrated Policy

- `final_score=max(max_reference_score, centroid_score)`
- AUTO / MATCH threshold: `0.65`
- REVIEW / AMBIGUOUS lower bound: `0.60`
- Below `0.60`: different dog / pass
- Qdrant candidate pre-filter: `0.55`
- Reference consistency threshold: `0.55`
- Reference subset/outlier filtering was not applied in this run.

## Clean Reset Scope

Only the dedicated smoke project was reset:

- `docker compose -p petnose_v2_perf_20260526_184826 ... down -v`
- MySQL volume: `petnose_v2_perf_20260526_184826_mysql_data`
- Qdrant volume: `petnose_v2_perf_20260526_184826_qdrant_storage`
- uploads volume: `petnose_v2_perf_20260526_184826_uploads_data`

Initial clean counts were all zero: `users`, `dogs`, `dog_images`, `dog_nose_references`, `verification_logs`, `adoption_posts`. Initial Qdrant point count was `0`; uploads volume was empty.

Final DB counts after API smoke:

| Table | Count |
|---|---:|
| `users` | 1 |
| `dogs` | 8 |
| `dog_images` | 36 |
| `dog_nose_references` | 24 |
| `verification_logs` | 8 |
| `adoption_posts` | 4 |

## Embedding Latency

Warmup `3`, measured `20` per direct endpoint/dog or batch size. Values are milliseconds.

| Endpoint | Images | Count | Mean | p50 | p95 | Min | Max |
|---|---:|---:|---:|---:|---:|---:|---:|
| `/embed` | 1 | 80 | 588.08 | 589.38 | 691.54 | 476.25 | 712.23 |
| `/embed-batch` | 1 | 20 | 586.91 | 581.09 | 669.00 | 531.57 | 669.31 |
| `/embed-batch` | 3 total | 20 | 1264.28 | 1269.90 | 1342.42 | 1189.38 | 1346.98 |
| `/embed-batch` | 3 per image | 20 | 421.43 | 423.30 | 447.47 | 396.46 | 448.99 |
| `/embed-batch` | 5 total | 20 | 1876.80 | 1870.18 | 1967.07 | 1772.91 | 1984.61 |
| `/embed-batch` | 5 per image | 20 | 375.36 | 374.04 | 393.41 | 354.58 | 396.92 |

## Qdrant Scaling

Synthetic active dog points were inserted only into the isolated smoke Qdrant collection. One dog equals 5 `REFERENCE` points plus 1 `CENTROID` point. Query vector was from real `ddubi/1.png` embedding. Each registration search cycle is 5 reference searches plus 1 centroid search with `score_threshold=0.55`, `limit=100`, `with_payload=true`.

| Active Dogs | Active Points | Mean Cycle | p50 | p95 |
|---:|---:|---:|---:|---:|
| 0 | 0 | 52.36 | 50.99 | 71.25 |
| 1 | 6 | 55.78 | 55.90 | 74.56 |
| 4 | 24 | 57.26 | 58.12 | 78.33 |
| 10 | 60 | 50.68 | 49.12 | 63.65 |
| 25 | 150 | 59.06 | 50.24 | 83.76 |
| 50 | 300 | 56.21 | 51.09 | 73.33 |
| 100 | 600 | 61.37 | 55.63 | 83.86 |
| 250 | 1500 | 63.78 | 61.74 | 77.80 |
| 500 | 3000 | 68.53 | 64.59 | 89.28 |
| 1000 | 6000 | 77.97 | 77.71 | 95.35 |

Empirical local slope from these means:

- `0.02361 ms` per active dog
- About `2.36 ms` per additional 100 active dogs
- About `11.80 ms` at 500 active dogs
- About `23.61 ms` at 1000 active dogs

Qdrant ANN/search behavior is not strictly linear; treat this as an empirical local Docker CPU slope, not a production capacity guarantee.

## API E2E Latency

Values are milliseconds.

| Scenario | Count | Mean | p50 | p95 | Min | Max |
|---|---:|---:|---:|---:|---:|---:|
| First registration, 5 references | 4 | 2358.69 | 2282.27 | 2770.43 | 2099.79 | 2770.43 |
| Duplicate registration, image 6 copied 3 times | 4 | 1495.29 | 1490.22 | 1570.91 | 1429.81 | 1570.91 |
| Adoption post creation | 4 | 44.90 | 39.34 | 64.04 | 36.87 | 64.04 |
| Same-dog handover | 4 | 650.22 | 647.73 | 667.07 | 638.37 | 667.07 |
| Cross-dog handover | 12 | 634.57 | 624.00 | 720.29 | 580.58 | 720.29 |

Slowest requests were all registration calls. The slowest was `ddubi` first registration at `2770.429 ms`.

## Functional Smoke

| Dog | First Registration | References | Qdrant Points | Duplicate Image 6 | Duplicate Final | Handover Image 7 | Handover Final |
|---|---|---:|---:|---|---:|---|---:|
| ddubi | `REGISTERED` | 6 | 6 | `DUPLICATE_SUSPECTED` | 0.9227281 | `MATCHED` | 0.89904654 |
| milk | `REGISTERED` | 6 | 6 | `DUPLICATE_SUSPECTED` | 0.7891785 | `MATCHED` | 0.72693276 |
| moca | `REGISTERED` | 6 | 6 | `REVIEW_REQUIRED` | 0.643942 | `MATCHED` | 0.6918067 |
| mungchi | `REGISTERED` | 6 | 6 | `DUPLICATE_SUSPECTED` | 0.7734946 | `MATCHED` | 0.6690009 |

Cross-dog handover:

- Total: `12`
- `MATCHED`: `0`
- `AMBIGUOUS`: `0`

Privacy/stateless:

- `verification_logs` before handover: `8`
- `verification_logs` after handover: `8`
- Final dog status counts: `REGISTERED=4`, `DUPLICATE_SUSPECTED=3`, `REVIEW_REQUIRED=1`
- Final adoption post status counts: `OPEN=4`
- No unsafe fields found in handover responses: `nose_image_url`, `author_user_id`, `top_matched_dog_id`
- Handover did not mutate dog/adoption status as part of this smoke.

## Raw Evidence

- Embed latency CSV: `C:\tmp\petnose-v2-performance\20260526_184826\embed_latency.csv`
- Qdrant scaling CSV: `C:\tmp\petnose-v2-performance\20260526_184826\qdrant_scaling.csv`
- API latency CSV: `C:\tmp\petnose-v2-performance\20260526_184826\api_latency.csv`
- Response bodies: `C:\tmp\petnose-v2-performance\20260526_184826\responses`
- Summary JSON: `C:\tmp\petnose-v2-performance\20260526_184826\benchmark_summary.json`

## Limitations

- Results are from a local Docker Desktop CPU environment.
- Qdrant scaling uses synthetic L2-normalized random vectors, while the query vector is a real model embedding.
- Production latency can differ with host CPU, GPU/CUDA use, Qdrant storage/index settings, network topology, and concurrent traffic.
- Mobile app/network latency is not included.
- This benchmark does not evaluate reference subset selection, outlier removal, or image quality rejection.
