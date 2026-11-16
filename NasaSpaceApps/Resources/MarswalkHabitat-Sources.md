# Marswalk Habitat scene — data and credits

This is a fictional Mars-surface habitat visualization using NASA ISS geometry as its structural design basis. It is not a representation of an ISS installation on Mars.

## NASA geometry

- NASA Astrobee media repository: <https://github.com/nasa/astrobee_media>
- Imported ISS meshes: `astrobee_iss/meshes/cupola.dae` and `astrobee_iss/meshes/node_3.dae`, with the repository's original interior textures. Node 3 is placed at its 0.2 m lateral / 2.0 m axial offset relative to Cupola in the repository URDF.

## Mars panorama

- NASA/JPL PIA26699: [Perseverance Mars rover surveys Crocodile Bridge](https://www.jpl.nasa.gov/images/pia26699-nasas-perseverance-mars-rover-surveys-crocodile-bridge/)
- The natural-color 360 panorama is assembled from Mastcam-Z images acquired on Sol 1717 (971 images) and Sol 1754 (9 images). A half-resolution source image is hosted by the ASU Mastcam-Z archive: <https://mcz-images.sese.asu.edu/Mastcam-Z_360_Crocodile_Bridge_Sols1717-1754_L0_natural_2x.jpg>.
- The image is mapped onto an inward-facing dome and displayed as the distant view. It is real rover imagery, not a live feed.

## Terrain

- HiRISE DTM product: `DTEEC_045994_1985_046060_1985_U01.IMG` (MRO/HiRISE, 1.0097 m/pixel source sampling, Jezero candidate landing-site tile): <https://www.uahirise.org/PDS/DTM/ESP/ORB_045900_045999/ESP_045994_1985_ESP_046060_1985/DTEEC_045994_1985_046060_1985_U01.IMG>
- Orthoimage: `ESP_045994_1985_RED_C_01_ORTHO.JP2`, from the same HiRISE tile.
- Blender includes a 500 m square mesh sampled every two source pixels (about 2.02 m between vertices). The orthoimage is the HiRISE RED single band, color-tinted for a Mars-like presentation; the measured elevation values are preserved at meter scale.
- The foreground DTM tile and Crocodile Bridge panorama are both Jezero-region source data but are not registered together as a single surveyed camera location.
- The app disables the DTM mesh in the habitat view because its 500 m footprint crosses the cupola camera position. The DTM remains available to the operational map; the panorama supplies the habitat's distant Mars lookout.
- NASA/JPL MARTIAN terrain workflow: <https://github.com/nasa-jpl/martian>.

## Archived MEDA display

The instrument overview and PDS archive are available at <https://pds-atmospheres.nmsu.edu/data_and_services/atmospheres_data/PERSEVERANCE/meda.html> and <https://atmos.nmsu.edu/PDS/data/PDS4/Mars2020/mars2020_meda/data_derived_env/>.

The panel shows sol-wide medians from the archived MEDA derived-environment CSV products for Sol 1717:

- Pressure: 641.73 Pa median (`WE__1717___________DER_PS__________________P01.CSV`)
- Relative humidity: 0.02% median (`WE__1717___________DER_RHS_________________P01.CSV`)
- Humidity sensor temperature: 248.25 K median (same RHS product)

The display is explicitly marked **ARCHIVED MEDA / NOT LIVE**. “RH sensor temperature” is retained as the source field meaning; it is not presented as a general atmospheric temperature.

## Outputs

- `MarswalkHabitat.blend`: editable Blender project, with packed textures, a 1 m scene scale, camera, lights, NASA station geometry, terrain, Mars panorama and MEDA readout.
- `MarswalkHabitat.usdc`: exported Universal Scene Description stage.
- `MarswalkHabitat.usdz`: packaged Apple-friendly scene archive generated with `usdzip`.
- `MarswalkHabitat_Preview.png`: camera render from inside the habitat.

The photoreal finish comes from the source textures and image-based exterior, PBR material tuning, lighting, and a cinematic camera; the assembled habitat itself is a static visualization rather than a physics simulation.
