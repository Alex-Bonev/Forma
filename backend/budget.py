"""Pick at most one product per shopping-list item so the set fits the user's budget."""
from itertools import product

MAX_PER_ITEM = 3  # only the best few per item are considered, which keeps the search at <= 4^6 combinations


def pick_within_budget(prices: list[list[float | None]], budget: float | None) -> list[int | None]:
    """prices[i][j]: price of item i's j-th product, agents' best first (None = unknown price).
    Returns the chosen product index per item (None = skip the item).

    Without a budget every item takes its first product. With one, products without a price are never chosen and
    the set maximizes items covered, then fit (earlier products are better fits), then the lowest total.
    Exact search over integer cents (no float drift at the budget edge).
    """
    if budget is None:
        return [0 if p else None for p in prices]
    cents = [[round(x * 100) if x is not None and x > 0 else None for x in p[:MAX_PER_ITEM]] for p in prices]
    limit = round(budget * 100)
    options = [[None] + [j for j, x in enumerate(p) if x is not None and x <= limit] for p in cents]
    best, best_key = [None] * len(prices), None
    for pick in product(*options):
        chosen = [(i, j) for i, j in enumerate(pick) if j is not None]
        total = sum(cents[i][j] for i, j in chosen)
        if total > limit:
            continue
        key = (len(chosen), -sum(j for _, j in chosen), -total)
        if best_key is None or key > best_key:
            best, best_key = list(pick), key
    return best
