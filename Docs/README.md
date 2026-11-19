# mhseals_sim documentation

Start with the [project README](../README.md) for installation, then:

| Document | Read it when you want to |
|---|---|
| [SimulationPhysicsAndRuntimeModes.md](SimulationPhysicsAndRuntimeModes.md) | Drive the sim from ROS 2 / Nav2: units and frames, boat physics and profiles, sensors, ROS topics and command inputs, the RoboBoat sensor contract, runtime flags, building the player, headless runs and the Nav2 launchers |
| [RoboBoatNavigationBaseline.md](RoboBoatNavigationBaseline.md) | Understand or tune the Nav2 configuration: active planner/controller/costmap parameters, the command contract at the Unity boundary, the thruster mixer, frames, measured results and known gaps |
| [Course.md](Course.md) | Generate RoboBoat 2026 courses, read course ground truth, and add a task |
| [PerformanceEngineering.md](PerformanceEngineering.md) | Pick a device tier (`--crane-sim-profile`), benchmark the player, run several players at once, or check what has been measured |
| [ArchitectureAndDesign.md](ArchitectureAndDesign.md) | Change the simulator itself: subsystem layout, timing and water pipeline, command gating, reset, design rules and known limitations |

Command-line flags and many classes keep the engine's historical `--crane-`/`Crane` prefix; use
them exactly as written.
