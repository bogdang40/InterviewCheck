"""Calculate a saved or draft score from the criteria that have a rating."""


def percentage_from_totals(weighted_sum: int, total_weight: int) -> float:
    if total_weight <= 0:
        raise ValueError("A weighted score needs at least one positive weight.")
    tenths, remainder = divmod(weighted_sum * 200, total_weight)
    # Use the nearest tenth of a percent. An exact tie goes to the even tenth.
    if remainder * 2 > total_weight or (remainder * 2 == total_weight and tenths % 2):
        tenths += 1
    return tenths / 10


def weighted_score_pct(items) -> float | None:
    weighted_sum = total_weight = 0
    for item in items:
        rating, weight = item["rating"], item["weight"]
        if isinstance(rating, int) and 1 <= rating <= 5 and isinstance(weight, int) and weight > 0:
            weighted_sum += rating * weight
            total_weight += weight
    return percentage_from_totals(weighted_sum, total_weight) if total_weight else None
