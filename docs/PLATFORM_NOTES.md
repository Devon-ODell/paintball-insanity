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
