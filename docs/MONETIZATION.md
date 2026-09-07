# Free launch and monetization framework

Everything obtainable from Field Supply currently costs **0 FF**. Both optional
cosmetic collections are **free claims**. There are no Robux/local-currency
prompts, subscriptions, ads, paid access, or paid skips in this build. Earned
campaign rewards and headshot camos still require their gameplay achievements.

`Data/monetization.json` controls the launch:

- `freeMode: true`: free cosmetic collection claims; hard-blocks every prompt.
- `paidEnabled: false`: a second independent barrier to spending.
- `shopFree: true`: zero effective Field Fee prices, including consumables.
- All marketplace IDs are `0` placeholders. No products have been created or
  repriced on the Roblox website. Free claims grant inventory inside the game;
  they do not pretend Roblox sold a zero-Robux pass.

Raw equipment costs remain in the original tuning files for future economy
balancing. Every current shop display, world price plaque and server debit uses
`CommerceCatalog.shopCost`, so those raw values do not charge players. Range
payout remains zero; normal match rewards still accumulate. Existing development
infinite-money/map-unlock flags remain as requested before this session.

## Inventory and selection

The existing loop is hub → field gate → five-round solo gauntlet → results → hub.
Players earn Field Fees, campaign equipment and map access. The pole-barn shop
already handled server-authoritative inventory and equipping. It had placeholder
Robux entries but no live receipt/prompt integration. ProfileStore was declared in
Wally but absent, so saves fell back to temporary memory.

The initial set attaches to the established paint and marker-finish slots:

| Collection | Audience | Contents | Eventual product type and rationale |
| --- | --- | --- | --- |
| Paint Locker | Visitors | Pink, cyan, lime, violet paint | Permanent pass: a clear, immediate cosmetic choice, bought once |
| Workshop Finishes | Returning players | Duracoat and Split Dust finishes | Permanent pass: lasting customization without altering shot statistics |

Both are free now and remain obtainable individually from the free supply shop.
Free claims permanently stay in the inventory if prices change later; do not
revoke them. Headshot camos are deliberately outside commerce and cannot be
bought or granted through these products. There are no recurring charges for a
permanent collection and no repeat-sale product that would sell an already-owned
finish again.

## Persistence and server boundaries

The official ProfileStore source is now bundled under
`src/ServerScriptService/Vendor/ProfileStore.luau`, pinned to upstream commit
`45c9847cbcf1fc260369c50eb335aba7c35aecdd`. Its Apache 2.0 license is in
`docs/licenses/ProfileStore.txt`. SHA-256:
`ad43737203688b8e88cab34ebe8c483000c157e53bfb41e35f1b49ee89d0c95f`.
Wally is no longer necessary to obtain this dependency. Installed packages can
still take precedence; otherwise the pinned module is used.

Published servers use session-locked profiles. The ordinary place uses
ProfileStore.Mock in Studio; the demo and headless tests use explicit in-memory
sessions. Neither test backend can acknowledge paid receipts or open prompts.
A missing dependency outside demo mode stops startup instead of silently losing
live saves. Version-1 profiles reconcile into version 2 without replacing their
currency, loadout or inventory. Session loss clears the active handle and asks
the player to rejoin; further currency, equip and grant mutations are refused.

`Commerce` owns the single `MarketplaceService.ProcessReceipt` callback. It
matches server-configured developer-product IDs, records each `PurchaseId` with
its grant in the same profile, and acknowledges only after that exact receipt
appears in `Profile.LastSavedData`. A `Save()` call alone is insufficient.
Storage errors, player absence, unknown IDs, lost sessions and concurrent
callbacks return `NotProcessedYet`. Retrying an unconfirmed receipt cannot
duplicate inventory. Receipts for previously sold products still get fulfilled
when selling/free mode changes; keep retired IDs in the server catalogue.
Receipt history is not truncated. Before high-volume repeat consumables are
introduced, plan receipt archival against DataStore document limits.

