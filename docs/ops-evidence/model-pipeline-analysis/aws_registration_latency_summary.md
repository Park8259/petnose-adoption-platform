# AWS Registration Latency Summary

Scope: AWS real-server end-to-end profiling.

The raw server log and API transcript were excluded from this PR because they contain generated resource IDs, server URLs, and raw operational log context. This file keeps only the sanitized stage-level timing summary.

| Segment | Time |
|---|---:|
| external dog registration API | 14106 ms |
| internal total | 13920 ms |
| embed_batch | 13522 ms |
| Qdrant search | 153 ms |
| file store | 17 ms |
| DB pending rows | 55 ms |
| Qdrant upsert | 39 ms |
| DB reference/status finalize | 67 ms |

Interpretation:

- `embed_batch` accounted for approximately 97% of internal registration time.
- Qdrant, DB, and file storage were not the primary bottleneck in this run.
- This should not be compared directly with local controlled benchmark values.
- This includes AWS CPU, Docker, production stack, and resource-contention effects.

Local controlled benchmarks and AWS end-to-end profiling measure different scopes and must not be combined into one direct speedup calculation.
