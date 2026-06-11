# Python Embed CPU Thread A/B Test

Status: measured locally. No production/server default config has been changed.

Verdict: do not apply explicit Python Embed CPU thread caps before PR. In the
local real-model A/B run, `default` was fastest and both `threads=1` and
`threads=2` regressed the primary `embed_batch` metric.

## Goal

Validate whether limiting CPU math library threads improves dog registration
embedding latency on the current server hardware.

Primary metric:

- Spring server log `[DogRegistrationTiming]` stage `embed_batch`
- Current concern: `embed_batch ~= 13500ms`

Secondary metrics:

- Client-observed `dog_registration` p50 / mean / p95 from
  `scripts/measure-aws-registration-latency.ps1`
- Health endpoint latency
- Error rate
- Registration response status correctness
- Returned registration `dimension` remains `2048`

## Candidates

Run candidates in this order, using the same image set and similar traffic
conditions:

| Candidate | Python Embed thread env |
|---|---|
| `default` | Do not include an explicit `OMP/MKL/OpenBLAS/NumExpr` override. |
| `threads=1` | Set `OMP_NUM_THREADS`, `MKL_NUM_THREADS`, `OPENBLAS_NUM_THREADS`, `NUMEXPR_NUM_THREADS`, and `NUMEXPR_MAX_THREADS` to `1`. |
| `threads=2` | Set `OMP_NUM_THREADS`, `MKL_NUM_THREADS`, `OPENBLAS_NUM_THREADS`, `NUMEXPR_NUM_THREADS`, and `NUMEXPR_MAX_THREADS` to `2`. |

## Temporary Compose Override

For `threads=1` and `threads=2`, include only the measurement override:

```bash
export PYTHON_EMBED_CPU_THREADS=1

docker compose --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.prod.yaml \
  -f infra/docker/compose.prod-real-model.yaml \
  -f infra/docker/compose.python-embed-cpu-thread-experiment.yaml \
  up -d --no-build --force-recreate python-embed
```

For `default`, omit
`infra/docker/compose.python-embed-cpu-thread-experiment.yaml` and recreate
`python-embed` from the normal real-model compose stack.

After each recreate, wait for Spring actuator health to be healthy before
measuring. Record the actual container values for audit:

```bash
docker compose --env-file infra/docker/.env \
  -f infra/docker/compose.yaml \
  -f infra/docker/compose.prod.yaml \
  -f infra/docker/compose.prod-real-model.yaml \
  exec python-embed python -c 'import os; keys=["OMP_NUM_THREADS","MKL_NUM_THREADS","OPENBLAS_NUM_THREADS","NUMEXPR_NUM_THREADS","NUMEXPR_MAX_THREADS"]; print({k: os.getenv(k) for k in keys})'
```

For `threads=1` and `threads=2`, include the experiment compose file and set
`PYTHON_EMBED_CPU_THREADS` for this verification command too.

## Measurement

Use one warmup registration after each Python Embed recreate, then run the
measured sample. The script writes CSV and JSON under the candidate-specific
output directory.

```powershell
pwsh -NoProfile -File .\scripts\measure-aws-registration-latency.ps1 `
  -NoseImageDir "C:\path\to\nose-images" `
  -RootUrl "http://<server-host>" `
  -BaseUrl "http://<server-host>/api" `
  -Runs 1 `
  -ExpectedDimension 2048 `
  -OutputDir "docs/ops-evidence/aws-registration-latency/warmup-default"

pwsh -NoProfile -File .\scripts\measure-aws-registration-latency.ps1 `
  -NoseImageDir "C:\path\to\nose-images" `
  -RootUrl "http://<server-host>" `
  -BaseUrl "http://<server-host>/api" `
  -Runs 5 `
  -ExpectedDimension 2048 `
  -OutputDir "docs/ops-evidence/aws-registration-latency/default"
```

Capture Spring logs for the same measured window and parse the primary metric:

