# Local ONNX Runtime Model-Only Summary

Scope: local model-only preliminary experiment.

Source: `<evidence-dir>/petnose-local-onnx-benchmark/benchmark_summary.json`.

| Case | PyTorch mean ms | PyTorch P95 ms | ONNX Runtime mean ms | ONNX Runtime P95 ms |
|---|---:|---:|---:|---:|
| Single image | 489.619 | 548.287 | 116.898 | 141.394 |
| Batch of 5 | 1630.565 | 1754.602 | 507.514 | 566.716 |

Derived result:

- batch mean speedup: approximately 3.21x
- batch P95 speedup: approximately 3.10x

Vector parity:

- cosine similarity minimum: 1.00000000
- max absolute difference maximum: 9.87e-8
- L2 difference maximum: 1.11e-6

Scope guardrail:

- FastAPI, HTTP, Docker, Spring-Python network, and AWS overhead are excluded.
- Do not describe this as a production API speedup.
- This is a follow-up validation candidate, not an adopted production runtime.
