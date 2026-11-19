# mhseals_sim physics, ROS interface and runtime modes

This is the practical reference for people driving the RoboBoat simulator from ROS 2 / Nav2 or
editing the boat. It covers what the current checkout simulates, the coordinate and timing
conventions components rely on, the ROS topics and frames, and how to launch the player.
Internal design is in [ArchitectureAndDesign.md](ArchitectureAndDesign.md); benchmarking and
device tiers are in [PerformanceEngineering.md](PerformanceEngineering.md); the tuned Nav2
configuration is in [RoboBoatNavigationBaseline.md](RoboBoatNavigationBaseline.md).

Many classes and every command-line flag still carry the engine's historical `Crane`/`--crane-`
prefix. Those names are real; use them as written.

## Conventions

### Units and coordinate frames

SI units throughout unless a serialized field or API says otherwise:

| Quantity | Convention |
|---|---|
| Position, distance | metres |
| Linear velocity / acceleration | m/s, m/s² |
| Mass, force, torque | kg, N, N·m |
| Unity inspector angles | normally degrees |
| Angular velocity and hydrodynamic rates | rad/s unless the API says degrees |
| Simulation time | scaled Unity seconds |

Unity world space is left-handed and Y-up. ROS messages use REP 103 (FLU body frame: forward,
left, up; ENU world). Code that converts between Unity and ROS must use the ROS-TCP Connector's
`ROSGeometry` helpers or an explicitly tested mapping; do not swap or negate axes ad hoc.

