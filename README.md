# OHTLI — Mars EVA Navigator

OHTLI is a visionOS prototype for exploring Mars terrain and planning a simulated extravehicular activity (EVA). A movable planning volume connects a Mars globe to a Gale Crater terrain map; the same mission can then be inspected from an aerial view or at helmet height.

The application uses bundled NASA and USGS data for geographic context and a deterministic terrain-based route planner. **Crew readings, the airlock, dust event, and suit-resource model are simulated. This is a planning demonstration, not operational EVA guidance or live Mars weather.**

## Explore the demonstration

1. Launch OHTLI and, if a launch window is shown, choose **Open Mars in Your Space**. Select a Gale / Mount Sharp marker on the globe, then choose **Open Gale sector**. Jezero is a globe marker; its detailed terrain is not included.
2. On the tabletop, inspect the terrain and select the EVA crew or a marker. Move the airlock or destination to recalculate the route. **Layers** offers the registered optical image and DTM-derived slope; **Route** opens the route comparison, modeled reserve, warnings, and source details.
3. Choose **Start emergency demo** to freeze a simulated crew position and calculate a one-way return to hypothetical Airlock Alpha during simulated dust conditions. **Explain return** uses the on-device Foundation Models system when available; otherwise it shows a labeled scripted explanation from the same planner results. Speech is optional and no microphone is required. **Reset demo** restores the prior planning state.
4. Use **3D Drone** to inspect the route from above or **Helmet** for a ground-level view. Navigation moves the scene, not the wearer's head camera. **Globe** or the close control returns to the mission hub. The volume's system window bar lets the wearer reposition the planning content and its controls together.

The green line represents the modeled route and the dashed red line is the direct comparison. A route can be unavailable when the modeled gates or budget reject candidate paths; this does not establish that no feasible path exists. The demo is offline: the dust warning is atmospheric context rather than a live forecast or solar particle event, and shelter availability is not calculated.

## Build and run

- macOS with Xcode **27.2** and the visionOS SDK and simulator runtime installed. The current app and test targets specify visionOS 27.0; select a matching or newer runtime.
- Open `NasaSpaceApps.xcodeproj` in Xcode, select the **NasaSpaceApps** scheme and an Apple Vision Pro Simulator, then build and run. An Apple Vision Pro can also be selected after configuring a signing team for your installation.
- The demo terrain and globe layers are bundled, so a network connection is not required for the planning demonstration. Apple Intelligence and SharePlay depend on system availability and configuration. The explanation has an offline scripted fallback.

For command-line builds and tests, run from the repository root and choose an installed simulator:

```sh
xcrun simctl list devices available
xcodebuild -project NasaSpaceApps.xcodeproj -scheme NasaSpaceApps \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' build
xcodebuild -project NasaSpaceApps.xcodeproj -scheme NasaSpaceApps \
  -destination 'platform=visionOS Simulator,name=Apple Vision Pro' test
```

If several matching simulators are installed, use `id=<simulator UUID>` in the destination instead. Simulator rendering and input do not replace headset checks for gaze, reachability, comfort, and spatial placement. Live Foundation Models behavior requires a supported device and enabled system model.

## Data and model scope

- **Local terrain:** a Gale-area crop of the Mars Reconnaissance Orbiter HiRISE stereo DTM `DTEEC_040770_1755_039280_1755_U01` and its registered RED orthophoto. Routing uses an approximately 8.09 m grid; the tabletop uses approximately 3.04 m samples and the immersive view uses the approximately 1.01 m source grid near the inspection area. The source orthophoto is approximately 0.25 m/pixel. The image has a presentation tint, and the crop's overlap with the Altadena drill location is unverified.
- **Global and regional context:** the globe includes NASA Ames / USGS Viking optical imagery, MOLA elevation, THEMIS day and night infrared mosaics, and the USGS global geologic map. THEMIS coverage is incomplete near the poles; these layers are not local live measurements. Curiosity RAD is measured along the rover traverse and does not supply a complete local radiation map here.
- **Route and resources:** the deterministic planner derives grade and distance from the bundled grid and applies demonstration traversal and resource constraints. Suit capacities, terrain classes, thresholds, and the emergency's starting resources are model inputs. The 50% reserve and other thresholds are not presented as validated NASA EVA policy. A bounded search cannot prove that no feasible route exists.
- **Synthetic scenery:** the distant terrain skirt and sky are illustrative; they do not extend the measured HiRISE footprint. Airlock Alpha, EVA positions and telemetry, dust, hazards, and modeled return estimates are scenario inputs or outputs.

The full source products, preprocessing, resolution, footprint, and limitations are documented in [Mars data provenance](NasaSpaceApps/Resources/MarsData/MARS_DATA_PROVENANCE.md). The [NASA Space Apps challenge](https://www.spaceappschallenge.org/2026/challenges/interplanetary-survival-guide-martian-map/) provides the Marswalk planning context. [Sol Explorers](https://github.com/saracen66/the-sol-explorers) is a workflow and visual reference; its Jezero terrain is not used as Gale data.

## Project layout

- `NasaSpaceApps/` — SwiftUI, RealityKit scenes, mission state, router, assets, and bundled data.
- `NasaSpaceAppsTests/` — routing, state, geometry, and explanation tests.
- `Scripts/` — source-data preparation scripts.
- `NasaSpaceApps/Resources/MarsData/MARS_DATA_PROVENANCE.md` — product references and dataset details.

## Demo video

The delivery video is planned at `Demo/OHTLI-demo.mp4`; its presence and duration should be verified in the delivered checkout. It is intended to show actual app footage with simulated conditions identified on screen.

## Attribution and licenses

NASA and USGS source products and the transformations used in this prototype are identified in the [data provenance](NasaSpaceApps/Resources/MarsData/MARS_DATA_PROVENANCE.md). The optional habitat asset has its own [source notes](NasaSpaceApps/Resources/MarswalkHabitat-Sources.md). Consult each source's terms before redistributing. This checkout does not currently include a project-wide software license; no license for the project's own code is implied by the public status of source datasets.
