# Platform checks — 2026-09-06

## Local demo follow-up

Roblox Studio was downloaded from Roblox's CDN and installed through its official installer. `demo.project.json` builds successfully without external packages; the demo explicitly uses temporary progress and checks `RunService:IsStudio()` before allowing play. The production project's missing dependencies are unchanged.

Verified the current [Player API](https://create.roblox.com/docs/reference/engine/classes/Player) for `LoadCharacterAsync`, the [GuiButton API](https://create.roblox.com/docs/reference/engine/classes/GuiButton) for the summary button's Modal property, and [testing modes](https://create.roblox.com/docs/studio/testing-modes): Test/F5 creates a player; Run/F8 does not. The demo launcher targets Test mode instructions.

## Initial review

Checked Roblox's [RemoteEvent reference](https://create.roblox.com/docs/reference/engine/classes/RemoteEvent/OnServerEvent) and [remote communication guide](https://create.roblox.com/docs/scripting/events/remote): `FireServer(...)` invokes `OnServerEvent(player, ...)`, with the sending Player supplied by the engine. The reload binding checks that Player against the active match owner. Reload requests carry no client-authoritative ammo or duration.

Local tools are in `~/.local/bin`, which is absent from this session's PATH. Lune and Rojo run when invoked by absolute path. Wally does not: the installed executable returns `bad CPU type in executable`. No dependencies were installed or system configuration changed during this review.

The default Rojo build currently fails because `Packages` is missing. `ServerPackages` is also absent. Do not replace those paths with empty folders and interpret a successful build as working persistence: `Profile.init()` falls back to volatile memory when ProfileStore is absent.

This review did not verify the installed ProfileStore API because the package is not installed. The older comments claiming prior verification are not evidence of a successful dependency install or persistence test.

## 2026-09-07 — free commerce, persistence and UI

Verified [MarketplaceService](https://create.roblox.com/docs/reference/engine/classes/MarketplaceService)
`ProcessReceipt`, `PromptProductPurchase`, `PromptGamePassPurchase`,
`UserOwnsGamePassAsync` and `GetProductInfoAsync`. The older `GetProductInfo` is
deprecated. Native confirmation presents the actual price; custom regional price
labels must use a client request, per [regional pricing](https://create.roblox.com/docs/production/monetization/regional-pricing).

Verified [PolicyService.GetPolicyInfoForPlayerAsync](https://create.roblox.com/docs/reference/engine/classes/PolicyService).
Calls are protected and cached; future paid prompts fail closed on lookup
failure. The current catalogue is deterministic cosmetics only. Ads, random
purchases, subscriptions, commerce goods and trading remain disabled; their
eligibility handling is not claimed as complete.

Verified [ProfileStore](https://madstudioroblox.github.io/ProfileStore/api/)
`New`, `Mock`, `StartSessionAsync`, `Reconcile`, `IsActive`, `EndSession`,
`OnSessionEnd`, `Save` and `LastSavedData`. Purchase confirmation follows its
[receipt guidance](https://madstudioroblox.github.io/ProfileStore/devproducts/):
store inventory and PurchaseId together; confirm the saved snapshot before
acknowledging. Bundled source/license provenance and limitations are recorded in
[MONETIZATION.md](MONETIZATION.md).

Roblox Studio **is installed** at `/Applications/RobloxStudio.app`; the old
handoff's absence claim is stale. This session's checks were headless and did not
exercise live purchases or rendered gameplay.

UI review also verified [scrolling frames](https://create.roblox.com/docs/ui/scrolling-frames),
[size modifiers](https://create.roblox.com/docs/ui/size-modifiers),
[ScreenGui](https://create.roblox.com/docs/reference/engine/classes/ScreenGui), and
[GuiObject](https://create.roblox.com/docs/reference/engine/classes/GuiObject).
The shop/dialogue use safe insets, size constraints and automatic scrolling;
HUD crosshair coordinates remain centered in the full camera viewport. Lune
construction checks cover actual Roblox properties and mocked button/input
routing, not rendered clipping or controller ergonomics.

---

## World pass 01 — barn roof, foliage padding, viewmodel, shop interior

Checked while working `HANDOFF_worldpass_01.md`.

**Two claims in that brief are stale.** `docs/` and `tools/` both exist and are
populated; `tools/ship-check.luau` runs and does enforce the pay-to-win audit and
the dev-flag gate. Nothing needed creating.

**The two shop structures are genuinely different buildings**, and only one had
the roof bug:

- `World/PoleBarn.luau` → model `PoleBarn`, built once in the hub from
  `overworld.json → barn`. Gable roof on rafters. **This is the one that was
  inverted.**
- `Match/FieldDetails.luau` → model `FieldSupply`, built per map from
  `venue.json → props`. Flat slab roof at y 4.35 with a fascia band at y 3.7
  tucked just under its front edge. Checked the numbers: it is correct, and a
  flat slab cannot be upside down. Left alone.

**Roof orientation, derived rather than observed.** No Studio in this loop, so
the inversion was confirmed by working the rotation out and then locked down with
specs against a new pure `PoleBarn.roofline`/`roofHeightAt`:

> `CFrame.Angles(θ, 0, 0)` sends local `+Z` to `(0, -sin θ, cos θ)`. Each sheet
> is centred on its own half-span with its `+Z` end at the eave, so that end must
> fall by `rise` — which needs `+pitch`, not `-pitch`. With the negation, for
> `side = -1` the rotation was `+pitch` and the sheet's `+Z` end (pointing back
> toward the ridge at `z = 0`) *rose*, and the mirrored sheet did the same. Both
> slopes fell inward: a valley. `RidgeCap` and `RidgeBeam` were still placed at
> `wallH + rise`, so they floated over the trough — the stray beam in the
> screenshots.

**`Enum.PartType` size semantics: NOT verified from documentation.** Neither the
[PartType enum page](https://create.roblox.com/docs/reference/engine/enums/PartType)
nor the [Part class page](https://create.roblox.com/docs/reference/engine/classes/Part)
documents how `Size` maps to a rendered `Ball` or `Cylinder`. What this pass
relies on is that **a Cylinder's length axis is its local X**, with the other two
components forming the circular cross-section. That is corroborated by two
working call sites already in this repo rather than by a doc page:

- `ViewMarker`'s barrel: `Size = (barrelLength, dia, dia)` with
  `CFrame.Angles(0, π/2, 0)` to lie along Z.
- `Foliage`'s trunks and canopy tiers: `Size = (height, dia, dia)` with
  `CFrame.Angles(0, 0, π/2)` to stand along Y.

Both predate this pass and both render correctly, so the convention holds. New
cylinders (air tank, hopper, pump rods, shop stock) follow the same one. Confirm
in Studio if it ever looks wrong — this is the least-verified thing in the pass.

The related `Ball` claim from the brief — that a sphere renders off the smallest
`Size` axis — is likewise undocumented and **unconfirmed**. It did not need to be:
a hopper and an air tank should not be spheres under any interpretation, so the
fix (cylinders with explicit rotations) is right either way.

**Not verified, and needs Studio.** Nothing in this pass has been rendered. The
roof, gable infill, sign brackets, viewmodel framing and all shop stock are
arithmetic-checked and spec-covered only. Screenshots remain owed.

## 2026-09-07 — release preparation verification

- [ProfileStore API](https://madstudioroblox.github.io/ProfileStore/api/) documents
  DataStoreState and the non-persistent Mock backend. The release adapter now
  requires Access for live sessions. [Installation tutorial](https://madstudioroblox.github.io/ProfileStore/tutorial/)
  supports placing the source ModuleScript in ServerScriptService; the already
  vendored dependency removes the need to install Rosetta/Wally for this build.
- [Gamepad inputs](https://create.roblox.com/docs/input/gamepad) documents B as
  cancel, triggers for primary actions and bumpers for secondary actions. R1
  slide and D-pad lean are this game's choices; Roblox does not specify a
  universal lean binding. Controller Emulator verification remains pending.
- [UI containers](https://create.roblox.com/docs/ui/on-screen-containers) recommends
  CoreUISafeInsets for interactive UI. HUD readouts use it; aiming graphics have
  a separate screen-centered layer.
- [GuiObject](https://create.roblox.com/docs/reference/engine/classes/GuiObject)
  and [GuiService](https://create.roblox.com/docs/reference/engine/classes/GuiService)
  provide Selectable, SelectionOrder, NextSelection links and SelectedObject.
  Menus explicitly establish and dispose their focus; Back uses a high-priority
  context action. Actual engine/controller layout behavior is not verified here.

## Studio bridge discovery — 2026-09-07

Verified Roblox's [Studio MCP guidance](https://create.roblox.com/docs/studio/mcp):
the ARM-native proxy is installed at
`/Applications/RobloxStudio.app/Contents/MacOS/StudioMCP`. A read-only protocol
probe initialized successfully after allowing the local socket, but tools/list
timed out because no enabled Studio connection supplied tools. The user chose
to continue without Studio for now. No Studio-authored source, playtest,
publishing or account changes were made through this probe.

### Combat motion and inflatable pass (2026-09-08)

Verified current Creator Hub references for [CFrame interpolation](https://create.roblox.com/docs/reference/engine/datatypes/CFrame), [Humanoid.CameraOffset](https://create.roblox.com/docs/reference/engine/classes/Humanoid), and [Part.Shape](https://create.roblox.com/docs/reference/engine/classes/Part/Shape). First-person motion uses local non-queryable parts and CFrame interpolation; the camera drop uses CameraOffset. The documented PartType.Wedge provides the tapered speedball panels. No uploaded animation IDs or external assets are required. Reload presentation reads MarkerState's existing deadline and duration; it cannot grant ammo. Authored speedball OBBs remain unchanged, including the existing invisible upper corners around tapered cover.

### Vehicle and yard props (2026-09-08)

Verified [Part.Shape](https://create.roblox.com/docs/reference/engine/classes/Part/Shape) (Block, Cylinder and Wedge) and [CFrame.fromMatrix](https://create.roblox.com/docs/reference/engine/datatypes/CFrame) against Creator Hub. Vehicle panels and wheel arches are authored primitives; a basis built from each beam's endpoints orients sloped glazing and cabin pillars. All vehicle visuals have collision, query and touch disabled. The callers retain the existing authoritative car and pickup collision volumes. No uploaded meshes, external textures or Studio-authored assets are needed.

### Look pass: sky, materials and per-instance colour (2026-09-08)

Verified against the engine's own class database through the headless harness
rather than from memory, because two of these are easy to get wrong:

- **[Clouds](https://create.roblox.com/docs/reference/engine/classes/Clouds)**
  (`Cover`, `Density`, `Color`, `Enabled`). Clouds must be parented to
  **Terrain**, not Lighting; a `Clouds` under Lighting silently renders nothing.
  `Match/Atmosphere` parents them to `Workspace.Terrain` under a pcall, since
  the headless harness has no Terrain and a sky is never a requirement.
  `Atmosphere.clear` reaches into Terrain to remove them -- the rest of the
  managed instances live under Lighting and the old loop could not see them.
- **[MaterialService.Use2022Materials](https://create.roblox.com/docs/reference/engine/classes/MaterialService)**,
  set once, pcall-guarded. Every surface in this game is a built-in material, so
  opting into the current generation is the cheapest upgrade available: no
  asset, no part, no tuning.
- **Materials confirmed present**: Pebble, LeafyGrass, Ground, Mud, Rock,
  Asphalt, Cobblestone, Limestone, Sandstone, Salt, Basalt, Pavement, Foil,
  alongside the legacy set. Gravel is Pebble and a creek bed is Rock; neither is
  Concrete. The field floor and forest floor are LeafyGrass, which has real
  relief where Grass is flat.

**No `Sky` instance is created, deliberately.** With no Sky, Lighting renders a
procedural sky driven by the Atmosphere settings. Adding a bare `Sky` replaces
that with the default skybox textures, which is a downgrade -- and a custom
skybox needs uploaded assets, which this project does not use.

Per-instance colour variation (`Shared/Tint`) is a positional hash, not a random
draw, so it needed no new engine API and moved nothing: the hub's foliage report
is identical part-for-part before and after.

## 2026-09-09 — five-fix follow-up

Checked [RunService render priorities](https://create.roblox.com/docs/reference/engine/classes/RunService): default camera updates at priority 200; BindToRenderStep uses a numeric priority and `.Value` on RenderPriority. Input offsets bind at Camera.Value−1 and camera-dependent presentation at Camera.Value+1.

Checked [Trail.Clear](https://create.roblox.com/docs/reference/engine/classes/Trail) for explicit history clearing during reuse, and [ContextActionService](https://create.roblox.com/docs/reference/engine/classes/ContextActionService) for action-state handling. Input now treats End/Cancel as release. The headless checks stub engine events and Trail.Clear; they validate lifecycle calls, not rendered trail pixels.

Current build status and handoffs live in [CHANGE_REPORT.md](CHANGE_REPORT.md). Earlier platform notes describe the dependencies available on their original dates; they are not current release status.
