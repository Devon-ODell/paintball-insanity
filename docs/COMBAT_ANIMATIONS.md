# Combat animation pass

First-person procedural motion; no animation upload or Studio authoring required.

- **R / gamepad X:** reload after firing. Gloved hands and sleeves lift the marker, open the hopper, bring in a pod, tip it over the hopper, withdraw it and close the lid. The timeline scales to the equipped marker's reload duration.
- **Shift / L3 while moving:** tuck and cant the marker with a distance-driven stride cycle. Standing still does not bob.
- **C / R1 during a grounded sprint:** slide marker pose and eased camera drop. The existing duration, speed and cooldown apply. This does not change the player's hitbox or add clearance under obstacles.

`Data/combatAnimations.json` controls poses, reload keyframes, motion smoothing and the slide eye drop. Reload keyframe translations for the marker are studs; pod/hand locations and dimensions are metres. Rotations are XYZ degrees. These are local first-person animations, not replicated third-person avatar tracks.

Speedball visual tuning is in `Data/inflatables.json`: tapered wedge doritos, soft pillow bricks/standups, domed cans and glossy PVC. Layout, bot navigation and shot-blocking boxes remain unchanged. The rectangular collision boxes still fill the visually empty corners around tapered/round bunkers.

Verification: `lune run tools/check-client-ui`, `lune run tools/check-inflatables`, `lune run tools/check-source`, `lune run tools/run-tests`, and `rojo build default.project.json`. The headless visual checks inspect transforms, hardware reset, slide gating, part properties and budgets. Studio playtesting is still needed to assess framing, hand placement and motion comfort at different aspect ratios.
