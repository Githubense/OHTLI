#!/usr/bin/env python3
"""Extract a compact, documented grid from a HiRISE PDS3 DTM IMG product."""

from __future__ import annotations

import argparse
import json
import math
import re
import struct
from pathlib import Path


PRODUCT_ID = "DTEEC_040770_1755_039280_1755_U01"
PRODUCT_PAGE = "https://www.uahirise.org/dtm/dtm.php?ID=ESP_040770_1755"
PRODUCT_FILE = (
    "https://www.uahirise.org/PDS/DTM/ESP/ORB_040700_040799/"
    "ESP_040770_1755_ESP_039280_1755/"
    f"{PRODUCT_ID}.IMG"
)


def parse_label(header: bytes) -> dict[str, str]:
    label = header.decode("ascii", errors="replace")
    end = re.search(r"(?m)^\s*END\s*$", label)
    if end is None:
        raise ValueError("PDS label has no END record")
    label = label[: end.end()]
    result: dict[str, str] = {}
    for key, value in re.findall(r"^\s*([A-Z_^]+)\s*=\s*([^\r\n]+)", label, re.M):
        result[key] = value.strip().strip('"')
    image = label.split("OBJECT = IMAGE", 1)[-1]
    for key, value in re.findall(r"^\s*([A-Z_^]+)\s*=\s*([^\r\n]+)", image, re.M):
        result[f"IMAGE_{key}"] = value.strip().strip('"')
    return result


