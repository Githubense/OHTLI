#!/usr/bin/env python3
"""Build the globe geology texture from the public USGS SIM 3292 JMARS raster.

Requires Pillow and NumPy. The official source uses -180..180 degrees east;
the app's geographic globe mesh uses 0..360 degrees east.
"""
from io import BytesIO
from pathlib import Path
from urllib.request import urlopen
from zipfile import ZipFile
import json
import numpy as np
from PIL import Image

SOURCE = "https://asc-pds-services.s3.us-west-2.amazonaws.com/pigpen/mars/geology/SIM3292_forJMars/sim3292_MarsGeologicMap_JMars_64ppd.zip"
MEMBER = "JMars_64ppd/Mars_Sim3292_GlobalGeology_dd0_64ppd_forJmars.png"
OUTPUT = Path(__file__).resolve().parent.parent / "NasaSpaceApps/Assets.xcassets/MarsGeology.imageset"

Image.MAX_IMAGE_PIXELS = None
with urlopen(SOURCE) as response, ZipFile(BytesIO(response.read())) as archive:
    with archive.open(MEMBER) as source:
        image = Image.open(source).convert("RGB").resize((4096, 2048), Image.Resampling.NEAREST)
image = Image.fromarray(np.roll(np.asarray(image), 2048, axis=1))
OUTPUT.mkdir(parents=True, exist_ok=True)
image.save(OUTPUT / "MarsGeology.jpg", quality=95, subsampling=0)
(OUTPUT / "Contents.json").write_text(json.dumps({"images": [{"filename": "MarsGeology.jpg", "idiom": "universal"}], "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
