# Dog Nose Model Analysis Evidence

이 디렉터리는 dog nose v2 모델 동작, similarity distribution, Qdrant reference/centroid 설계 판단 근거를 보관한다.

제출 repository에는 summary/report/script 중심의 재현 가능한 최소 산출물만 유지한다. 대형 raw CSV, embedding, 이미지 데이터셋, checkpoint, 생성 output은 active repository에 커밋하지 않는다.

## Tracked files

아래 파일은 모델 threshold와 dog nose v2 설계 근거를 확인하거나 재현하는 데 필요한 최소 파일로 tracked 상태를 유지한다.

- `MODEL_INFERENCE_REPORT.md`
- `RECOMMENDED_QDRANT_DESIGN.md`
- `SIMILARITY_EXPERIMENT.md`
- `experiment_summary.json`
- `run_similarity_experiment.py`

## Intentionally untracked/generated files

아래 파일과 디렉터리는 generated artifact 또는 private/local artifact로 간주하며 repository에 커밋하지 않는다.

- `pairwise_scores.csv`
- `multi_reference_scores.csv`
- raw embeddings
- raw image datasets
- private datasets
- model checkpoints
- generated output directories
- local smoke raw evidence
- private dog image fixtures

## Artifact policy

Raw/generated outputs가 필요하면 local artifact directory, release asset, external storage, 또는 ops evidence artifact로 보관한다.

PR과 제출 문서에는 summary statistics와 재현 command만 남긴다. Raw CSV는 `run_similarity_experiment.py`로 다시 생성할 수 있으므로 repository에는 `experiment_summary.json`과 report markdown을 primary tracked summary로 유지한다.

Raw data 위치는 private/local path일 수 있으므로 repository에 기록하지 않는다. 모델 checkpoint와 image dataset도 repository 밖에 둔다.

모델 checkpoint, raw dog image, private dataset, embedding dump, service account 파일, `.env` 파일은 절대 커밋하지 않는다.

예시 재현 command:

```powershell
python docs/model-analysis/run_similarity_experiment.py `
  --model-dir <model_dir> `
  --dataset-dir <model_dataset_dir> `
  --output-dir <local_artifact_output_dir> `
  --dog-limit 50 `
  --images-per-dog 5 `
  --device cpu
```

`<local_artifact_output_dir>`에는 `pairwise_scores.csv`, `multi_reference_scores.csv`, `experiment_summary.json`이 생성될 수 있다. CSV 파일은 커밋하지 않고, 필요한 summary만 문서 또는 `experiment_summary.json`에 반영한다.

## Submission criteria

제출 심사자는 `SIMILARITY_EXPERIMENT.md`, `MODEL_INFERENCE_REPORT.md`, `RECOMMENDED_QDRANT_DESIGN.md`, `experiment_summary.json`을 통해 threshold 근거와 Qdrant 설계 판단을 확인한다.

Raw CSV 전체는 제출 repository에 없어도 된다. 필요 시 별도 evidence package로 제공한다.