def read_grid(
    source: Path,
    grid_size: int,
    sample_step: int,
    origin_x: int | None = None,
    origin_y: int | None = None,
) -> tuple[list[float], dict]:
    with source.open("rb") as file:
        label_header = file.read(64_000)
        label = parse_label(label_header)
        record_bytes = int(label["RECORD_BYTES"])
        image_record = int(label["^IMAGE"])
        lines = int(label["IMAGE_LINES"])
        samples = int(label["IMAGE_LINE_SAMPLES"])
        sample_type = label["IMAGE_SAMPLE_TYPE"]
        bits = int(label["IMAGE_SAMPLE_BITS"])
        map_scale = float(label["MAP_SCALE"].split()[0])
        map_resolution = float(label["MAP_RESOLUTION"].split()[0])
        center_latitude = float(label["CENTER_LATITUDE"].split()[0])
        center_longitude = float(label["CENTER_LONGITUDE"].split()[0])
        line_projection_offset = float(label["LINE_PROJECTION_OFFSET"].split()[0])
        sample_projection_offset = float(label["SAMPLE_PROJECTION_OFFSET"].split()[0])
        if sample_type != "PC_REAL" or bits != 32:
            raise ValueError(f"Expected PC_REAL 32-bit DTM, found {sample_type}/{bits}")

        data_start = (image_record - 1) * record_bytes
        crop_width = grid_size * sample_step
        crop_height = grid_size * sample_step
        start_x = origin_x if origin_x is not None else (samples - crop_width) // 2
        start_y = origin_y if origin_y is not None else (lines - crop_height) // 2
        if start_x < 0 or start_y < 0:
            raise ValueError("Requested crop is larger than the source DTM")

        values: list[float] = []
        invalid = 0
        for grid_y in range(grid_size):
            source_y = start_y + grid_y * sample_step
            row_offset = data_start + source_y * samples * 4
            file.seek(row_offset)
            row = file.read(samples * 4)
            for grid_x in range(grid_size):
                source_x = start_x + grid_x * sample_step
                value = struct.unpack_from("<f", row, source_x * 4)[0]
                if not math.isfinite(value) or value < -10_000:
                    invalid += 1
                    value = 0.0
                values.append(value)

    first_sample = start_x + 1
    last_sample = start_x + (grid_size - 1) * sample_step + 1
    first_line = start_y + 1
    last_line = start_y + (grid_size - 1) * sample_step + 1

    def coordinate(sample: float, line: float) -> tuple[float, float]:
        longitude = center_longitude + (sample - sample_projection_offset) / map_resolution
        latitude = center_latitude - (line - line_projection_offset) / map_resolution
        return latitude, longitude

    center_sample = (first_sample + last_sample) / 2
    center_line = (first_line + last_line) / 2
    center_latitude_crop, center_longitude_crop = coordinate(center_sample, center_line)
    corner_coordinates = [
        coordinate(first_sample, first_line),
        coordinate(first_sample, last_line),
        coordinate(last_sample, first_line),
        coordinate(last_sample, last_line),
    ]
    crop_spacing = map_scale * sample_step

    return values, {
        "sourceProduct": PRODUCT_ID,
        "sourcePage": PRODUCT_PAGE,
        "sourceFile": PRODUCT_FILE,
        "sourceInstitution": "University of Arizona / HiRISE Operations Center",
        "mission": "Mars Reconnaissance Orbiter",
        "instrument": "HiRISE stereo DTM",
        "dataSetId": "MRO-M-HIRISE-5-DTM-V1.0",
        "originalPostSpacingMeters": map_scale,
        "sourceSampleStepPixels": sample_step,
        "gridSpacingMeters": round(crop_spacing, 6),
        "sampledPointSpanMeters": round(crop_spacing * (grid_size - 1), 3),
        "gridSize": grid_size,
        "cropOriginPixels": {"x": start_x, "y": start_y},
        "sourceRasterSize": {"width": samples, "height": lines},
        "sourceLocation": {
            "latitudeCenterDegrees": center_latitude_crop,
            "longitudeCenterDegreesEast": center_longitude_crop,
            "coordinatePrecision": "computed from PDS3 map projection and sampled crop center",
        },
        "cropFootprint": {
            "minimumLatitudeDegrees": min(point[0] for point in corner_coordinates),
            "maximumLatitudeDegrees": max(point[0] for point in corner_coordinates),
            "minimumLongitudeDegreesEast": min(point[1] for point in corner_coordinates),
            "maximumLongitudeDegreesEast": max(point[1] for point in corner_coordinates),
            "coordinateReference": "PDS3 simple cylindrical map projection; bounds span sampled post centers",
        },
        "verticalDatum": "Mars 2000 areoid / equipotential surface",
        "heightEncoding": "little-endian IEEE-754 float32 meters",
        "invalidSamplesReplacedWithZero": invalid,
        "registrationNote": (
            "This compact crop is centered in the source raster. It is Gale Crater / "
            "Curiosity terrain context; it is not confirmed to overlap the Altadena "
            "drill location. Case-study endpoints, hazard overlays, surface classes, "
            "crew positions, and telemetry are synthetic demonstration inputs."
        ),
        "processing": (
            "Centered crop, regularly sampled from the HiRISE DTM at its PDS MAP_SCALE "
            "and the documented sourceSampleStepPixels interval. No synthetic displacement "
            "or shape-from-shading applied."
        ),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, help="HiRISE PDS3 IMG product")
    parser.add_argument("output", type=Path, help="Output directory")
    parser.add_argument("--grid-size", type=int, default=128)
    parser.add_argument("--sample-step", type=int, default=8)
    parser.add_argument("--origin-x", type=int)
    parser.add_argument("--origin-y", type=int)
    parser.add_argument("--basename", default="hirise_gale_context")
    parser.add_argument("--metadata-name", default="terrain_metadata.json")
    args = parser.parse_args()

    values, metadata = read_grid(
        args.source,
        args.grid_size,
        args.sample_step,
        origin_x=args.origin_x,
        origin_y=args.origin_y,
    )
    args.output.mkdir(parents=True, exist_ok=True)
    data_path = args.output / f"{args.basename}.f32"
    data_path.write_bytes(struct.pack(f"<{len(values)}f", *values))
    (args.output / args.metadata_name).write_text(
        json.dumps(metadata, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Wrote {data_path} ({len(values)} float samples)")
    print(f"Wrote {args.output / args.metadata_name}")


if __name__ == "__main__":
    main()