No repeat product is currently exposed. The receipt framework supports
server-audited deterministic cosmetic grants and has retry/replay coverage.
Adding genuinely repeatable benefits requires a matching cosmetic-consumption
feature and grant handler, not merely changing a pass's type.

Pass benefits are refreshed from `UserOwnsGamePassAsync` on join and after the
server's purchase-finished event; the event's boolean alone never grants an item.
Old/free inventory counts as collected and is not sold back to its owner.
Free claims and paid grants use the same cosmetic allowlist: paint colors and
marker finishes only. No weapon, aim, currency, camo-progress or stat grants.

`PolicyService:GetPolicyInfoForPlayerAsync` is called per player and cached for
five minutes. Paid prompts fail closed if the policy request fails. The current
passes are fixed cosmetics and have no restricted randomized/traded component.
Ads, paid randomness, trading, subscriptions and other unimplemented features are
explicitly disabled and fail the catalogue audit if enabled. Their respective
eligibility rules still need actual integration if those features are built;
this implementation does not claim a generic policy fetch implements them.

## Presentation and later activation

The shop displays **FREE**, **Claim free**, **Collected**, **Equip**, and
**Earn on field**. There are no urgency timers, fake sales, paid revival prompts,
progress-reset threats, or random rewards. Purchases are optional actions inside
the shop. For future paid collections the button says **See price** and opens
Roblox's native confirmation; the game does not hardcode or present a guessed
regional price. The native prompt presents the user's current price. If custom
prices are added later, fetch them on the client with `GetProductInfoAsync` as
required by the regional-pricing documentation.

When the owner explicitly chooses to activate pricing:

1. Create permanent cosmetic passes for this experience in Creator Dashboard;
   configure their real IDs and sale settings there. Decide how they coexist
   with the ordinary Field Fee shop (currently all finishes/colors remain free).
2. Keep free inventory already granted. Set `freeMode` and `paidEnabled`
   intentionally; `shopFree` is a separate Field Fee economy decision.
3. Verify persistence, real pass ownership/rejoins and purchase prompts in a
   private published test place. Use Roblox's documented developer-product test
   flow before exposing any future repeat product. Check personalized/regional
   prices if enabling managed pricing.
4. Turn off development overrides and run `tools/ship-check`. The current
   deliberate dev overrides cause its sole failure. This check is not a
   substitute for live purchase and Studio playtests.

None of these dashboard or publishing actions has been performed.

## Strategies deliberately left unavailable

Subscriptions need ongoing benefits and an actual update cadence; paid private
servers and trading add little to this solo experience. Paid access would
contradict the current free launch. Ads need a deliberate world placement and
per-player eligibility handling. Avatar commissions require owned/moderated
catalogue assets and an avatar-shopping flow. Roblox Plus integration is not a
new in-game product tier; no signup prompt is added here. Creator Store plugins
and models are creator-facing distribution products, outside this game's shop.
No multiplayer, external asset listing, billing, or ad placements were invented
to force these strategies into the project.

## Verification

Run `lune run tools/run-tests` for pure economy, receipt, camo, progression and
simulation checks. `tools/check-persistence` exercises the real profile adapter
with controlled writes and session loss. `tools/run-live-checks` exercises live
MatchService against mocked engine/projectile boundaries.
`tools/check-client-ui` constructs UI and markers using Lune's Roblox datatypes;
`tools/check-demo-world` constructs all maps and validates decorative geometry.
These are headless checks; live DataStore/Marketplace traffic and rendered
Studio appearance still need a real playtest.

API sources verified 2026-09-07: [Roblox monetization](https://create.roblox.com/docs/production/monetization),
[MarketplaceService](https://create.roblox.com/docs/reference/engine/classes/MarketplaceService),
[PolicyService](https://create.roblox.com/docs/reference/engine/classes/PolicyService),
[regional pricing](https://create.roblox.com/docs/production/monetization/regional-pricing),
[ProfileStore API](https://madstudioroblox.github.io/ProfileStore/api/),
[ProfileStore receipt guidance](https://madstudioroblox.github.io/ProfileStore/devproducts/).
