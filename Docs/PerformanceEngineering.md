# mhseals_sim performance engineering

This document covers device tiers (simulation profiles), how to benchmark the player, and the
measured state of the Unity `6000.5.10f1` / HDRP `17.5.0` checkout. Repository metadata that names
older releases is not authoritative. Flags and launch examples are in
[SimulationPhysicsAndRuntimeModes.md](SimulationPhysicsAndRuntimeModes.md); the subsystem design
is in [ArchitectureAndDesign.md](ArchitectureAndDesign.md).

All numbers below come from one reference machine (i7-12700K, RTX 4070 Ti SUPER, Vulkan) unless a
row says otherwise. Re-measure on your own hardware before relying on them.

## Settings and constraints

- Physics timestep: 0.02 simulated seconds.
- PhysX solver: 6 position iterations and 1 velocity iteration.
- Auto transform synchronization is disabled; reusable collision callbacks are enabled.
- Collision layers (Environment, Vehicle, DynamicObstacle, SensorQuery, SimulationTrigger) use a
  coverage-tested matrix. SensorQuery has no physical pairs; triggers overlap only vehicle,
  dynamic-obstacle and legacy bodies.
- The RoboBoat scene enables HDRP scripted water interaction.
- All three HDRP assets (High Fidelity, Balanced, Performant) run the same 128-resolution GPU
  water with readback; `SimProfileTests` fails if a simulation profile's asset drifts.
  Full-resolution CPU water raised process CPU from about 6% to 19%, so GPU readback stays.
- A graphics device and a real Vulkan loop are required. `-nographics`, and `-batchmode` without a
  display, do not drive the HDRP water query path.
- Do not change `QualitySettings.vSyncCount` at runtime in the Vulkan player; Unity 6000.5 crashes
  in `GfxDeviceVK::SetVSyncCount` on the reference machine. Every quality level ships with vsync
  off, and the simulation profile's `FrameRateCap` (`Application.targetFrameRate`) paces frames.

## Simulation profiles (device tiers)

`--crane-profile` picks which subsystems run. The simulation profile picks how much rendering and
sensor work they cost, so the same scene holds real time on weaker devices. A simulation profile
never changes physics (0.02 s step, water simulation, colliders) or the points per LiDAR scan.

Each tier is a `CraneSimProfile` asset in `Assets/Config/Performance/Resources/SimProfiles/`;
edit it in the Inspector (every field has a tooltip):

| Field | Full | Balanced | Minimal |
|---|---|---|---|
| `Pipeline` (HDRP asset) | High Fidelity | Balanced | Performant |
| `FrameRateCap` (fps; all cameras render once per frame) | 60 | 30 | 20 |
| `CameraResolutionScale` (robot RGB/depth textures) | 1 (1280×720) | 0.5 (640×360) | 0.25 (320×180) |
| `CameraHz` (RGB and depth; 0 = scene) | scene (15) | 10 | 5 |
| `DetectionHz` | scene (8) | 5 | 5 |
| `LidarHz` (72,000 points per scan always; the fusion node needs 10 Hz) | scene (10) | 10 | 10 |
| `ReducedEffects` (bloom, DoF, motion blur, SSAO, SSR, SSGI, contact shadows, volumetrics off) | off | on | on |
| `WaterDetail` (tessellation, caustics; render-only) | on | on | off |
| `Spectator` (window camera) | on | on | on |

Selection, highest precedence first:

1. `--crane-sim-profile full|balanced|minimal|auto` on the command line.
2. A saved manual choice: add `--crane-sim-profile-save` to store the named tier in
   `<persistentDataPath>/crane-sim-profile.json`; `--crane-sim-profile auto --crane-sim-profile-save`
   forgets it (and the cached measurement).
3. Auto: the cached result for this device (CPU model, core count, GPU, graphics API), or else a
   measurement in the real scene. Per tier: warm 3 s, measure 6 s capped (must deliver 97% of the
   cap), then 4 s with the cap lifted (must sustain 1.05× the cap). Both need a real-time factor of
   at least 0.95 and zero stale observations; any failure steps down a tier. Measuring takes about
   14 s per tier tried (42 s worst case). Unattended launches (`-batchmode`, `--crane-worker`,
   `--crane-benchmark`) never measure: they use the cached tier or Full and log
   `CRANE_SIM_PROFILE_UNATTENDED`; add `--crane-sim-profile-measure` to measure anyway.
   `Tools/Performance/run_worker.sh` pins `full` by default (`CRANE_SIM_PROFILE`). Concurrent
   players write the cache atomically.

