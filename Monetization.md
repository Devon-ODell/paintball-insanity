---
name: roblox-monetization
description: Add monetization to a Roblox experience the way Roblox's own Monetization documentation prescribes — choosing between immersive ads, Roblox Plus, subscriptions, passes, developer products, paid access (Robux or local currency), private servers, catalog commissions, and Creator Store plugins/models, then implementing them with the required purchase-data persistence and PolicyService eligibility gating. Use this skill whenever the task touches earning revenue in an experience: adding a shop, a pass, a gamepass, a battle pass, in-game currency, a premium tier, a paid unlock, a "buy" prompt, a price change, a loot box or random reward, or anything described as monetization, IAP, or in-game purchases — even if the user just says "let players buy X" and never uses the word monetization.
---

# Roblox monetization

This skill encodes Roblox's Monetization documentation. Its job is to keep monetization
work inside what Roblox actually documents and sanctions, rather than importing free-to-play
patterns from other platforms that Roblox specifically warns against.

**Scope discipline matters here.** The source page is a strategy and product overview,
not an API reference. It tells you *which* products exist, *when* each fits, and *what
you are obligated to do* around them. It does not contain code samples. So: follow this
skill for product selection, structure, and compliance, and verify exact API surfaces
(`MarketplaceService`, `DataStoreService`, `PolicyService` method names and signatures)
against Studio autocomplete or current API reference before writing calls. Do not
invent a product type, a fee, a revenue share, or a policy that isn't listed below.

---

## Step 1: Read the codebase before proposing anything

Monetization has to attach to systems that already exist. Before suggesting products,
find and report:

- What the player already earns, unlocks, or progresses through
- Whether any persistence layer exists (`DataStoreService`, an external store, or nothing)
- Where the session loop is — what a player does in their first five minutes, and what
  they do on their twentieth visit
- Whether there's a shop/UI layer already, or whether one has to be built
- Any existing `MarketplaceService` or `PolicyService` usage

If persistence doesn't exist yet, say so plainly. Roblox does not automatically record
product or purchase information. Without a store, purchases will be lost. That gap has to
be closed before or alongside the first purchasable item, not after.

## Step 2: Decide strategy before picking products

Roblox users downvote experiences when they don't approve of the monetization. Design
against the audience the docs describe.

**Tourists vs. locals.** Two rough categories of user:

- *Tourists* hop between experiences, preferring variety over depth. They want items with
  immediate effects — either making gameplay more fun right now, or making them stand out
  so other players ask where they got it.
- *Locals* focus on one experience or a small set. They engage more deeply and make up
  nearly all of an experience's engaged user base. They want items with long-term
  benefits, such as a battle pass.

A catalog that serves only one group leaves the other unserved. Name which group each
proposed product is for.

**Social features.** Roblox players enjoy experiences that emphasize social interaction.
Limited-time items or events create excitement around content, and a trading system
encourages interaction. Both work alone; they're particularly effective combined.

**Live ops.** Post-launch support is easier on Roblox than elsewhere because updates ship
quickly. Frequent content updates maintain engagement — a weekly cadence is ideal, monthly
at the bare minimum. Regaining a lapsed player's interest is much harder than holding an
active one's. Give each update a single **theme** so players can tell what's new and so
promotional assets line up. Don't be afraid to make players *earn* access to new content:
new users flock to updates, but if they don't feel they've achieved something they may
leave soon after. That sense of earning can come either from monetizing the update content
or from prerequisite conditions for playing it.

**Patterns to avoid.** Appointment mechanics and timers that can be removed or brought
forward work on other platforms but are unpopular with Roblox users, who take issue with
their fun ending prematurely. Do not port them in.

**Honest framing.** Applying these techniques does not guarantee effective monetization,
and an experience does not need financial goals to be worth building.

## Step 3: Choose products from this catalog only

### Immersive ads
Ad units inserted into the experience that permit Roblox to programmatically serve ad
content from advertisers to active players. Formats include image ads and portal ads.
Revenue without asking the player for anything — but placement is world-building work,
and eligibility is `PolicyService`-gated (see Step 5).

### Roblox Plus
Earns through increased in-game purchases driven by Roblox-subsidized user discounts,
sign-up bonuses for each new subscriber brought in, and engagement in paid private servers.

### Subscriptions
Recurring benefits for a monthly fee, priced in local currency and managed per-experience
(each has a state — active or inactive — and an ID). Fits *locals*: ongoing value,
ongoing relationship. Requires benefits that keep being worth paying for, which means it
depends on the live-ops cadence above.

### Passes
A **one-time Robux fee** for a special privilege: entry to a restricted area, an in-game
avatar item, or a permanent power-up. The cleanest first product for most experiences —
one purchase, permanent effect, easy to reason about in code.

### Developer products
An item or ability a player can purchase **more than once** — in-game currency, ammo,
potions. Purchases can be prompted, recorded, and queried through scripting. This is the
product type that most requires the persistence work from Step 1: repeat purchases are
worthless if the grant isn't durably recorded.

### Paid access in Robux
A **one-time Robux fee** to access the experience at all. Some developers use it
temporarily to create a closed beta where the most engaged players get early access and
help with testing and feedback.

### Paid access in local currency
A **one-time fee in the player's local currency** to access the experience; players
without local currency support are charged in USD. Same closed-beta use case.

### Private servers
A subscription-based feature letting a player decide who can play with them. Private
servers can be free, or monetized by charging a **monthly Robux fee** for access.

