# Handoff: shopping list, cart and agent checkout

To: **David (C)**, who owns the shopping agents and `Features/Vibe/`. Alex (A): the Designer already puts a shopped product into the room as a placement (`Placement.product`), so check with David before changing that.
From: Michelle (B). Written 2026-10-18.

## Where things stand

- Shopping starts only at Room > Make it real > "Shop a vibe" (`RoomVibe/Features/Vibe/VibeView.swift`). Agents return products per item (title, price, retailer, `productURL`).
- Each product card has **Add** (drops the product into the room as an object) and **Open** (the retailer's page in the browser).
- Nothing remembers which products a user picked across screens. There is **no shopping list, no cart and no checkout**.
- Paper frames "v2 · K · Shop" and "v2 · L · Cart" are an old generic catalog and cart (quantities, subtotal, delivery, Checkout). They do not match the agent flow and will be redrawn. Do not build them as drawn.
- Paper frames "main · S1" to "S5" show what `VibeView` looks like today.

## What needs building

1. **A shopping list (cart) per room.** Persist the picks: product, retailer, price, `productURL`, which room and which vibe it came from. Survive app restarts. Decide with the Supabase work (`docs/specs/supabase-storage.md`) whether it syncs.
2. **List UI.** Show each pick with its store, price and a total against the budget. Remove a pick. "Add" in `VibeView` should write to this list, not only to the room. The designs will come from Michelle in Paper.
3. **Checkout = dispatch agents.** The intent is that checkout sends a Browserbase agent to each retailer's site to buy the items there, instead of linking the user out. One agent run per retailer, with the picks for that store.

## Constraints for checkout (please read before building)

- **Spending is irreversible. The user must confirm explicitly** before any agent buys: a review step that shows every item, price, retailer and the total. Never start a purchase from a single tap on "Add".
- **Cap spend** at the budget the user set. Stop and ask if a price changed or an item is out of stock.
- **Payment and shipping details:** decide where they come from and where they are stored. Do not log them, and do not send them to a model. Raise this with Michelle before choosing.
- **Status per retailer:** queued, running, done, failed, needs the user (login, CAPTCHA, address). Partial success is normal: show which stores finished.
- **Fallback:** if an agent cannot finish a store, give the user the "Open" link for those items.
- Prices already exclude shipping and tax (see the note in `VibeView`). The final total should include them once known.

## Open questions

- Who holds the retailer accounts or guest checkout details?
- One confirmation for all stores, or one per store?
- Does the cart sync to Supabase?
- Where does shopping start from? Candidates: Room detail, the fullscreen vibe pill, vibe details, the Vibes tab. Today it is only reachable after a render.