Forcing a tier above the cached auto tier, `--crane-sim-profile-save` without a profile, and a
requested rate that matched no sensor all log a `CRANE_SIM_PROFILE` warning. The resolved profile
is published once, latched, as JSON in a `std_msgs/String` on `/crane/sim/profile` (not when ROS
transport is disabled).

The Editor without the flag uses the saved choice or Full and never measures. Adjust single
fields of the selected tier with `--crane-sim-set "CameraHz=10,Spectator=false"` (field names as
in the table; `FrameRateCap=0` uncaps); the assets stay untouched. Every launch logs
`CRANE_SIM_PROFILE_RESOLVED {json}` with the effective values and their source (`cli`, `saved`,
`auto-cache`, `auto-benchmark`, `editor-default`), plus one `CRANE_SIM_PROFILE_BENCHMARK` line per
measured tier.

`--crane-sim-profile headless` is rejected (exit 3): buoyancy, hydrodynamics and LiDAR water
culling query HDRP water, which needs a graphics device.

### Measured tiers

Roboboat course, 1280×720 window, 20 s runs with ROS transport off, on an existing X display.
Physics held 50 Hz (49.96–50.04 ticks/s) and the real-time factor was 1.00 in every run.

| Tier | fps (cap) | GPU ms | RSS | RGB/depth | LiDAR | Valid on this machine | Valid on 2 E-cores (`taskset -c 16,17`) |
|---|---|---|---|---|---|---|---|
| Full | 60 | 5.6 | 1.44 GB | 15 Hz 1280×720 | 10 Hz | yes | yes, 43 fps (cap not held) |
| Balanced | 30 | 8.1 | 1.19 GB | 10 Hz 640×360 | 10 Hz | yes | yes with the lowered rates, 27 fps (cap not held) |
| Minimal | 20 | 16.1 | 1.11 GB | 5 Hz 320×180 | 10 Hz | yes | yes, 20 fps |

Uncapped capacity (GPU ms per frame, full CPU): Full 3.12, Balanced 1.63, Minimal 1.35. Single
knobs from Full: reduced effects 2.04, half resolution 2.54, water detail off 2.89, spectator off
1.58. LiDAR hit rate (7.95–8.01%) and mean range (16.5–16.8 m) agree across tiers; scans differ in
timing, so checksums differ. CPU LiDAR plus ROS message creation cost the same in every tier
(about 7.6 ms per frame each at Full), which is why Balanced and Minimal also lower camera and
detection rates. Auto-select picks Full on the reference machine and Minimal on 2 E-cores. The
weak-CPU rows are simulated by restricting cores, and a weak GPU was not measured: by arithmetic
from the uncapped GPU times, Full holds 60 fps on a GPU up to about 5× slower, Balanced 30 fps up
to about 20×, Minimal 20 fps up to about 37×.

## Runtime profiles and sensor cost

