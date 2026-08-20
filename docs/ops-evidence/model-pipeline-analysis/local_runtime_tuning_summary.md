# Local Runtime Tuning Summary

Scope: local runtime tuning reviewed but not adopted.

Sources:

- `<evidence-dir>/petnose-local-embed-runtime-tuning/petnose-local-embed-runtime-tuning-20260610T121917Z.md`
- `<evidence-dir>/petnose-embed-warmup-channels-last/final-comparison.md`

| Candidate | Result | Decision |
|---|---|---|
| warm-up | No first-request improvement strong enough for adoption. | Not adopted |
| channels_last | No meaningful latency improvement; AWS comparison was slower. | Not adopted |
| warm-up + channels_last | Did not meet adoption criteria. | Not adopted |
| torch.compile | Dynamo unavailable in the tested Python 3.12 + torch 2.3.1 runtime. | Not adopted |

No product runtime flags or production defaults were changed from these experiments.
