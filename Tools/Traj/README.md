# .ctraj trajectory files

`CraneTrajRecorder` (Assets/Scripts/Performance) records runs as `crane-traj/1` files. The
`golden/` pair is a reference file (`small.ctraj`) and its decoded values (`small.json`), made by
the upstream CRANE Python codec. `CraneTrajTests` reads it so the C# codec stays compatible.
