# Local PyTorch Batch Inference Summary

Scope: local CPU controlled experiment.

Source: `<evidence-dir>/petnose-local-onnx-benchmark/benchmark_summary.json`.

| Case | Mean ms | P95 ms |
|---|---:|---:|
| 5 separate `/embed` calls, summed | 2532.397 | 2781.707 |
| `/embed-batch` with 5 images | 1692.285 | 1836.452 |

Derived result:

- mean reduction: 33.17%
- P95 reduction: 33.98%
- mean time saved: approximately 840.112 ms
- speedup: approximately 1.496x

Mean is average processing time. P95 means 95% of observed runs completed within that time.

This is the structural improvement reflected in the active runtime path. It improves request/forward structure without model retraining or threshold changes.
