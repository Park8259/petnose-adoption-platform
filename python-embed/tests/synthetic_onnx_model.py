from __future__ import annotations

import argparse
from io import BytesIO
from pathlib import Path

from PIL import Image


def write_synthetic_onnx_model(path: Path, *, invalid_output_shape: bool = False) -> None:
    """
    Write a tiny dynamic-batch ONNX graph for adapter contract smoke tests.

    The graph intentionally has no model weights: it flattens the input image
    tensor and slices the first 2048 values as the embedding output.
    """
    import onnx
    from onnx import TensorProto, checker, helper

    path.parent.mkdir(parents=True, exist_ok=True)
    input_info = helper.make_tensor_value_info("images", TensorProto.FLOAT, ["N", 3, 224, 224])
    output_shape: list[object] = ["N", 1, 2048] if invalid_output_shape else ["N", 2048]
    output_info = helper.make_tensor_value_info("embeddings", TensorProto.FLOAT, output_shape)

    starts = helper.make_tensor("slice_starts", TensorProto.INT64, [1], [0])
    ends = helper.make_tensor("slice_ends", TensorProto.INT64, [1], [2048])
    axes = helper.make_tensor("slice_axes", TensorProto.INT64, [1], [1])
    steps = helper.make_tensor("slice_steps", TensorProto.INT64, [1], [1])

    flattened_output = "flattened"
    sliced_output = "sliced_embeddings" if invalid_output_shape else "embeddings"
    nodes = [
        helper.make_node("Flatten", ["images"], [flattened_output], name="flatten_images", axis=1),
        helper.make_node(
            "Slice",
            [flattened_output, "slice_starts", "slice_ends", "slice_axes", "slice_steps"],
            [sliced_output],
            name="slice_embedding_dim",
        ),
    ]
    initializers = [starts, ends, axes, steps]

    if invalid_output_shape:
        unsqueeze_axes = helper.make_tensor("unsqueeze_axes", TensorProto.INT64, [1], [1])
        nodes.append(
            helper.make_node(
                "Unsqueeze",
                [sliced_output, "unsqueeze_axes"],
                ["embeddings"],
                name="make_invalid_3d_output",
            )
        )
        initializers.append(unsqueeze_axes)

    graph = helper.make_graph(
        nodes,
        "petnose_synthetic_onnx_embedder",
        [input_info],
        [output_info],
        initializer=initializers,
    )
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)])
    checker.check_model(model)
    onnx.save(model, str(path))


def make_png_bytes(index: int = 0, *, size: int = 32) -> bytes:
    color = (
        (37 + index * 29) % 256,
        (91 + index * 47) % 256,
        (149 + index * 61) % 256,
    )
    image = Image.new("RGB", (size, size), color=color)
    handle = BytesIO()
    image.save(handle, format="PNG")
    return handle.getvalue()


def write_png_fixtures(directory: Path, *, count: int = 5) -> list[Path]:
    directory.mkdir(parents=True, exist_ok=True)
    paths = []
    for index in range(count):
        path = directory / f"nose-{index + 1}.png"
        path.write_bytes(make_png_bytes(index))
        paths.append(path)
    return paths


def main() -> int:
    parser = argparse.ArgumentParser(description="Create synthetic ONNX smoke inputs outside the repository.")
    parser.add_argument("--output", required=True, help="Path for the generated synthetic .onnx model.")
    parser.add_argument("--images-dir", default="", help="Optional directory for generated PNG smoke images.")
    parser.add_argument("--count", type=int, default=5, help="Number of PNG images to write when --images-dir is set.")
    parser.add_argument("--invalid-output-shape", action="store_true")
    args = parser.parse_args()

    write_synthetic_onnx_model(Path(args.output), invalid_output_shape=args.invalid_output_shape)
    if args.images_dir:
        write_png_fixtures(Path(args.images_dir), count=args.count)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
