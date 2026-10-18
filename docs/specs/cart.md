# Spec: Cart and product detail

Status: **UI built; checkout not built**. Owner: Michelle (B) for the UI, David (C) for agents and the backend. Paper: page "forma — v2", frames L, L2, PD1, PD2, "cart exists" variants of A, A2, A3 and E, and "Motion spec · Add to cart".

## What the cart is

- The cart is **every shopped product that has been added to a room**: each `Placement` with a `product`. Nothing else is stored except the room's budget (below). Removing a product from the room removes it from the cart.
- Add comes from the shopping screen (`VibeView`) or the product detail page. Both use `RoomCart.add`.
- A cart for one room, or a cart for all rooms (sectioned by room).

## Screens

- **Cart (L, L2)** is a sheet. Title "Cart", item count, close button. One room: subtitle "Added to <room>". All rooms: one section per room with "N items · $total". All-rooms subtitle: "Everything added to your rooms". Rows: thumbnail, title, store, price, chevron to the product detail. Footer: subtotal, "N without a listed price" when some listings have no USD price, and "Prices exclude shipping and tax." Empty state: "Nothing in your cart yet." and "Add products from Shop a vibe."
- **Check out** is shown but **disabled**, with "Checkout isn't available yet. Open each item's original listing to buy." Agent checkout is not built (see `docs/handoff-cart-checkout.md`, issue #34).
- **Product detail, while shopping (PD1)**: image, store and host, title, price, details the app has (size, category, store, listing host), "Add to room" (becomes "Added to room"; hidden when no room is known), "Go to original listing". Reached from "Open" on a product card: Open opens this page, not the retailer. Footnote: "Details come from the store's listing. Check the original listing before you buy."
- **Product detail, in your room (PD2)**: the same page, an "In <room>" chip, "Go to original listing", "Remove from room". Reached from a cart row.
- The page shows only fields the backend sends. Richer scraped details (description, material, color, stock, returns) need backend fields.

## Budget

- The room's budget is `Project.budgetUSD` (USD, nil = no limit). Shop a vibe saves it when a run with a budget finishes (never for the demo run). It is per room, not per vibe.
- The one-room cart (not the all-rooms cart) shows a budget card above the list when the room has a budget and the cart is not empty: spent "of $B", "Change", a segment bar, and "$X left. Prices exclude shipping and tax." or, when over, "Over budget by $X."
- Each row shows a dot and "N% of budget" when the budget and the price are known.
- Under the rows, while money is left, a note says "Adding anything over $X goes past your $B budget." Adding is never blocked.
- "Change" opens the budget sheet ("Your cart total stays the same. Only the budget changes.", "Update budget"). It writes `Project.budgetUSD` only and does not re-pick products.
- Paper: BG1 to BG5 on "forma — v2".

## Entry points

- Fullscreen room: a cart icon to the right of "Add object" once the room has at least one product. It opens that room's cart. Hidden while the Objects sheet is open. With the cart icon showing, "Make it real" and "Add object" may shrink their text (down to 70%) to fit.
- Home: a cart icon to the right of "Scan Object" once any room has a product. It opens the all-rooms cart.
- Shop a vibe: a cart icon in the top bar once the room has a product.

## Motion

- **Add to cart:** a 56 pt square with the product image flies from the card to the cart icon (440 ms, x ease-out, y ease-in), shrinking to 0.25 and fading to 0.2. The cart count rises on arrival. The cart icon then beams: scale 1 to 1.18 and back, and a sage ring grows and fades (600 ms).
- Several adds: each flies on its own. "Add all" does not fly; the cart just beams.
- If the cart icon's position is not known yet (first add), the flight waits up to 500 ms for it; if it never appears the flight is skipped and the add still happens.
- Reduced motion: no flight, no beam.

## Not built

- Agent checkout. Entry points other than the three above (to be discussed). Scraped product details beyond what `ShopProduct` carries.