The `--crane-profile` presets are listed in
[SimulationPhysicsAndRuntimeModes.md](SimulationPhysicsAndRuntimeModes.md#runtime-profiles).
Their measured effect on the RoboBoat scene:

- **Full visual sensors** (1280×720 RGB and depth at 15 Hz, 72,000-point LiDAR at 10 Hz): valid at
  1×. At 2× each camera completed 173 of 180 scheduled frames over 12 simulated seconds with up to
  seven ticks of observation age, which fails the delivery check.
- **`train-gpu`** (RGB and spectators off, depth + detections + LiDAR kept): 2.006× with 149 depth
  frames, 80 detection acquisitions, 100 LiDAR scans, valid water and no stale observations in a
  five-wall-second run. RGB off with depth at 4× delivered 338 of 900 depth frames and was
  rejected.
- **`--crane-disable-visual-sensors`** (no RGB/depth/camera info; LiDAR and non-visual sensors
  kept): about 4× with body and water behavior near the measured run-to-run floor.
- **`interactive-low`** (960×540 spectator, sensors unchanged): 12.503 ms mean GPU frame over three
  runs versus 12.755 ms for `interactive-high`, a modest 1.97% saving. All runs delivered 120 RGB
  and 120 depth frames, 64 detection acquisitions and 80 LiDAR scans over eight simulated seconds.
  Turning off a group of spectator-camera HDRP frame settings instead raised GPU time by about
  2.5% and was reverted.

Presentation settings must not replace the physical water asset used by scripted water queries.

## Benchmark invocation

Build the player:

```bash
unity build /path/to/mhseals_sim \
  --editor-version 6000.5.10f1 \
  --target StandaloneLinux64 \
  --execute-method CranePerformanceBuild.BuildLinuxWorker \
  --allow-dirty-build
```

Run one benchmark:

```bash
SDL_VIDEODRIVER=x11 ./Builds/CRANE-Worker/CRANE.x86_64 \
  -screen-fullscreen 0 -screen-width 640 -screen-height 360 \
  -logFile "$PWD/Logs/worker.log" \
  --crane-worker --crane-benchmark --crane-disable-ros \
  --crane-scene 'Roboboat Course' --crane-scenario aquatic-full-sensor \
  --crane-seed 1000 --crane-time-scale 1 \
  --crane-warmup 3 --crane-duration 30 \
  --crane-output "$PWD/bench/worker.json"
```

`Tools/Performance/run_worker.sh` wraps this and also samples GPU utilization with `nvidia-smi`
(set the output directory with `CRANE_RESULT_ROOT`). `Tools/Performance/sweep_workers.sh 1 2 4 8`
gives every process a distinct seed, ROS-TCP port, UDP port, output directory and `ROS_DOMAIN_ID`,
then writes aggregate summaries. ROS-side processes must use the matching port and domain.

Compare two runs at equal simulated timestamps:

```bash
python3 Tools/Performance/compare_benchmarks.py reference.json candidate.json \
  --output comparison.json
```

The result JSON includes real-time factor; physics/water/dynamics/LiDAR/sensor/ROS markers;
process CPU; GPU frame time; memory; GC allocation; episode/tick/queue counters; errors; body
states; water samples; LiDAR hit/range signatures; RGB/depth acquisition signatures; the
validation-stream path with captured/retained/dropped counts; cumulative invalid-water count; and
whole-run maximum observation age. Worker summaries report raw, valid-only and rejected aggregate
throughput separately and include `allWorkersValid`; never quote raw throughput from workers with
stale or failed observations.

### Multiple players

Nonvisual sensors at 4× per player:

| Players | Valid | Aggregate simulated s/s | Mean per-player RTF |
|---:|---:|---:|---:|
| 1 | 1/1 | 4.000 | 4.000 |
| 2 | 2/2 | 7.989 | 3.994 |
| 4 | 4/4 | 15.964 | 3.991 |
| 8 | 8/8 | 25.758 | 3.220 |

RGB-off sensor profile (1280×720 depth at 15 Hz, detections at 8 Hz, 72,000-point LiDAR at 10 Hz),
ROS transport suppressed:

| Players × requested RTF | Valid | Aggregate valid s/s | Stale observations | Decision |
|---:|---:|---:|---:|---|
| 1 × 2 | 1/1 | 2.003 | 0 | Accept |
| 2 × 2 | 2/2 | 4.000 | 0 | Accept |
| 4 × 2 | 4/4 | 8.003 | 0 | Accept; highest fully valid result |
| 5 × 2 | 2/5 | 4.001 | 6 | Reject |
| 8 × 2 | 0/8 | 0.000 | 834 | Reject |
| 8 × 1 | 2/8 | 2.008 | 14 | Reject |

The limit is concurrent depth-rendering density, not requested time scale alone.

With a full Nav2 graph per player (`Tools/Performance/sweep_nav2_workers.sh N`, isolated ports and
ROS domains): one and two players at 2× were valid (4.003× aggregate for two); six players at
0.75× were valid at 4.509× aggregate; four at 1× passed one run but had one stale command in
another; eight at 1× or 0.75×, and three at 1.5× or 2×, produced stale depth observations even
though every Nav2 goal succeeded. Choose player count and time scale from the complete validity
record, not from goal success.

## Useful arguments

| Argument | Meaning |
|---|---|
| `--crane-profile NAME` | Runtime preset (see the physics/runtime guide) |
| `--crane-list-profiles` | Print the profile catalog and exit |
| `--crane-runtime-report PATH` | Write the resolved runtime profile and capability state as JSON |
| `--crane-sim-profile`, `--crane-sim-set` | Device tier and per-field overrides |
| `--crane-interactive-width N`, `--crane-interactive-height N` | `interactive-low` window size (default 960×540, minimum 320×180) |
| `--crane-time-scale N` | Unity time scale; the physics step stays at 0.02 s |
| `--crane-worker`, `--crane-benchmark` | Unattended player and benchmark collection |
| `--crane-scene`, `--crane-scenario`, `--crane-seed`, `--crane-worker-id` | Scene, label, random seed and player ID |
| `--crane-warmup S`, `--crane-duration S`, `--crane-output PATH` | Benchmark timing and result path |
| `--crane-disable-ros` | Suppress ROS-TCP and the UDP bridge while still building messages |
| `--crane-disable-ros-tcp`, `--crane-disable-sitl` | Suppress only ROS-TCP/`/clock`, or only the ArduPilot JSON UDP bridge |
| `--crane-disable-visual-sensors` | Disable RGB, depth and camera info |
| `--crane-disable-rgb`, `--crane-disable-depth`, `--crane-disable-camera-info`, `--crane-disable-detections` | Disable one sensor stream |
| `--crane-depth-backend gpu\|geometric\|off` | Select rendered, PhysX-geometric or no depth |
| `--crane-geometric-depth-validation` | Run geometric depth layout/occlusion/motion/thin-geometry checks and exit |
| `--crane-geometric-depth-fixture`, `--crane-depth-width`, `--crane-depth-height`, `--crane-depth-hz` | Add an obstacle-rich geometric depth stream to a benchmark |
| `--crane-detection-visibility-validation`, `--crane-detection-visibility-validation-output PATH` | Run the detection visibility check and exit; optionally write its JSON result |
| `--crane-disable-lidar-debug-rays` | Disable LiDAR debug drawing only |
| `--crane-lidar-command-validation`, `--crane-lidar-pack-validation`, `--crane-lidar-process-validation` | Compare Burst LiDAR command generation, packing or return processing with the managed reference path |
| `--crane-lidar-batch-size N` | Override the LiDAR job batch size for sweeps |
| `--crane-depth-buffer-validation` | Compare one reused depth payload byte-for-byte with its GPU readback |
| `--crane-fixture contact-heavy` | Add a 144-body contact fixture |
| `--crane-contact-fixture-legacy-layers` | Run that fixture on Default layers for A/B tests |
| `--crane-action-policy latest\|bounded`, `--crane-max-action-lag-ticks N` | Command acceptance policy |
| `--crane-reset-probe` | Run a scene-reload A→B→A check before measurement |
| `--crane-no-signatures` | Skip full-frame hashing for throughput runs |
| `--crane-validation-period S`, `--crane-validation-capacity N`, `--crane-validation-output PATH` | Body/water snapshot interval, in-memory retention (default 256) and JSONL stream |
| `--crane-ros-ip`, `--crane-ros-port`, `--crane-mavros-port` | Per-process ROS-TCP endpoint and UDP listen port |
| `--crane-traj PATH`, `--crane-traj-hz N` | Write the robot's pose after physics (default 20 Hz) with run events |

## Measured changes

Roboboat scene, fixed 0.02 s physics, GPU water, ROS transport suppressed, 640×360 window unless
stated.

| Change | Before | After | Decision |
|---|---:|---:|---|
| Persistent LiDAR buffers/direct point packing, 10 s | 2991 ms LiDAR, 322.5 MB GC | 918 ms, 8.9 MB GC | Keep |
| LiDAR worst scan/frame | 45.1 ms | 13.3 ms | Keep |
| Direct camera readback packing, 6 s at 1× | 1647.8 ms sensor callback | 1456.4 ms | Keep |
| Direct camera ROS message creation | 2179.7 ms total, 28.8 ms max | 1938.6 ms total, 15.2 ms max | Keep |
| Automatic camera render → manual 15 Hz render | 12.44 ms GPU frame | 14.01 ms plus HDRP water-buffer warnings | Reverted |
| GPU water → full-resolution CPU water | about 6% process CPU | about 19% | Reverted |
| Strip sensor-camera HDRP opaque/transparent passes at 2× | 449 depth frames, zero stale | 441 frames, 8 stale | Reverted |
| Replace the `train-gpu` sensor camera's color target with a 64×64 water driver, 2× | 13.998 ms GPU frame | 14.756 ms | Reverted |
| Nine-ray partial-visibility detections at 2× | depth-only profile valid | 10 stale depth acquisitions | Replaced with centre-ray occlusion |
| Adaptive partial-visibility detections, 2× | 0.05276 ms/frame centre-ray path | about 0.053 ms/frame, zero stale | Keep; renderer probes run only when the centre is occluded |
| Classified 144-body contact fixture | 0.5837 ms/physics frame on Default | 0.5788 ms classified | Keep for correctness; no speed claim |
| Classified collision layers in the production scene, 2× | all colliders on Default | 2.00136× → 2.00099× RTF; max paired RMS 4.50 mm position, 4.84 mm water | Keep for correctness; no speed claim |
| Embedded connector registration fix, live Jazzy 1× | two endpoint publisher registrations for one clock | one connection, one registration per topic | Keep pinned patch |
| Connector per-command serializer, live Jazzy 1× | rare startup frame corruption forced a reconnect | zero endpoint errors or duplicate nodes | Keep; the shared serializer was not thread-safe |
| Nav2 `NavigateToPose` with NavFn, BT and LiDAR costmaps, live Jazzy 1× | controller-only fixture | success; 79 commands accepted, zero stale/rejected; 22.4 ms goal-to-first-command; 1.001× | Keep; ground-truth odometry only |
| Scene reload + live Nav2, Jazzy 1× | reload validated without a controller | success after `/clock` rewind; one Unity connection at a time; zero duplicate endpoint nodes | Scene reload is the ROS-connected reset baseline |
| Live Nav2 at 2× for 12 s | rejection counts only | 40/40 commands stamped; source-to-application mean/max 4.175/7 ticks; queue 1/1 tick | Keep lag bounds in the Nav2 summary |
| Spectator HDRP frame-setting overrides | 12.755 ms GPU frame | 13.070 ms | Reverted |
| `interactive-low` resolution only | 12.755 ms GPU frame | 12.503 ms at 960×540 | Keep; 1.97% saving |
| LiDAR Burst ray-command generation, 2× | 3.689 ms/frame LiDAR | 1.904 ms; 72,000/72,000 commands matched | Keep; 48.4% lower |
| LiDAR Burst PointCloud2 packing, 2× | 0.567 ms/frame packing | 0.099 ms; 864,000/864,000 bytes matched | Keep; 82.5% lower |
| LiDAR `colliderEntityId` hit classification, 2× | 0.517 ms/frame processing | 0.227 ms; 72,000 classifications matched | Keep |
| Disable LiDAR debug rays alone, 2× | debug drawing on | no repeatable improvement | Reverted as an optimization; `train-*` presets still suppress the rays |
| Burst LiDAR return processing, 2× | 0.229 ms processing, 0.966 ms LiDAR | 0.121 ms, 0.860 ms; bytes matched exactly | Keep |
| HDRP patch search batch size 1 → 8, 2× | 1.0464 ms/frame water query | 1.0451 ms | Reverted; within run variation |
| Reuse `SubmergedData.triangleAreas` in `GeneralDynamics`, 2× | 1.2705 ms/frame dynamics | 1.2822 ms | Reverted |
| Conditional uniform-current query reuse, 2× | 1.0481 ms/frame `Current`; 1.0491 ms water query | 0.0437 ms; 0.0644 ms | Keep when both HDRP spatial-current features are off |
| Reuse managed depth payload with ROS transport suppressed, 2× | 0.929 ms/frame depth callback | 0.258 ms; 3,686,400 bytes matched | Keep conditional path |
| Geometric depth in the production scene, Vulkan 1× | GPU depth owned the water render loop | 76 frames, one 64×64 water driver, zero invalid water queries | Keep camera-ownership fix; not graphics-free |
| LiDAR batch 500 → 64, 2× | 0.738 ms/frame raycast | 0.692 ms; all equivalence checks passed | Keep in the production prefab |
| LiDAR batch 500 → 2000, 2× | 0.739 ms/frame raycast | 0.899 ms | Rejected |

Notes on the larger items:

- **Uniform current.** HDRP 17.5 derives the current direction from the spectrum's base
  orientation and only rotates it by position when a large- or ripple-current map is active. The
  Roboboat surface disables both, yet the legacy `Current` component projected every submerged
  face. Querying once per tick while both features are off cut `Current` by 95.8%; position RMS
  against the baseline (1.72 mm) was below the baseline's own repeat variation (1.94 mm).
- **Depth payload reuse.** ROS-TCP serializes queued messages on its sender thread, so with
  transport on every frame still needs its own array. The reuse applies only when transport is
  suppressed and does not reduce ROS-enabled serialization or bandwidth.
- **LiDAR batch size.** The production sensor has 72,000 beams; batch 64 cut the raycast marker by
  6.2% and full LiDAR by 3.7%. Batch size is a scheduling parameter, not an observation change.
- **Detections.** When the aggregate centre is blocked, the detector samples at most four renderer
  centres, rejects objects below the visible-fraction threshold and scales confidence by that
  fraction. The schedule keeps fractional remainder, so 8 Hz produces exactly 80 acquisitions in
  ten simulated seconds.
- **Repeatability.** A 1× versus 4× comparison measured 9.6 mm position RMS and 13.6 mm water-height
  RMS, while a repeated 1× run already varied by 14.3 mm and 16.2 mm. Body and water differences
  therefore did not reject 4×; visual-sensor delivery did.

## Correctness fixes found during profiling

- `MotorBase` initializes runtime caches in `Awake()`; `OnValidate()` alone does not run in
  standalone players.
- `Lidar3D` fills every horizontal/vertical beam index; earlier indexing populated only a fraction.
- Sensor period accumulators keep their fractional remainder: 10 Hz LiDAR produces 60 scans in six
  simulated seconds instead of 50, and 15 Hz cameras produce 90 frames.
- The depth camera keeps its serialized camera reference.
- Async camera work has a bounded queue, acquisition tick and episode ID; old-episode callbacks are
  discarded and no callback touches a destroyed camera during shutdown.
- `--crane-disable-ros` disables both ROS-TCP and the legacy-named `MAVROSConnection` bridge.
- Camera noise shaders are always included in standalone builds.
- ROS thruster and PWM callbacks enqueue latest-value commands; actuator changes happen only after
  episode/sequence/lag checks in `FixedUpdate`.
- Runtime scene selection suppresses the transient build-index-zero ROS graph, so a requested
  scene opens one endpoint connection instead of two.
- `ROSOmniXCommand` applies stamped commands only from `FixedUpdate`, converts the header stamp to
  an acquisition tick and stops after a simulated-tick timeout. The Omni-X mixer combines
  translation and yaw before saturation instead of discarding translation on turns.

## Remaining bottlenecks

1. Full-resolution RGB/depth readback is the largest sensor cost and limits full-sensor runs to 1×
   on the reference machine.
2. LiDAR remains a material CPU cost (about 1 ms/frame at 2×). The next measurement target is GPU
   depth/render work rather than another LiDAR rewrite.
3. Hull water queries are issued per component rather than batched per water surface.
4. Live ROS-TCP sensor transport moves about 64 MB/s of raw payload at 1× (depth plus LiDAR).
5. Nav2 `Twist` and PWM commands carry no source-observation stamp; localization/SLAM in the loop
   and lockstep are unvalidated.
6. In-place reset is incomplete; use scene reload. A scene-reload A→B→A probe reloaded in 61.3 ms
   and differed from a fresh run by 3.70 mm position RMS and 8.31 mm water-height RMS.
7. Explicit `Physics.Simulate` stays deferred until every `FixedUpdate()` dependency has an
   exactly-once step path.

A 60-second full-sensor stress run completed at 1.000× with 900 RGB frames, 900 depth frames and
600 LiDAR scans, zero stale/failed observations and no logged errors. Memory stayed close to its
initial level. Validation samples stream to JSONL with bounded in-memory retention, but multi-hour
soak tests have not been run.