```powershell
pwsh -NoProfile -File .\scripts\summarize-dog-registration-timing-log.ps1 `
  -LogPath "C:\path\to\candidate-default.spring.log" `
  -Candidate "default" `
  -Stage "embed_batch"
```

Repeat for `threads=1` and `threads=2`.

## Local Result

Run date: 2026-06-09 KST.

Runtime shape:

- Local Docker Desktop real-model stack.
- Spring image rebuilt from this branch before measuring so
  `[DogRegistrationTiming]` was present.
- Python Embed health passed for every candidate:
  `model=dog-nose-identification2:s101_224`, `device=cpu`,
  `vector_dim=2048`, `model_loaded=true`.
- One real dog-nose fixture was repeated as `1.jpg` through `5.jpg` to keep
  the `/embed-batch` request stable across candidates.
- One warmup registration was run after each Python Embed recreate, then seven
  measured registrations were collected per candidate.
- Raw logs, raw latency outputs, and the temporary image fixture were retained
  outside the repo only.

Thread env verification:

| Candidate | Thread env values |
|---|---|
| `default` | `OMP_NUM_THREADS`, `MKL_NUM_THREADS`, `OPENBLAS_NUM_THREADS`, `NUMEXPR_NUM_THREADS`, `NUMEXPR_MAX_THREADS` all unset |
| `threads=1` | All five thread env values set to `1` |
| `threads=2` | All five thread env values set to `2` |

Primary metric from Spring `[DogRegistrationTiming]` stage `embed_batch`:

| Candidate | Count | Mean | p50 | p95 | Mean vs default |
|---|---:|---:|---:|---:|---:|
| `default` | 7 | `1621.14ms` | `1599ms` | `1755ms` | baseline |
| `threads=1` | 7 | `7359.29ms` | `7330ms` | `7451ms` | `+353.9%` slower |
| `threads=2` | 7 | `4143.43ms` | `4158ms` | `4188ms` | `+155.6%` slower |

Secondary client-observed `dog_registration` latency:

| Candidate | Count | Mean | p50 | p95 | Error rate |
|---|---:|---:|---:|---:|---:|
| `default` | 7 | `1833.22ms` | `1806.18ms` | `1992.71ms` | `0` |
| `threads=1` | 7 | `7564.58ms` | `7559.13ms` | `7586.85ms` | `0` |
| `threads=2` | 7 | `4345.17ms` | `4349.13ms` | `4367.49ms` | `0` |

Correctness checks:

| Candidate | Health error rate | Registration statuses | Embedding statuses | Dimension check |
|---|---:|---|---|---|
| `default` | `0` | `DUPLICATE_SUSPECTED=7` | `SKIPPED_DUPLICATE=7` | passed, all `2048` |
| `threads=1` | `0` | `DUPLICATE_SUSPECTED=7` | `SKIPPED_DUPLICATE=7` | passed, all `2048` |
| `threads=2` | `0` | `DUPLICATE_SUSPECTED=7` | `SKIPPED_DUPLICATE=7` | passed, all `2048` |

Server-impact estimate from local result:

- Local tuned-candidate improvement over `default`: none.
- Apply the requested estimate formula with `X=0%`:
  `13500ms * (1 - 0%) = 13500ms`.
- Estimated server saving: `13500ms * 0% = 0ms`.
- Because both tuned candidates regressed locally, this branch should not add
  thread caps to production/server config.

## Decision Rule

Do not apply thread tuning to production/server config unless a tuned candidate
meets all of these:

- `embed_batch` mean, p50, and p95 improve versus `default`; prefer a material
  improvement of at least 10% or enough to resolve the `13500ms` concern.
- Client-observed `dog_registration` mean/p50/p95 does not regress materially.
- Health endpoint error rate remains zero.
- `dog_registration` error rate remains zero.
- Registration statuses are expected for the reused image set, such as
  `REGISTERED` for the first clean registration or `DUPLICATE_SUSPECTED` for
  repeated images.
- `dimension_check.passed=true` and every successful registration returns
  `dimension=2048`.

Keep raw generated evidence directories out of commits unless they have been
reviewed and intentionally selected.