The RoboBoat hull is imported so that its **visible bow (LiDAR and catamaran noses) is hull-local
`-X`**, not `+Z`. The logical ROS body frame is a -90 degree rotation about Unity Y from the
imported physics body, and the same correction is applied to commands, odometry, TF, sensor
child frames and the docking evaluator. Details are in
[RoboBoatNavigationBaseline.md](RoboBoatNavigationBaseline.md#geometry-and-frames).

Topic frame IDs are strings configured on sensor components (`base_link`, `imu_link`,
`lidar_link`, `front_camera_link`, `gps_link`). A frame ID does not by itself publish a TF edge;
the navigation-state adapter described below publishes `odom -> base_link` and the sensor child
edges.

### Time and stepping

The fixed physics step is `0.02` simulated seconds (50 Hz). A process-wide clock advances its
tick exactly once per Unity `FixedUpdate`; a scene load starts a new episode. `Time.timeScale`
(`--crane-time-scale`) changes how fast Unity tries to run fixed steps in wall time; it never
enlarges the physics step.

Simulation-critical code uses Unity lifecycle callbacks:

- `Awake`/`Start`: cache bodies and configuration, resolve references, allocate buffers.
- `FixedUpdate`: actuator dynamics, forces, sensor schedules and ROS publication schedules.
- `Update`/`LateUpdate`: presentation.
- Render callbacks and `AsyncGPUReadback`: RGB/depth acquisition.
- ROS callbacks: enqueue commands only; actuator changes happen at the next fixed step.

`Physics.Simulate()` alone does not run these callbacks, so there is no safe manual-step mode.

`/clock` and `Clock.time` are episode-relative: a scene load starts the clock at zero. Run every
ROS node with `use_sim_time:=true`.

### Physics bodies and collision layers

`IPhysicsBody` is the shared force/pose abstraction, implemented by `RigidbodyAdapter` and
`ArticulationBodyAdapter`. Normal vehicle motion must come from forces, torques, articulation
drives, gravity and contact; direct transform or velocity assignment is reserved for resets.

Mass, inertia, centre of mass, collider geometry, solver settings and collision layers are part of
the physical model. Collision-layer ownership is a project convention:

| Layer | Ownership |
|---|---|
| Environment | fixed shore, tents and other world geometry |
| Vehicle | colliders owned by the boat's Rigidbody/ArticulationBody |
| DynamicObstacle | physical or script-moved docks, buoys and obstacles |
| SensorQuery | geometry visible to sensor ray queries but excluded from contacts |
| SimulationTrigger | trigger volumes that overlap vehicles/obstacles without contact response |

## Boat physics

### Water coupling

The boat is force-driven and coupled to HDRP water:

```text
HDRP spectrum and displacement
  -> CPU-accessible water search data
  -> moving water patch around the hull
  -> clipped submerged hull mesh
  -> buoyancy, hydrodynamic and thruster forces, PhysX contacts
  -> ArticulationBody integration
```

`Submersion` builds a grid patch around the hull. `Patch` batches HDRP `WaterSimulationSearchJob`
searches (eight-iteration limit, 0.01 m error target). The hull mesh is clipped against that
surface to get submerged triangles, face centres/normals, centroid and displaced volume.
`Buoyancy` applies Archimedes' force `F_b = ρ_water · g · V_displaced` at the centre of
buoyancy.

Because buoyancy queries HDRP water, the player needs a graphics device even when nobody is
watching (see [Headless runs](#headless-runs)).

### The boat plant (default)

On every scene with a thruster-driven articulation, `RoboBoatPhysics` applies one
`MarineSurfacePlant` to the hull from a boat profile (`Assets/Config/Boats/Resources/`). It sets
the mass layout, zeroes Unity link damping, disables the older per-face water components
(`FossenDynamics`, `GeneralDynamics`, `Current`) and logs `CRANE_ROBOBOAT_PHYSICS` and
`CRANE_PLANT_APPLIED`.

The plant (`MarinePlanarModel`) is a surge/sway/yaw maneuvering model in body FLU at the centre
of gravity:

```text
M = M_RB + M_A,   M_RB = diag(m, m, I_z),   M_A = [[a11,0,0],[0,a22,a26],[0,a26,a66]]
M ν̇ = τ_h − C_RB(ν)ν,   τ_h = τ + M_A ν̇_c − C_A(ν_r)ν_r − D(ν_r)
```

`ν_r` is velocity relative to the water, so a current carries the boat. Each axis uses sign-split
linear-plus-quadratic damping `D(s) = (D1 + D2|s|) s`. Heave, roll and pitch are damped
separately; buoyancy still comes from the clipped hull.

Each thruster (`ThrusterModel`) goes from ESC pulse to thrust: the pulse is clamped to
1100-1900 µs, effort `q = clamp((p − 1500 − offset)/400, ±1)` with an optional deadband, an
optional dead time, steady thrust `K_f q²` forward / `−K_r q²` reverse (optionally scaled by
supply voltage), and a first-order lag. Force is applied at the thruster mount and scaled by the
submerged fraction, so PhysX produces the matching moment.

The `ideal` profile (`Tools/Characterization/profiles/ideal.json`) holds the current priors:

| Parameter | Ideal value |
|---|---|
| Mass / inertia (roll, pitch, yaw) | 30 kg / 2.2, 2.0, 4.1 kg·m² |
| Added mass a11, a22, a66 | 1.5, 15.0, 1.23 |
| Surge damping D1, D2 | 10, 19.4 |
| Sway damping D1, D2 | 15, 41.7 |
| Yaw damping D1, D2 | 10, 19.3 |
| Thrusters | four, at (±0.27, ±0.34) m, 45-degree diagonals, 51.5 N full-command thrust (T200 at 16 V prior), no lag or deadband |
| Speed envelope (surge, sway, yaw) | 2.5 m/s, 1.7 m/s, 1.9 rad/s |

Every parameter is marked `prior` with a reason (no weigh-in, no field data, no bollard pull).
Treat them as estimates until a characterization passes.

### Boat profiles

| `--crane-boat-profile` | Use it for | Numbers |
|---|---|---|
| `ideal` (default) | Validating logic and ideas: nominal geometry, symmetric priors, no lag, deadband or noise | Priors |
| `characterized` | Runs that should behave like the real boat | `ideal`, overwritten only where real data passed the quality gate; every parameter records its status and reason |

- `--crane-boat-profile-json PATH` overrides the selected asset with a profile JSON (same schema).
- Every run logs `CRANE_PLANT_APPLIED profile=<name> sha256=<profile json> status=<summary>`.
  Only compare results that used the same profile and hash.
- `--crane-roboboat-legacy-physics` skips the plant and keeps the scene's authored physics
  (logged as `CRANE_PLANT_LEGACY`). That older path uses `GeneralDynamics` face drag, `Current`
  and the deprecated `FossenDynamics`, which has known defects (wrong added-mass sign, surge read
  from the mesh's sway axis); prefer the default plant.
- `--crane-calibration-faults JSON` adds a separate actuator/mass error layer on top of either
  profile. It never changes the profile's numbers.
- A robot selected with `--crane-robot NAME` whose thrusters the profile does not name gets a
  default profile built from its URDF mass/inertia and thruster mounts (`CRANE_PLANT_DEFAULT`).
- Today `characterized` equals `ideal`: the only saved characterization
  (`mhseals_testing/config/sim/hardware_crane.yaml`) is simulator-derived, and the gate rejects it
  (`Tools/Characterization/profiles/characterized.gate.json` lists the reasons).

To refresh `characterized` from a field survey (mhseals_testing characterization-v2):

```bash
python3 -I Tools/Characterization/import_yaml.py --yaml <data>/characterization/<fit>-survey.yaml \
    --out-profile Tools/Characterization/profiles/characterized.json \
    --out-report Tools/Characterization/profiles/characterized.gate.json
<Unity> -batchmode -quit -projectPath . -executeMethod \
    Sim.Physics.Water.Boat.Editor.CraneBoatProfileImport.ImportFromCommandLine \
    --crane-profile-json Tools/Characterization/profiles/characterized.json \
    --crane-profile-asset Assets/Config/Boats/Resources/Characterized.asset
```

The gate attributes every rejection to its source, never to the hull:

- provenance: `SIM_DERIVED`, `PROVENANCE_MISSING` (also a dirty mhseals_testing tree), `CALIBRATION_INVALID`;
- conditions: `CONDITIONS_POOR`;
- procedure: `HOLD_INVALID:baseline_unsettled` means the coast before a hold was too short.

`M_eff` stays at its prior until a survey records t95.

### Wind and current

| Flag | Effect |
|---|---|
| `--crane-water-current speed,toward_deg` | Water current (direction it flows toward, counter-clockwise from world +x) |
| `--crane-wind speed,toward_deg` | World-fixed wind: drag `½ρ Cd A |u| u` on the above-water area (0.30 m² ahead, 0.40 m² abeam, Cd 1) with Ornstein-Uhlenbeck gusts (25 %, 8 s) and veer (10 deg, 30 s), seeded by `--crane-seed` |
| `--crane-disturbance-after s` | Wind and current start after `s` seconds and ramp in over 10 s, so a run begins where the boat was placed |

`OmniXController` is the four-thruster X mixer used by the velocity input and manual driving; it
is a command mixer, not a dynamics model.

## Sensors

| Sensor | Default topic | Frame | Notes |
|---|---|---|---|
| 3D LiDAR | `/points` (`sensor_msgs/PointCloud2`) | `lidar_link` | 10 Hz; 72,000 beams as authored, or VLP-16 geometry under the RoboBoat contract |
| 2D LiDAR | `scan` | `lidar_link` | |
| RGB camera | `camera/image_raw` | `front_camera_link` | 1280×720 at 15 Hz by default |
| Depth camera | `camera/depth` (`32FC1`, metres, optical-axis Z) | `front_camera_link` | |
| Camera info | `camera/camera_info` | `front_camera_link` | |
| Semantic detections | `/detections` (3D boxes) | `front_camera_link` | 8 Hz by default; no RGB inference |
| IMU, GPS | `imu/raw`, `gps/raw` (scene components) | `imu_link`, `gps_link` | replaced under `--crane-roboboat-contract` |

Sensor rates are in simulated time and keep fractional remainders, so 15 Hz does not drift
against the 50 Hz physics step. The simulation profile (see
[PerformanceEngineering.md](PerformanceEngineering.md#simulation-profiles-device-tiers)) can
lower camera resolution and rates on weak machines.

- **RGB and GPU depth** use bounded two-request asynchronous readback queues. A full queue drops
  the observation instead of adding latency; results from an earlier episode are discarded.
  Depth is independent of RGB.
- **Geometric depth** (`--crane-depth-backend geometric`) replaces GPU depth with batched PhysX
  raycasts. It sees colliders only: no alpha-tested or transparent surfaces and no water surface
  without matching collider geometry. `--crane-depth-backend gpu|geometric|off` selects the
  backend.
- **LiDAR** uses persistent native buffers, Burst ray-command generation, batched PhysX raycasts
  (batch size 64 on the production prefab) and Burst PointCloud2 packing.
  `--crane-lidar-returns-only` publishes only returns, as the Velodyne driver does.
  `--crane-lidar-water-level y` drops returns below the water surface.
- **Detections** use registered scene objects, camera frustum/range tests, centre-ray occlusion
  and a distance-based confidence. If the centre is blocked, up to four renderer centres are
  probed and confidence is scaled by the visible fraction. Class confusion, correlated noise,
  false positives and latency models are not implemented. Under a generated course,
  `--crane-detection-labels oracle|camera` picks the label mode (see [Course.md](Course.md)).
  `--crane-detection-visibility-validation` runs a built-in clear / partially occluded / fully
  occluded check and exits.

## ROS interface

The player talks to ROS 2 through the embedded ROS-TCP Connector and a `ros_tcp_endpoint` node
(`--crane-ros-ip`, `--crane-ros-port`, default port 10000). `--crane-disable-ros` suppresses all
transport while still building messages (for benchmarks); `--crane-disable-ros-tcp` suppresses
only ROS-TCP and `/clock`.

### Ground-truth navigation state

`--crane-ros-nav-state` publishes `nav_msgs/Odometry` on `/crane/odom` and `odom -> base_link` on
`/tf` at 50 Hz from the boat's physics body, plus `base_link` edges for `lidar_link`,
`front_camera_link`, `imu_link` and `gps_link` when present. Linear and angular velocity are in
the body frame (ROS FLU); odometry and TF share one episode-relative timestamp. Overrides:
`--crane-ros-odom-topic`, `--crane-ros-tf-topic`, `--crane-ros-odom-frame`,
`--crane-ros-base-frame`, `--crane-ros-nav-state-hz`, and `--crane-ros-nav-child-frames`
(comma-separated, or `none`).

### Velocity input (`TwistStamped`)

`--crane-ros-cmd-vel [TOPIC]` (default `/crane/cmd_vel_stamped`) subscribes to
`geometry_msgs/TwistStamped`, a **desired body velocity** (`linear.x` surge m/s, `linear.y`
sway m/s, `angular.z` yaw rate rad/s). `ROSOmniXCommand` closes a feed-forward + PI loop on the
measured body velocity and feeds the Omni-X mixer, which combines translation and yaw before
normalizing the four thrusters.

| Flag | Default |
|---|---|
| `--crane-cmd-vel-linear-scale`, `--crane-cmd-vel-yaw-scale` | 1 m/s, 1 rad/s |
| `--crane-cmd-vel-linear-feed-forward`, `--crane-cmd-vel-yaw-feed-forward` | 0.21, 0.24 |
| `--crane-cmd-vel-linear-kp`, `--crane-cmd-vel-yaw-kp` | 0.1, 0.05 |
| `--crane-cmd-vel-linear-ki`, `--crane-cmd-vel-linear-integral-limit` | 0.1, 0.2 |
| `--crane-command-timeout-ticks` | 25 ticks (0.5 s); then effort goes to zero and integrators reset |

Nav2 publishes plain `Twist`; the Nav2 launcher's fixture node stamps and forwards it to
`/crane/cmd_vel_stamped`.

### PWM input (the boat's own mixer)

`--crane-ros-thruster-pwm [TOPIC]` (default `/thrusters/pwm`) drives the four thrusters from
`std_msgs/UInt16MultiArray` ESC pulse widths (physical outputs 1-4, microseconds), the signal the
boat's ODROID puts on its PWM pins. mhseals_hardware's `thruster_pwm_node` publishes it with
`output_backend: topic`, after the boat's own mixer, channel map and calibration, so the
simulator exercises the tuned allocation rather than `OmniXController`'s mixer.

- Each pulse maps through the shared `EscPwm` model (1100-1900 µs, 1500 neutral).
- `--crane-pwm-deadband` adds an ESC deadband in microseconds.
- `--crane-pwm-outputs FL,FR,RR,RL` names the physical output wired to each thruster (default
  `1,2,3,4`), the simulator's equivalent of the wiring that `thruster_identify` discovers.
- Commands apply in `FixedUpdate` and go neutral after `--crane-command-timeout-ticks`; the
  publisher repeats at 20 Hz, so silence means a lost link.
- The input refuses to start beside `--crane-ros-cmd-vel` or without `--crane-disable-sitl`, so
  two thruster sources never fight. (`--crane-disable-sitl` turns off an optional ArduPilot JSON
  UDP bridge, the legacy-named `MAVROSConnection`, which the RoboBoat path does not use.)

The boat mixer and `OmniXController` agree on every thruster's sign once
`ROSOmniXCommand.ToControllerMotion` is applied; `RoboBoatThrusterPwmTests` pins this.

### RoboBoat sensor contract

`--crane-roboboat-contract` publishes what the boat's flight controller provides through MAVROS,
so mhseals_nav's localization runs unchanged with `odom.launch.py fcu:=false` and no ArduPilot:

| Topic | Type | Content |
| --- | --- | --- |
| `/odom/mavros` | `nav_msgs/Odometry`, 20 Hz | `odom` pose, body-frame (`base_link`) velocity; `--crane-fcu-velocity-sigma` adds noise |
| `/imu/raw` | `sensor_msgs/Imu`, 20 Hz | attitude, body rates and specific force (+g up at rest), `base_link` |
| `/gps/fix` | `sensor_msgs/NavSatFix`, 5 Hz | ENU position about `--crane-gps-origin lat,lon`; `--crane-gps-sigma` adds noise |

Under the contract:

- frames follow REP 103 and the RoboBoat bow correction;
- the scene's own `Imu` and `GPS` components are disabled;
- ground truth stays on `/crane/odom` for scoring but **without** `odom -> base_link` TF, which
  the EKF owns;
- the 3D LiDAR is reconfigured as a VLP-16 (16 rings 2 degrees apart over ±15 degrees, 0.2 degree
  azimuth steps, 10 Hz) in `lidar_link` REP-103 axes (not with `--crane-roboboat-legacy-physics`);
- `--crane-contract-seed` fixes the noise.

The boat's full stack therefore runs as:

```bash
<player> --crane-disable-sitl --crane-ros-thruster-pwm --crane-roboboat-contract
ros2 launch mhseals_nav robot.launch.py sim:=true fcu:=false
ros2 run mhseals_hardware thruster_pwm_node --ros-args -p output_backend:=topic
```

### Other sim-only topics and services

| Name | Purpose |
|---|---|
| `/crane/reset_to_start` (`std_srvs/Trigger`) | Puts the boat back at rest on the course start pose at the next physics tick; added once a course is built. The response carries the resulting `/crane/odom` pose |
| `/crane/sim/profile` (`std_msgs/String`, latched) | The resolved simulation profile as JSON |
| `/crane/truth/course`, `/crane/truth/states`, `/crane/sim/horn` | Course ground truth and task state (opt-in, see [Course.md](Course.md)) |
| `/crane/docking_evaluator` | Docking verdicts with `--crane-roboboat-docking-evaluator` (goal and tolerances via `--crane-dock-*`) |

## Runtime profiles

`--crane-profile` presets which subsystems run. Profiles never change the physics.

| Profile | Rendering and sensors | Use |
|---|---|---|
| `interactive-high` | Full presentation and configured sensors | Normal Nav2/parameter development |
| `interactive-low` | Task sensors unchanged; spectator/window 960×540 by default (`--crane-interactive-width`, `--crane-interactive-height`, minimum 320×180) | Development on weaker hardware |
| `evaluation-high` | Full presentation and configured sensors | Live evaluation runs |
| `train-gpu` | RGB and spectator cameras off; depth, detections, LiDAR and navigation sensors kept; water still rendered | Faster unattended runs (the Nav2 launcher's default) |
| `train-cpu` | All cameras off, geometric depth | Graphics-free scenes only; exits with status 3 on the RoboBoat scene because HDRP water needs graphics |
| `replay-high` | Full presentation | Kept for compatibility; this repository ships no episode player |
| `custom` (default) | Only explicit `--crane-disable-*` flags | Hand-picked combinations |

Individual gates: `--crane-disable-rgb`, `--crane-disable-depth`, `--crane-disable-camera-info`,
`--crane-disable-detections`, `--crane-disable-visual-sensors`,
`--crane-disable-spectator-cameras`, `--crane-disable-lidar-debug-rays`.

Every applied profile logs `CRANE_RUNTIME_PROFILE_RESOLVED`. `--crane-list-profiles` prints the
catalog and exits; `--crane-runtime-report PATH` writes the resolved graphics device, sensor
gates, camera ownership and water-surface count as JSON.

The separate **simulation profile** (`--crane-sim-profile full|balanced|minimal|auto`) scales
rendering and sensor cost to the machine; see
[PerformanceEngineering.md](PerformanceEngineering.md#simulation-profiles-device-tiers).

## Viewer camera

`Sim.Utils.Viewer.ViewerCameraRig` drives the on-screen camera. It follows the spawned robot with
damped position and heading plus a fraction of its roll and pitch, and eases between presets
instead of cutting. A runtime bootstrap attaches it to the enabled screen camera (one with no
target texture); sensor cameras, the water update driver and profiles with spectators off are
left alone, and the rig never creates a camera. It stays off without graphics, in batch mode
unless `--crane-viewer-preset` is given, and with `--crane-disable-viewer-camera`.

Settings live in `Assets/Config/Viewer/Resources/ViewerCamera.asset`: damping time constants,
roll fraction (0.2), transition time, orbit sensitivity, pitch limits, key bindings and presets.
Keys use Input System paths. The default presets are 1 Chase, 2 Side, 3 Front, 4 Corner,
5 Overhead, 6 Map (north-up), 7 Task (frames the task area nearest the robot, from course truth
when present, otherwise the scene's root groups) and 8 Course. V cycles the presets. Right-drag
orbits, the scroll wheel zooms, and reselecting a preset unwinds the orbit. Runtime flags:
`--crane-viewer-preset NAME`, `--crane-viewer-roll F` and `--crane-viewer-target NAME`.

## Courses

`--crane-roboboat-course FILE.json` builds a course by cloning the scene's buoys, docks and
vessels (course frame = boat start, x ahead, y to port), hides the scene's own task groups,
registers every element with the detection sensor and adds banners to dock bays.
`--crane-roboboat-course-truth FILE.json` writes what was placed (in the `/crane/odom` world frame)
for a referee. `Tools/RoboBoat/courses/roboboat_2025.json` lays out the 2025 tasks (handbook 3.2).
The procedural 2026 course family is described in [Course.md](Course.md).

## Build and launch

Build the player (Linux; add `--crane-build-target windows64` for
`Builds/CRANE-Worker-Windows/CRANE.exe`):

```bash
unity build /path/to/mhseals_sim \
  --editor-version 6000.5.10f1 \
  --target StandaloneLinux64 \
  --execute-method CranePerformanceBuild.BuildLinuxWorker \
  --allow-dirty-build --format json --no-tail
```

The default output is `Builds/CRANE-Worker/CRANE.x86_64`; the launchers in `Tools/Performance`
expect it there (override with `CRANE_PLAYER`).

Interactive session for ROS/Nav2 development:

```bash
SDL_VIDEODRIVER=x11 ./Builds/CRANE-Worker/CRANE.x86_64 \
  -screen-fullscreen 0 -screen-width 1280 -screen-height 720 \
  --crane-profile interactive-high --crane-scene "Roboboat Course" \
  --crane-ros-ip 127.0.0.1 --crane-ros-port 10000 \
  --crane-ros-nav-state \
  --crane-ros-cmd-vel /crane/cmd_vel_stamped \
  --crane-action-policy bounded --crane-max-action-lag-ticks 10 \
  --crane-command-timeout-ticks 25
```

`--crane-action-policy latest` accepts the newest valid command; `bounded` additionally rejects
commands that waited more than `--crane-max-action-lag-ticks` in the queue.

### Headless runs

There is no graphics-free mode for the RoboBoat scene: buoyancy, hydrodynamics and LiDAR water
culling query HDRP water, which needs a GPU and a Vulkan device. `-nographics` breaks the water
queries and `--crane-sim-profile headless` is rejected (exit 3). For unattended runs use
`-batchmode` with an X display so Vulkan can start (`CRANE_BATCHMODE=1 DISPLAY=:1` with the
launchers); without any display the NVIDIA Vulkan device fails to start.

### Nav2 launchers

`Tools/Performance/run_nav2_controller_fixture.sh` starts a complete Nav2 `NavigateToPose` loop:
ROS-TCP endpoint, lifecycle manager, NavFn planner, LiDAR-fed global/local costmaps, BT
navigator, behaviors, Regulated Pure Pursuit controller, the Twist-to-TwistStamped fixture node and
the Unity player, with logs and a JSON summary. `CRANE_NAV2_ACTION_MODE=follow-path` runs the
narrower controller-only action. `Tools/Performance/run_roboboat_command_response.sh` runs the
surge/sway/yaw response fixture (`CRANE_RESPONSE_INPUT=pwm` drives it through the PWM input),
checked by `check_roboboat_axis_response.py`.

Prerequisites, which the scripts do not install:

- Docker, and a ROS 2 Jazzy image with Nav2. Set it with `CRANE_ROS_IMAGE` (default
  `lunarzdev/astro:cuda`).
- A built `astro_dock` colcon workspace whose `install/` contains `ros_tcp_endpoint`. Point to it
  with `CRANE_ASTRO_DOCK` (default `../astro_dock`, next to this repository). The workspace is
  mounted read-only into the containers.
- A built player at `Builds/CRANE-Worker/CRANE.x86_64` (or `CRANE_PLAYER`).

Useful variables: `CRANE_RESULT_ROOT` (output directory), `CRANE_ROS_PORT`,
`CRANE_ROS_DOMAIN_ID`, `CRANE_NAV2_PROFILE` (default `train-gpu`), `CRANE_NAV2_GOAL_X/Y/YAW`,
`CRANE_NAV2_PATH_FILE`, `CRANE_DOCKING_EVALUATOR=1`, and `CRANE_NAV2_UNITY_EXTRA_ARGS`. Adding
`CRANE_NAV2_UNITY_EXTRA_ARGS='--crane-reset-probe'` exercises a scene reload mid-run and checks
that Nav2 recovers after the `/clock` rewind (a TF-buffer rewind warning is expected).

The launcher uses Unity ground-truth `odom` as the global frame. It does not test localization,
SLAM, static-map navigation or lockstep control.

When ROS nodes are split across Docker containers using Fast DDS, give every container the same
IPC namespace (`--ipc host`, as the launchers do); otherwise discovery can show topics while
shared-memory payloads silently fail. Each player must own one ROS graph/domain and one `/clock`.
If the stack cannot keep up, lower `--crane-time-scale` or use the bounded action policy; there is
no Nav2 lockstep barrier.

On scene reload, the scene-owned `ROSConnection` cancels and joins its connection task before it
is destroyed, and the endpoint must remove that socket's ROS nodes on disconnect. The embedded
ROS-TCP Connector under `Packages/` carries patches for registration, serializer isolation and
teardown; do not replace it with an unpinned upstream version without rerunning the live Nav2 and
scene-reload fixtures.

## Authoring rules

1. Treat scenes, prefabs, masses, inertias, colliders, sensor rates and water settings as part of
   the physical configuration.
2. Add forces/torques in `FixedUpdate`; do not move a live vehicle by assigning transforms.
3. Do not stack buoyancy or drag implementations on one hull unless the combination is
   intentional and validated.
4. Keep RGB, depth, camera info, detections and spectator rendering independently configurable.
5. Carry episode and acquisition identity through asynchronous work and drop prior-episode
   callbacks.
6. Use scene reload as the reset baseline.
7. Compare changes at equal simulated timestamps with the same seed, timestep, scene, sensors,
   water and ROS configuration.
8. Do not call `-nographics` runs of the RoboBoat scene "headless support", and do not disable
   water to make them appear to work.
9. Keep oracle scene identity separate from what the robot observes: the detection sensor must
   apply visibility, range and occlusion rather than publishing every registered object.
