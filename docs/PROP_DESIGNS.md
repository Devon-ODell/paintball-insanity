# Vehicle and yard props

The Urban course's four car boxes now carry detailed sedan assemblies. The two Landing trucks use a pickup assembly with an open cargo bed. Both have sloped glazing, separate pillars, bevelled hood shoulders, segmented wheel arches, tires and spoke rims, lights, grilles, bumpers, mirrors, door handles and trim. Broad surfaces and opaque tinted windows keep the designs readable in play.

The Landing's picnic tables, air racks and pallet stacks now have individual boards, braces, open rack frames, tank valves, retention bands, a gauge and cargo straps.

- `Data/vehicleProps.json`: vehicle dimensions, authored panels, wheel geometry, palette and part budget.
- `Data/yardProps.json`: authored furniture and equipment parts.
- `World/VehicleProps.luau` and `World/YardProps.luau`: reusable builders.
- `Data/maps/urban.json`: `prop: "sedan"` decorates the existing course cover boxes.

Vehicle visuals never collide or enter raycasts. Urban retains its authored car boxes; pickups retain the hub's original bed and cab colliders. This means paint is still blocked by the rectangular course volume, including the visible gaps underneath cars. The vehicles are static props, not drivable.

The sedan has 120 visual parts; the pickup has 125. Major panels and tires cast shadows; small hardware does not. Windows are opaque, so the pass adds no transparent surface area.

## Geometry preview

![Sedan on the left, pickup on the right](previews/vehicle-props.png)

This is an orthographic software rendering of the actual generated parts, in a neutral paint colour. It checks geometry and proportions; it is not a Studio screenshot and does not reproduce Roblox lighting or materials. In game the vehicles retain their placement-specific paint colours.

Reproduce the preview:

```sh
lune run tools/check-props /tmp/paintball-vehicles.json
python3 tools/render-props.py /tmp/paintball-vehicles.json docs/previews/vehicle-props.png
```

Other verification: `tools/check-source`, `tools/check-budget`, `tools/check-demo-world`, the full `tools/run-tests` suite, and `rojo build default.project.json`. A Studio walkthrough remains necessary to assess the final in-game lighting and the visual match to the rest of the venue.
