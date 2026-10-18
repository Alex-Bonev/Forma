# Handoff: shopping list, cart and agent checkout

To: **David (C)**, who owns the shopping agents and `Features/Vibe/`. Alex (A): the Designer already puts a shopped product into the room as a placement (`Placement.product`), so check with David before changing that.
From: Michelle (B). Written 2026-10-18.

## Where things stand

- Shopping starts only at Room > Make it real > "Shop a vibe" (`RoomVibe/Features/Vibe/VibeView.swift`). Agents return products per item (title, price, retailer, `productURL`).
- Each product card has **Add** (drops the product into the room as an object) and **Open** (the in-app product detail page, which has "Go to original listing").
- **Built (UI):** the cart is every `Placement.product` across the rooms (`RoomCart`). `CartSheet` shows one room or all rooms, `ProductDetailView` shows a product, and cart icons sit in the fullscreen room, on Home and in Shop a vibe. See `docs/specs/cart.md`.
- **Not built:** checkout (the button is disabled), scraped product details beyond what `ShopProduct` carries, a budget line in the cart, and syncing the cart. The cart is derived from placements, so it does not record which vibe a product came from.
- Paper: K (Shop) is deleted. L, L2, PD1 and PD2 are the cart and product detail frames. "main · S1" to "S5" show `VibeView`.

## What needs building

1. **Cart data, the rest of it.** The cart survives restarts because it lives on the placements. Still open: whether it syncs (`docs/specs/supabase-storage.md`), and whether to record the vibe a product came from.
2. **Cart extras.** A budget line (the budget is not stored yet) and the backend fields for richer product details (description, material, color, stock, returns).
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