### Catalog fees and commissions
Accessories and clothes can be created and sold on the Marketplace. After paying the
upload fee and submitting an asset for approval, moderation reviews it and, if approved,
adds it to the catalog. A commission arrives every time a player purchases the item — and
if the purchase happens inside an experience via the avatar inspect menu or the avatar
editor service, the experience owner also receives a commission.

### Plugins and models
A plugin extends Studio; a model is a reusable asset. Both can be offered to other creators
on the Creator Store free, or sold for **United States Dollars** — minimum $4.99 for
plugins, $2.99 for models. Roblox deducts only taxes and payment processing fees on these
sales. Note the **30-day escrow hold**: Roblox holds the seller's share for 30 days from
the date of sale.

### Pricing systems
- **Managed pricing** unifies regional pricing and price optimization. Opt in once, choose
  which items to include, and it keeps prices optimized across products and regions over time.
- **Price optimization** finds the best price points for passes and developer products,
  to earn more over time while keeping prices competitive.

Prefer these to hand-tuned price constants, and don't hardcode prices in places that make
opting in later a refactor.

## Step 4: Persist every purchase

Roblox does not automatically record product or purchase information. Purchase data must be
carefully stored using `DataStoreService` or another data storage service hosted outside of
Roblox, or it will be lost.

Treat this as a hard requirement of shipping any purchasable item, not a follow-up ticket.
When implementing, make sure:

- The grant is written to the store before the purchase is acknowledged as complete
- Repeat-purchase products (developer products) are recorded per purchase, not as a boolean
- Failures are handled rather than swallowed — a dropped write is a player who paid and
  got nothing

## Step 5: Gate eligibility with PolicyService

Roblox is a global community of all ages, so promotions within an experience should be
suitable for all audiences by default. Some monetization products are restricted in certain
locations — paid random items, for example. `PolicyService` returns whether a given player
is eligible for specific items or features according to their **location, age, and platform**.

Integrating it is a compliance obligation, not an optimization. Use it to determine whether
each player is:

- Eligible to purchase subscriptions or commerce products
- Allowed paid random items, paid item trading, or to see immersive ads

**Hard rule.** If a player can use Robux — or anything else acquired with Robux — to get a
random reward, `PolicyService` is *required* to block that feature for players who are not
permitted to use random items in exchange for Robux. Any loot box, crate, gacha, spin, or
randomized-outcome purchase falls under this. If the codebase has one and no
`PolicyService` check, that's a defect; report it.

Also: all developers must be transparent about any chance-based monetization and use those
mechanics responsibly.

## Step 6: Present products honestly

Monetization products must be presented in a way that's transparent, honest, and
user-friendly. Players must never be misled, confused, or pressured into purchases they did
not intend, and must always have the freedom to make a clear, deliberate choice to obtain a
subscription or spend Robux on a specific item.

**Discounts must be genuine and fair.**
- Not genuine if an item is always "on sale" for the same amount of Robux.
- Not fair if offered only for a very short time, pressuring a fast purchase.

**Avoid at all times:**
- Claiming a subscription or item is almost out of stock or only available for a short time
  when that isn't true.
- Countdown timers that aren't accurate or that automatically restart for the same item.

The documented failure example: a "deal of the day" advertised as 24-hours-only, shown to
every player on every login, never actually expiring. That's a false sense of urgency and
is not user-friendly.

**Language.** Avoid pushy or urgent messaging, especially toward minors — high-pressure
language can be overwhelming. Use these substitutions in UI copy:

| Language to avoid | Recommended alternative |
|---|---|
| "GET IT NOW" | "View Item" |
| "LAST CHANCE, ACT NOW" | "See Price" |
| "BUY BEFORE IT'S GONE!" | "Open Shop" |

Apply this to button labels, notification text, and prompt copy — anywhere the player reads
words attached to a purchase.

---

## Working in a single-player experience

Several documented strategies assume other players are present: trading systems, social
excitement around limited-time items, private servers as a paid feature, catalog commissions
through the avatar inspect menu. These do not translate to a solo experience.

Do not silently invent multiplayer systems to unlock them, and do not silently drop the
strategy either. Instead:

- Lean on what works solo: passes for permanent unlocks, developer products for consumables
  and currency, subscriptions for ongoing benefits, immersive ads, paid access.
- Note in the handoff which documented strategies are unavailable and what would have to
  change structurally to use them — then let the human decide whether that's worth it.
- Limited-time content still works solo; it just loses the social amplification. Keep the
  honesty rules from Step 6 fully intact if using it.

## What to produce

When asked to add monetization, deliver in this order:

1. **Inventory** — what's in the codebase now, and whether purchase persistence exists.
2. **Proposal** — which products from Step 3, each with: the player group it targets
   (tourist or local), what it attaches to in the existing game loop, and why that product
   type rather than a neighboring one. Keep the initial set small.
3. **Implementation** — the code, with persistence (Step 4) and eligibility gating (Step 5)
   included in the same change, not deferred. Verify API signatures before writing them.
4. **Copy review** — every player-facing string checked against Step 6.
5. **Gaps** — anything the documentation covers that this codebase can't currently support,
   flagged for the human.

## Out of scope — don't improvise

- No product type, fee, minimum price, revenue share, or escrow term beyond those listed
  in Step 3.
- No appointment mechanics or removable/advanceable timers.
- No urgency framing, fake scarcity, restarting countdowns, or permanent "sales."
- No chance-based rewards without transparency and a `PolicyService` gate.
- No claims about earnings, conversion rates, or expected revenue — the documentation
  explicitly guarantees nothing.

Where this skill is silent and the answer matters, ask the human or check current Roblox
Creator documentation. Don't fill the gap from general free-to-play instinct — that's the
exact failure mode the source material warns about.
