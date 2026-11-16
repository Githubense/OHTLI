# Mars Data Provenance

## Globe image layers

The globe layers are visual context layers; none is the numeric DEM used by the router.

- **Optical:** NASA Ames colorized Viking MDIM 2.1, nominal source resolution approximately 232 m/pixel. The 8192 × 4096 `MarsViking.jpg` was independently derived with bilinear downsampling from the [USGS-hosted cloud-optimized source](https://asc-pds-services.s3.us-west-2.amazonaws.com/wms_basemaps/Mars/MDIM21_AMESColor/MDIM21_AMES_recolor_dd360_jpeg_cog.tif), using `Scripts/prepare_viking_globe.py`. It retains north-up planetocentric latitude and east longitude 0–360°, with no artistic tint applied during processing. This is a downsampled view, not new source detail. Source metadata: [USGS Astropedia](https://astrogeology.usgs.gov/search/map/mars_viking_colorized_global_mosaic_232m). NASA Ames produced the colorized mosaic and USGS publishes it as public domain.
- **THEMIS infrared:** [USGS controlled daytime infrared mosaic](https://asc-pds-services.s3.us-west-2.amazonaws.com/wms_basemaps/Mars/THEMIS_USGS/THEMIS_DayIR_ControlledMosaics_100m_v2_oct2018_cog.tif), nominal 100 m/pixel. It covers approximately 65°S–65°N; missing coverage and zero-valued gaps are dark grey. It is broad regional context, not a site-scale thermal-inertia map or a current temperature measurement.
- **THEMIS night infrared:** [USGS controlled nighttime infrared mosaic](https://asc-pds-services.s3.us-west-2.amazonaws.com/wms_basemaps/Mars/THEMIS_USGS/THEMIS_NightIR_ControlledMosaics_100m_v2_oct2018_cog.tif), nominal 100 m/pixel; the 4096 × 2048 display image is resampled to north-up, 0–360° east, with uncovered polar areas shown dark. It is regional context, not a live reading or a direct measurement of firmness.
- **Global geology:** USGS Scientific Investigations Map 3292 (Tanaka et al., 2014), 1:20,000,000, [official JMARS color raster](https://asc-pds-services.s3.us-west-2.amazonaws.com/pigpen/mars/geology/SIM3292_forJMars/sim3292_MarsGeologicMap_JMars_64ppd.zip). The bundled 4096 × 2048 image uses the published colors, nearest-neighbor resampling, and a longitude shift to 0–360° east. Global map units are regional context rather than site-scale geology. See the [USGS map and legend](https://doi.org/10.3133/sim3292).
- **MOLA:** [USGS MOLA 128/64 pixels-per-degree elevation merge](https://asc-pds-services.s3.us-west-2.amazonaws.com/wms_basemaps/Mars/MOLA/mola128_mola64_merge_90Nto90S_SimpleC_clon0_cog.tif), nominal source resolution approximately 463 m/pixel. A display color ramp represents elevation; this image is not the numeric DEM used by the router.
- MOLA and THEMIS are 4096 × 2048 north-up, planetocentric overview images in a 0–360° east longitude domain. `Scripts/prepare_globe_context.py` reads each source, switches the longitude domain from −180–180°, and downsamples it for display.
- WMTS service documentation: <https://trek.nasa.gov/tiles/apidoc/trekAPI.html?body=mars>

These downsampled global overview mosaics are for the globe. Local terrain rendering uses the HiRISE elevation grid and its matching local ortho image below.

## Gale local terrain and matching optical image

- Mission / instrument: NASA Mars Reconnaissance Orbiter / HiRISE stereo DTM.
- DTM product ID: `DTEEC_040770_1755_039280_1755_U01`.
- Dataset: `MRO-M-HIRISE-5-DTM-V1.0`.
- Catalog record: <https://www.uahirise.org/dtm/dtm.php?ID=ESP_040770_1755>
- PDS DTM image: <https://www.uahirise.org/PDS/DTM/ESP/ORB_040700_040799/ESP_040770_1755_ESP_039280_1755/DTEEC_040770_1755_039280_1755_U01.IMG>
- The DTM PDS label reports a 1.011763 m/post map scale and Mars 2000 areoid/equipotential vertical datum. `hirise_gale_context.f32` is a centered 128 × 128 sample crop taken every 8 source posts, giving an 8.094104 m grid spacing and a 1,027.951 m span between outer sample centers. Coordinates and the geographic footprint are computed from the PDS map projection in `terrain_metadata.json`.
- `hirise_gale_detail.f32` is a second, same-center 339 × 339 crop sampled every 3 source posts (3.035289 m spacing, 1,025.928 m sample span). It supplies the tabletop terrain and slope overlay and the synthetic horizon boundary; routing uses the smaller 128 × 128 grid. All grids use the same registered orthophoto footprint.
- `hirise_gale_native.f32` is the same 1,025.928 m footprint at the native 1.011763 m/post spacing (1015 × 1015 posts, origin 2639, 5608). The immersive mesh samples every post near the current waypoint and every third post farther away; the two regions share mesh vertices. The detailed area is regenerated as the waypoint moves. This adds no synthetic displacement. `terrain_native_metadata.json` records the source and footprint.
- The optical source is `ESP_040770_1755_RED_A_01_ORTHO.JP2`, the matching RED orthophoto named in the DTM’s PDS label. It has 0.252940754 m/pixel map scale, the same map projection and source stereo product lineage, and its label footprint contains the DTM crop. The bundled 4065 × 4065 image is the projected extent of the sampled grid. `prepare_hirise_ortho.py` derives its crop from both PDS labels and the DTM metadata. A documented exposure/contrast and red display tint is applied for visibility; this is not a radiometric product, SfS, or added relief.
- `prepare_hirise_grid.py` reproduces the numeric crop from the PDS3 `PC_REAL` image. No synthetic displacement or shape-from-shading has been applied.
- This is Gale Crater / Curiosity context. Its local footprint has not been confirmed to overlap Curiosity’s Altadena drill stop. The Altadena point remains a scenario marker and is not rendered as a verified site coordinate.

## Other layers and demo content

## Rendering and lighting

- The local terrain texture is the registered HiRISE orthophoto above, displayed with a documented red presentation tint. The 1:1 mesh uses DEM-derived vertex heights and normals; it has no invented relief or shape-from-shading.
- A single directional key light uses a fixed **visual afternoon preset** at Gale (15:00 local solar time, equinox declination) to reveal relief and produce shadows. This is a presentation setting, not a current Mars ephemeris, calibrated surface irradiance, or operational lighting forecast.
- The sky dome and low-intensity image-based fill are synthetic presentation assets. They add ambient color only; the direct key light carries the terrain form. The visible Sun disc is a scale cue, not an astronomical render.
- The Drone and Helmet views display a circular cutout of the HiRISE crop, surrounded by a synthetic, low-detail terrain skirt with rings approximately 350 m, 1.2 km and 24 km beyond its edge. The skirt is illustrative and does not represent mapped elevation outside the DTM footprint; the visual join still requires inspection for seams.

- The THEMIS globe layers are regional daytime and nighttime IR mosaics, with incomplete polar coverage. No local, registered Gale THEMIS thermal-inertia product is bundled or draped over the mesh. These globe images do not claim a local Gale measurement.
- Curiosity RAD is measured along the rover’s traverse, not as a complete gridded radiation field. Any radiation overlay in the app is a shelter/demo visualization, not a spatially complete RAD dataset. Instrument context: <https://science.nasa.gov/mission/msl-curiosity/science-instruments/>.
- The ISS interior is a showcase habitat. Its Mars landscape, sky dome, and 3 km / 8 km / 24 km horizon rings are synthetic scene context. The high-resolution DTM remains the registered ~1.03 km Gale crop; no elevation source is claimed for the outer rings.
- `SafetyAlert.wav` is a short synthetic spatial chime used for demo alert events.
- Airlock Alpha, route endpoints, obstacle and hazard overlays, terrain classes, shelter masks, crew locations, telemetry, playback, and storm events are synthetic demonstration inputs. The 171 kg crew/suit scenario and route comparisons are planner outputs over the bundled grid plus explicitly labeled scenario assumptions, not validated EVA guidance.
- Route weights are user-selected preferences. Velocity, friction, metabolic, thermal, radiation, shelter, and cooling thresholds are demo assumptions unless a UI/source label says otherwise. The router is deterministic but has not been validated for crewed Mars operations.

### Demonstration route budget

The planner uses adjustable-in-code `RouteConstraints` demonstration inputs: walking speed and exertion depend on synthetic surface class, oxygen and CO₂ use assumed duration capacities, and cooling water uses modeled energy divided by 2,480 kJ/kg. The default science stop is 30 minutes at 280 W. These values are not measured suit performance. The reported limiting reserve includes outbound consumption, a terrain-traversable minimum-energy return to the route origin from each waypoint, and the science stop at the destination. Return time and water are evaluated on that same return path; the calculation does not optimize all resources simultaneously. The comparison's straight-line reserve remains a simplified return-along-the-line estimate. Candidate searches use a finite set of resource weightings and may miss a feasible route. Shelter availability and a point of no return are not calculated. The return origin is a hypothetical scenario location, not an actual habitat.
