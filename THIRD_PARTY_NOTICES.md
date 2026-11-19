# Third-party notices

mhseals_sim is licensed under GPL-3.0 (see `LICENSE`). It bundles the following third-party
components under their own licenses:

| Component | Location | License |
|---|---|---|
| Unity ROS-TCP-Connector (vendored, with local thread-safety patches described in `CRANE_PATCH.md`) | `Packages/com.unity.robotics.ros-tcp-connector/` | Apache-2.0, see the package `LICENSE` |
| Liberation Sans font (TextMesh Pro default) | `Assets/TextMesh Pro/Fonts/` | SIL Open Font License 1.1, see `LiberationSans - OFL.txt` |

Packages that Unity fetches at import time (HDRP, Input System, Cinemachine, the URDF Importer,
and others listed in `Packages/manifest.json`) are not redistributed here; their licenses apply
as published by their authors.
