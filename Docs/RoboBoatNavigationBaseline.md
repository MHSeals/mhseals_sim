# RoboBoat navigation baseline

This is the code-checked Nav2 baseline for the RoboBoat in mhseals_sim: the launch path, active
Nav2 parameters, the command contract at the Unity boundary, the thruster mixer, geometry and
frames, measured results, and known gaps.

## Configuration

- ROS image: set by `CRANE_ROS_IMAGE` (default `lunarzdev/astro:cuda`), ROS 2 Jazzy with Nav2
  `1.3.12` Debian packages. The launcher also needs a built `astro_dock` workspace containing
  `ros_tcp_endpoint` (`CRANE_ASTRO_DOCK`, default `../astro_dock`); see
  [Nav2 launchers](SimulationPhysicsAndRuntimeModes.md#nav2-launchers).
- Active parameters: [nav2_controller_fixture.yaml](../Tools/Performance/nav2_controller_fixture.yaml),
  loaded explicitly by [run_nav2_controller_fixture.sh](../Tools/Performance/run_nav2_controller_fixture.sh).
- Active behavior tree:
  [nav2_roboboat_distance_replanning.xml](../Tools/Performance/nav2_roboboat_distance_replanning.xml),
  selected by the parameter file (no command-line BT override).
- No velocity smoother is launched.

## Launch architecture

```text
NavigateToPose (/navigate_to_pose)
  -> BT Navigator, nav2_roboboat_distance_replanning.xml
  -> NavfnPlanner /compute_path_to_pose (A*, rolling odom costmap)
  -> RegulatedPurePursuitController /follow_path at 10 Hz
  -> Twist on /nav2/cmd_vel
  -> nav2_follow_path_fixture.py stamps/forwards it as TwistStamped
     on /crane/cmd_vel_stamped
  -> ROS TCP endpoint -> Unity ROSSubscriber
  -> ROSOmniXCommand (desired body velocity -> normalized PI/feed-forward effort)
  -> OmniXController (four-thruster X mixer and common saturation)
  -> boat plant (thrusters, buoyancy, hydrodynamics, water current/waves)
  -> CraneROSNavigationState at 50 Hz
  -> /crane/odom and /tf (odom -> base_link plus sensor children)
  -> Nav2 controller/costmaps/BT navigator
```

The boat's own stack (mhseals_nav localization and Nav2, mhseals_hardware thruster allocation)
uses a second path with no ArduPilot or MAVROS:

```text
Nav2 / test suite -> /cmd_vel -> [calibrated_velocity_controller]
  -> thruster_pwm_node (boat mixer + channel_map, output_backend topic)
  -> /thrusters/pwm (UInt16MultiArray, physical outputs 1-4, us)
  -> ROSThrusterPwmCommand (EscPwm, --crane-pwm-outputs wiring) -> thrusters
mhseals_sim --crane-roboboat-contract -> /odom/mavros, /imu/raw, /gps/fix -> mhseals_nav EKFs
mhseals_sim ground truth -> /crane/odom (no TF) -> scoring only
```

The boat mixer and `OmniXController` agree on every thruster's sign once
`ROSOmniXCommand.ToControllerMotion` is applied, so positive boat effort on a thruster is positive
simulator command; `RoboBoatThrusterPwmTests` pins this.

`run_nav2_controller_fixture.sh` launches four Nav2 servers directly, remaps controller and
behavior output to `/nav2/cmd_vel`, and launches the lifecycle manager. The fixture node is the
only Twist-to-TwistStamped bridge in this path. ROS callbacks enqueue commands; Unity applies the
latest accepted command only on the 50 Hz physics boundary. Commands become stale after 25 ticks
(0.5 s), at which point effort is zeroed and integrators reset.

## Active Nav2 stack

- Planner: `nav2_navfn_planner::NavfnPlanner`, A* enabled, unknown allowed, 0.5 m tolerance,
  expected 5 Hz.
- Controller: `nav2_regulated_pure_pursuit_controller::RegulatedPurePursuitController`, 10 Hz,
  forward-only (`allow_reversing=false`), fixed 2.0 m lookahead, collision detection enabled,
  0.8 m/s desired surge, 0.02 m/s minimum approach speed, 2.0 m approach-scaling distance, and
  0.2 rad/s rotate-to-heading speed with terminal rotation enabled. It emits surge and yaw, never
  `linear.y`, and follows the geometric path tangent.
- Goal checker: stateful `StoppedGoalChecker`; 0.20 m XY, 0.35 rad yaw, 0.05 m/s stopped
  translation, and 0.05 rad/s stopped rotation.
- Progress checker: `SimpleProgressChecker`; 0.05 m in 20 s.
- Recovery behaviors: Spin, BackUp, DriveOnHeading, Wait at 10 Hz; 0.5 rad/s maximum recovery
  rotation, 0.5 rad/s² rotational acceleration. The BT replans after each 1 m of translation. This
  refreshes a wave-disturbed long approach but preserves the final sub-metre path; unconditional
  1 Hz replanning was measured replacing it with a quantized two-pose Navfn path and causing
  terminal orbits.
- Local costmap: rolling `odom`, `base_link`, 20 × 20 m, 0.10 m cells, 10 Hz update/2 Hz publish.
- Global costmap: rolling `odom`, `base_link`, 60 × 60 m, 0.20 m cells, 5 Hz update/1 Hz publish.
- Both costmaps use a 0.80 m robot radius, 3-D VoxelLayer from `/points`, obstacle range 1-20 m,
  raytrace range 1-25 m, heights -1.5 to 3.0 m, plus InflationLayer radius 1.0 m and factor 3.0.
- All nodes use simulation time. Odometry is `/crane/odom`; the final plant command is
  `/crane/cmd_vel_stamped`. There is no map server, AMCL, static map or velocity smoother in this
  launch path.
- Other installed controllers, not active: DWB, MPPI, Graceful Controller and Rotation Shim.

Compared with the first baseline, four controller values changed: desired speed
`0.15 -> 0.8 m/s`, fixed lookahead `0.8 -> 2.0 m`, terminal rotation `false -> true`, and rotate
speed `0.4 -> 0.2 rad/s`.

RPP assumes a nonholonomic plant that can promptly realize requested surge/yaw and rotate in
place. The vessel is actually omnidirectional and inertial. The first mismatch is harmless while
forward-only motion is wanted; the second is mitigated by the 2 m approach slowdown and the
body-velocity loop. Wave drift remains an external disturbance, not commanded sway.

## Boat command contract

At the Unity boundary, `TwistStamped` is a **desired body velocity**, not normalized thrust:

- `linear.x`: ROS FLU forward/surge, m/s; imported physics-body local `-X`, toward the LiDAR and
  catamaran noses and away from the chase camera/Blastoise head.
- `linear.y`: ROS FLU left/sway, m/s; imported physics-body local `-Z`.
- `angular.z`: ROS FLU counter-clockwise yaw rate, rad/s; Unity local `-Y` axial rotation.

The logical ROS body frame is a -90 degree Unity-Y rotation from the imported physics body. The
same transform is applied to commands, odometry pose/twist, root TF, sensor-child TF and docking
evaluation. `ROSOmniXCommand` clamps translation and yaw to ±1.0 in their SI units and measures
body-frame velocity each fixed step. Translation uses normalized feed-forward `0.21`, Kp `0.1`,
Ki `0.1` and integral effort limit `0.2`; yaw uses square-root feed-forward `0.24` and Kp `0.05`
(all overridable, see
[Velocity input](SimulationPhysicsAndRuntimeModes.md#velocity-input-twiststamped)). Each axis
effort is clipped to [-1, 1]. Manual input calls `OmniXController.SetMotion` directly.

A yaw sweep confirmed the contract: 0.025/0.05/0.1/0.2/0.4 rad/s requests produced
0.028/0.055/0.106/0.211/0.415 rad/s tail response. A directly-ahead 8 m goal produced exactly zero
lateral command; its small measured sway is consistent with the enabled waves.

## Thruster mixer

There are four fixed, diagonal thrusters around the centre of mass, about 0.33 m off the
centreline (each hull sits `0.3302 m` to its side of `base_link`, per `left_hull_joint` and
`right_hull_joint` in `blastoise.urdf`). Their serialized rotations are the four complementary
45-degree diagonals. The LiDAR/catamaran noses define the bow; the Blastoise head is aft.

For requested normalized effort `(f, s, r)`, `OmniXController` computes:

```text
[FL]   [-1 -1 -1] [f]
[FR] = [ 1 -1  1] [s]
[RL]   [-1  1  1] [r]
[RR]   [ 1  1 -1]
```

All four values are divided by `max(1, max(abs(value)))`, preserving the requested direction while
saturating. The matrix has rank 3, symmetric pure-surge/pure-sway/pure-yaw columns and no
algebraic coupling. `ROSOmniXCommand.ToControllerMotion` supplies the sign conversion for ROS
FLU. Axis-response tests verified surge, sway and yaw signs independently.

The resulting thruster commands drive the boat plant's ESC-to-thrust model (see
[The boat plant](SimulationPhysicsAndRuntimeModes.md#the-boat-plant-default)). Only with
`--crane-roboboat-legacy-physics` does `Thruster.FixedUpdate` apply its own shaft-velocity model
from `OmniThrusterConfig.asset` (±500 rad/s, quadratic coefficient -0.014, 0.03 m full-submersion
depth, no deadband).

## Physical model

By default the scene's boat (`Blastoise.prefab`) runs the profile-driven plant: 30 kg, added mass,
relative-water surge/sway/yaw damping sized for a 2.5 m/s top speed, and four 51.5 N thrusters
(the `ideal` priors). Physics runs at 0.02 s. `Submersion` clips a simplified hull mesh against the
HDRP WaterSurface (3 m patch, resolution 20) and `Buoyancy` applies displaced-water force at the
centre of buoyancy. All plant numbers are priors until a characterization passes the gate.

With `--crane-roboboat-legacy-physics`, the scene's authored values apply instead: `base_link`
3 kg with linear damping 4, angular damping 15, COM Y -0.23 m and inertia `(10,15,10)`; each hull
link 8 kg; `GeneralDynamics` face drag (linear 100, quadratic 30, reference speed 1 m/s), `Current`
and `FossenDynamics` enabled by a scene override. Those legacy components have known defects
(added-mass sign, Coriolis DOF routing, bow axis, a double normal transform and a "quadratic" drag
that is effectively constant), so do not tune Nav2 against them.

The measurements in this document were taken with the authored scene physics, before the profile
plant became the default. Re-run them before quoting them for the current plant.

Under that legacy physics, an earlier full-effort test on controller axis X reached 1.246 m/s peak
and 1.216 m/s tail, traveled 17.47 m, then coasted 0.655 m after release. That axis is
imported-body `+Z`, not the visible bow, so it shows plant response but is not a valid
forward top-speed test.

## Geometry and frames

- `odom` is the global/planning frame and `base_link` is the odometry child and rotation reference.
  Imported physics-body `(-X, -Z, Y)` maps to logical ROS `(X, Y, Z)`; angular vectors receive the
  required handedness sign.
- `CraneROSNavigationState` publishes odometry and TF at 50 Hz, including `lidar_link`,
  `front_camera_link`, `imu_link` and `gps_link` when present.
- The 3-D LiDAR is on `lidar_link` at the bow, 10 Hz, 360-degree horizontal field of view, 16
  vertical beams, publishing `points` (resolved as `/points`).
- The hull envelope used by the docking evaluator is 1.063 m long by 0.895 m beam. The costmap's
  0.80 m circular radius exceeds the hull's circumscribed radius (~0.695 m), so it is conservative.
- The evaluated berth is 3.0 m deep by 2.0 m wide. An aligned hull has roughly 0.55 m lateral
  clearance per side, while the 1.6 m costmap diameter leaves 0.20 m per side. The far-dock run
  shows the circle still permits entry, but it may reject tighter valid maneuvers.

## Tools and results

`Tools/Performance` contains FollowPath/NavigateToPose fixtures, generated straight/gentle/S paths
(`nav2_path_spec.py`), a known far-dock path (`roboboat_far_dock_known_path.json`),
command/yaw/thruster response fixtures, a docking evaluator, path metrics and plots
(`plot_nav2_fixture.py`) and a costmap-clearance audit (`audit_nav2_costmap_clearance.py`). They
measure action status, RMS/max cross-track and heading error, body velocity, final pose,
stopping/coast, contact, dock-region containment, recovery events and transport validity.

Results (legacy scene physics, `linear.y` command always zero):

| Run | Result | Fixture time | Key numbers |
|---|---:|---:|---|
| ROS surge step, 1.0 m/s for 15 s | complete | 15 s | +15.363 m bow direction, +0.582 m wave drift; 0.9996 m/s tail surge, 0.0023 m/s tail sway |
| 8 m fixed FollowPath | success | 26.43 s | +7.837 m bow direction, -0.317 m wave drift, 0.025 rad final yaw |
| 8 m NavigateToPose, distance BT | success | 16.95 s | +7.854 m bow direction, zero sway command, 0.032 rad final yaw |
| Far dock `(0.864, -27.587, +pi/2)`, distance BT | Nav2 success | 46.03 s action / 53.08 s observed | 23.37 m traveled; 0.267 m XY and 0.019 rad yaw; hull inside dock, zero contact |

The original direct-ahead baseline took 65.83 s at 0.15 m/s. A naive 0.30 m/s change with terminal
rotation disabled reached within 0.005 m, then looped nearly 180 degrees and timed out at 70 s;
enabling terminal rotation made the same case succeed in 38.18 s. A later audit found an exact
90 degree boundary error: ROS surge had been bound to imported-body `+Z` while the camera/LiDAR
geometry shows the visible bow is imported-body `-X`. A scene-loaded regression test failed
before the correction (bow/surge dot product `9.31e-8`) and passes after it.

## Known gaps

Resolved: the 90 degree ROS/imported-body frame error, unconditional 1 Hz terminal replanning, the
terminal-heading configuration, and too-short speed/lookahead settings. Goal checking and the
conservative footprint were not the cause of the earlier sideways motion. Remaining:

1. **Plant speed and scale.** Full-effort bow-axis speed has not been measured against real mass,
   hull dimensions, full-throttle speed, current draw/RPM and bollard thrust.
2. **Disturbance robustness.** The distance-triggered BT passed the direct-ahead and far-dock runs,
   but wave severity, current and multiple seeds have not been swept.
3. **Footprint shape.** The 0.8 m circle is safe but conservative for a catamaran. A polygon could
   help tight clearances; change it only if a clearance audit fails.
4. **High-speed turns.** 0.8 m/s is validated on a gentle turn and the far planner path, not every
   obstacle geometry. Do not raise the 1.0 m/s adapter ceiling until stopping-distance and
   curved-path sweeps stay collision-free.
5. **Station keeping.** After the far action succeeded, seven seconds with no command let waves
   drift the boat 0.219 m. It stayed inside the dock with zero contact but crossed the evaluator's
   0.4 m pose tolerance before the five-second settle latch. Decide whether docking needs an active
   hold after Nav2 success before adding one; do not loosen tolerances or hydrodynamics to hide it.

## Nav2 overlay

`Assets/Scripts/Utils/Visualization/Nav2EvidenceOverlay.cs` (enabled with
`--crane-evidence-overlay`) is a read-only overlay. It draws the received Nav2 path as a cyan
line, accumulated odometry as a yellow line, and occupancy-grid cells as low-opacity 3-D tiles
whose height and color encode occupancy; unknown cells are hidden by default. It also draws the
latest `TwistStamped` command as a magenta arrow from the odometry pose. The arrow is the published
desired body velocity, scaled for visibility, not measured motion or thrust. The overlay only
subscribes to topics and does not change the controller or physics.

For a useful screenshot set, capture an oblique view with water and dock visible under the
costmap, a top-down view of plan versus odometry, and a close-up of any replan or obstacle region.
Check the ROS frame transform against a known pose first.
