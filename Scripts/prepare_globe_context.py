#!/usr/bin/env python3
"""Create north-up 0–360°E MOLA and THEMIS day IR globe context images.

Requires rasterio, numpy, and Pillow; run from the project root.
"""
import math
from pathlib import Path

import numpy as np
import rasterio
from PIL import Image
from rasterio.enums import Resampling

BASE = "/vsicurl/https://asc-pds-services.s3.us-west-2.amazonaws.com/"
SOURCES = {
    "mola": "wms_basemaps/Mars/MOLA/mola128_mola64_merge_90Nto90S_SimpleC_clon0_cog.tif",
    "themis": "wms_basemaps/Mars/THEMIS_USGS/THEMIS_DayIR_ControlledMosaics_100m_v2_oct2018_cog.tif",
    "themis_night": "wms_basemaps/Mars/THEMIS_USGS/THEMIS_NightIR_ControlledMosaics_100m_v2_oct2018_cog.tif",
}
ASSETS = Path(__file__).resolve().parent.parent / "NasaSpaceApps/Assets.xcassets"
WIDTH, HEIGHT = 4096, 2048
RADIUS_M = 3396190.0


def main():
    with rasterio.Env(GDAL_DISABLE_READDIR_ON_OPEN="EMPTY_DIR", GDAL_HTTP_MULTIRANGE="YES",
                      GDAL_HTTP_MERGE_CONSECUTIVE_RANGES="YES", GDAL_CACHEMAX=512, VSI_CACHE="TRUE"):
        for kind, path in SOURCES.items():
            with rasterio.open(BASE + path) as dataset:
                if kind == "mola":
                    elevation = dataset.read(1, out_shape=(HEIGHT, WIDTH), resampling=Resampling.bilinear)
                    elevation = np.roll(elevation, WIDTH // 2, axis=1)
                    stops = np.array([-8000, -4000, 0, 4000, 8000, 16000, 22000])
                    colors = np.array([[30, 55, 110], [50, 105, 160], [98, 167, 152],
                                       [182, 199, 115], [211, 160, 99], [189, 94, 69], [240, 218, 178]])
                    rgb = np.stack([np.interp(elevation, stops, colors[:, i]) for i in range(3)], axis=-1).astype(np.uint8)
                    target = ASSETS / "MarsMola.imageset/MarsMola.jpg"
                else:
                    # The controlled mosaic covers approximately ±65° latitude.
                    # Display its uncovered polar regions and zero-valued gaps in dark grey.
                    half_height_m = math.pi * RADIUS_M / 2
                    rows = round(HEIGHT * (dataset.bounds.top - dataset.bounds.bottom) / (2 * half_height_m))
                    top = round((half_height_m - dataset.bounds.top) / (2 * half_height_m) * HEIGHT)
                    pixels = dataset.read(1, out_shape=(rows, WIDTH), resampling=Resampling.bilinear)
                    frame = np.full((HEIGHT, WIDTH), 24, np.uint8)
                    frame[top:top + rows] = np.where(pixels > 0, pixels, 24)
                    frame = np.roll(frame, WIDTH // 2, axis=1)
                    rgb = np.repeat(frame[..., None], 3, axis=2)
                    target = (ASSETS / "MarsTHEMISNight.imageset/MarsTHEMISNight.jpg" if kind == "themis_night"
                              else ASSETS / "MarsTHEMIS.imageset/MarsTHEMIS.jpg")
            Image.fromarray(rgb).save(target, quality=90, subsampling=0, optimize=True)
            print(f"Wrote {target}")


if __name__ == "__main__":
    main()
