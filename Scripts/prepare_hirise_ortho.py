#!/usr/bin/env python3
"""Crop the HiRISE image that is map-registered to the bundled Gale DTM grid.

Usage:
  prepare_hirise_ortho.py DTM.IMG ORTHO.JP2 ORTHO.LBL terrain_metadata.json output.jpg

The crop is derived from both PDS map-projection labels and the grid metadata.
On macOS, `sips` extracts the JPEG2000 crop and the companion Swift script applies
a documented display stretch. The stretch is only for viewing; it is not SfS.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import tempfile
from pathlib import Path


def parse_pds_label(data: bytes) -> dict[str, str]:
    text = data.decode("ascii", errors="replace")
    end = re.search(r"(?m)^\s*END\s*$", text)
    if end is None:
        raise ValueError("PDS label has no END record")
    text = text[: end.end()]
    return {
        key: value.strip().strip('"')
        for key, value in re.findall(r"^\s*([A-Z_^]+)\s*=\s*([^\r\n]+)", text, re.M)
    }


def read_dtm_label(path: Path) -> dict[str, str]:
    with path.open("rb") as source:
        return parse_pds_label(source.read(256_000))


def projection(label: dict[str, str]) -> tuple[float, float, float, float, float]:
    return (
        float(label["CENTER_LATITUDE"].split()[0]),
        float(label["CENTER_LONGITUDE"].split()[0]),
        float(label["MAP_RESOLUTION"].split()[0]),
        float(label["LINE_PROJECTION_OFFSET"].split()[0]),
        float(label["SAMPLE_PROJECTION_OFFSET"].split()[0]),
    )


def source_stereo_pair(label_bytes: bytes) -> set[str]:
    text = label_bytes.decode("ascii", errors="replace")
    match = re.search(r"SOURCE_PRODUCT_ID\s*=\s*\((.*?)\)", text, re.S)
    if match is None:
        return set()
    return set(re.findall(r"ESP_\d{6}_\d{4}", match.group(1)))


def output_crop(
    dtm: dict[str, str], ortho: dict[str, str], grid: dict
) -> tuple[int, int, int]:
    dtm_lat0, dtm_lon0, dtm_res, dtm_line0, dtm_sample0 = projection(dtm)
    ortho_lat0, ortho_lon0, ortho_res, ortho_line0, ortho_sample0 = projection(ortho)
    grid_size = int(grid["gridSize"])
    sample_step = int(grid["sourceSampleStepPixels"])
    origin_x = int(grid["cropOriginPixels"]["x"])
    origin_y = int(grid["cropOriginPixels"]["y"])

    first_sample = origin_x + 1
    first_line = origin_y + 1
    last_sample = origin_x + (grid_size - 1) * sample_step + 1
    last_line = origin_y + (grid_size - 1) * sample_step + 1
    center_sample = (first_sample + last_sample) / 2
    center_line = (first_line + last_line) / 2

    center_lon = dtm_lon0 + (center_sample - dtm_sample0) / dtm_res
    center_lat = dtm_lat0 - (center_line - dtm_line0) / dtm_res
    center_ortho_sample = ortho_sample0 + (center_lon - ortho_lon0) * ortho_res
    center_ortho_line = ortho_line0 + (ortho_lat0 - center_lat) * ortho_res

    scale_ratio = ortho_res / dtm_res
    if abs(scale_ratio - round(scale_ratio)) > 1e-5:
        raise ValueError(f"Expected an integer aligned pixel ratio, found {scale_ratio:.8f}")
    width = round((grid_size - 1) * sample_step * scale_ratio) + 1
    left = round(center_ortho_sample - 1 - (width - 1) / 2)
    top = round(center_ortho_line - 1 - (width - 1) / 2)
    return left, top, width


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("dtm", type=Path)
    parser.add_argument("ortho", type=Path)
    parser.add_argument("ortho_label", type=Path)
    parser.add_argument("terrain_metadata", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    dtm_label = read_dtm_label(args.dtm)
    ortho_label_data = args.ortho_label.read_bytes()
    ortho_label = parse_pds_label(ortho_label_data)
    with args.dtm.open("rb") as source:
        dtm_label_data = source.read(256_000)
    dtm_pair = source_stereo_pair(dtm_label_data)
    ortho_pair = source_stereo_pair(ortho_label_data)
    if not dtm_pair or not ortho_pair or not ortho_pair.issubset(dtm_pair):
        raise ValueError(f"DTM/ortho stereo source pairs do not match: {dtm_pair} vs {ortho_pair}")
    metadata = json.loads(args.terrain_metadata.read_text(encoding="utf-8"))
    left, top, width = output_crop(dtm_label, ortho_label, metadata)
    args.output.parent.mkdir(parents=True, exist_ok=True)

    swift_script = Path(__file__).with_name("prepare_hirise_ortho.swift")
    with tempfile.TemporaryDirectory(prefix="gale-hirise-") as temp_dir:
        crop = Path(temp_dir) / "registered_crop.jpg"
        subprocess.run(
            [
                "/usr/bin/sips",
                "-s", "format", "jpeg",
                "-s", "formatOptions", "96",
                "--cropToHeightWidth", str(width), str(width),
                "--cropOffset", str(top), str(left),
                str(args.ortho), "--out", str(crop),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
        )
        subprocess.run(["swift", str(swift_script), str(crop), str(args.output)], check=True)

    ortho_lat0, ortho_lon0, ortho_res, _, _ = projection(ortho_label)
    dtm_lat0, dtm_lon0, dtm_res, _, _ = projection(dtm_label)
    metadata["registeredOrthophoto"] = {
        "sourceProduct": ortho_label.get("PRODUCT_ID", "ESP_040770_1755_RED_A_01_ORTHO"),
        "sourceFile": (
            "https://www.uahirise.org/PDS/DTM/ESP/ORB_040700_040799/"
            "ESP_040770_1755_ESP_039280_1755/ESP_040770_1755_RED_A_01_ORTHO.JP2"
        ),
        "instrument": ortho_label.get("INSTRUMENT_ID", "HIRISE"),
        "mapScaleMetersPerPixel": float(ortho_label["MAP_SCALE"].split()[0]),
        "sourceStereoPair": sorted(ortho_pair),
        "projectionAlignedToDTM": (
            ortho_lat0 == dtm_lat0
            and ortho_lon0 == dtm_lon0
            and abs(ortho_res / dtm_res - 4.0) < 1e-5
        ),
        "cropOriginPixels": {"x": left, "y": top},
        "cropSizePixels": {"width": width, "height": width},
        "displayStretch": "Core Image exposure +1.20 EV, contrast 1.04, lightly warmed red-channel display tint; no SfS or displacement",
    }
    args.terrain_metadata.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

    print(f"Registered crop: x={left}, y={top}, {width}x{width} pixels")
    print(f"Wrote display-stretched image: {args.output}")


if __name__ == "__main__":
    main()
