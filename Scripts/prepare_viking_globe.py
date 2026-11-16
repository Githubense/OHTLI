#!/usr/bin/env python3
"""Build the north-up 0–360°E Mars globe texture from USGS's public COG.

Requires rasterio, numpy, and Pillow. Run from the project root:
    python Scripts/prepare_viking_globe.py
"""

from pathlib import Path

import rasterio
from rasterio.enums import Resampling
from PIL import Image


SOURCE = (
    "/vsicurl/https://asc-pds-services.s3.us-west-2.amazonaws.com/"
    "wms_basemaps/Mars/MDIM21_AMESColor/MDIM21_AMES_recolor_dd360_jpeg_cog.tif"
)
OUTPUT = Path(__file__).resolve().parent.parent / "NasaSpaceApps/Assets.xcassets/MarsViking.imageset/MarsViking.jpg"


def main():
    # Source COG bounds: longitude 0..360° E, latitude 90..-90° planetocentric.
    # Read a downsampled overview, retaining the source orientation and color.
    with rasterio.Env(
        GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR",
        GDAL_HTTP_MULTIRANGE="YES",
        GDAL_HTTP_MERGE_CONSECUTIVE_RANGES="YES",
        GDAL_CACHEMAX=512,
        VSI_CACHE="TRUE",
    ):
        with rasterio.open(SOURCE) as dataset:
            if dataset.count < 3 or tuple(dataset.bounds) != (0.0, -90.0, 360.0, 90.0):
                raise ValueError("Unexpected Viking mosaic bounds or band count")
            rgb = dataset.read([1, 2, 3], out_shape=(3, 4096, 8192), resampling=Resampling.bilinear)
    image = Image.fromarray(rgb.transpose(1, 2, 0))
    image.save(OUTPUT, quality=92, subsampling=0, optimize=True)
    print(f"Wrote {OUTPUT} ({image.width} × {image.height})")


if __name__ == "__main__":
    main()
