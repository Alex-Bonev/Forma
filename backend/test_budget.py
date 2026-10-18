from budget import pick_within_budget


def test_no_budget_takes_first_of_each():
    assert pick_within_budget([[900, 10], [], [None]], None) == [0, None, 0]


def test_fits_budget_and_prefers_more_items():
    # The best-fit sofa alone eats the budget; a cheaper sofa leaves room for the lamp too.
    assert pick_within_budget([[700, 450], [200, 120]], 700) == [1, 0]


def test_prefers_better_fit_then_lower_total():
    assert pick_within_budget([[100, 50], [100, 50]], 1000) == [0, 0]
    assert pick_within_budget([[300, 300]], 1000) == [0]


def test_skips_unpriced_and_impossible():
    assert pick_within_budget([[None, 80], [None]], 100) == [1, None]
    assert pick_within_budget([[500], [600]], 100) == [None, None]
    assert pick_within_budget([], 100) == []


def test_six_items_exact():
    prices = [[400, 250, 150]] * 6
    pick = pick_within_budget(prices, 1000)
    assert sum(prices[i][j] for i, j in enumerate(pick) if j is not None) <= 1000
    assert pick.count(None) == 0  # 6 x 150 = 900 fits, so every item is covered


def test_lowest_total_breaks_fit_ties():
    assert pick_within_budget([[100, 40], [60, 50]], 150) == [1, 0]


def test_cent_prices_hit_budget_exactly():
    assert pick_within_budget([[19.99], [30.01]], 50) == [0, 0]
    assert pick_within_budget([[0.1], [0.2]], 0.3) == [0, 0]


def test_only_top_three_per_item():
    assert pick_within_budget([[900, 900, 900, 10]], 100) == [None]
    assert pick_within_budget([[5] * 50] * 6, 100) == [0] * 6  # stays fast
