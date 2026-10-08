#!/usr/bin/env python3
"""
Build football ratings for the 151 original Pokemon.

Input : data/source_gen1.csv  (base stats, types, size, evolution info; from PokeAPI's open CSVs)
Output: data/pokemon.json and js/data.js (same data, loadable without a server)

Method (deterministic, no hand-tuning):
  1. Standardize each input (z-score across the 151). Weight and height use log scale.
  2. Each attribute = weighted blend of those z-scores (ATTR_FORMULAS).
  3. Re-standardize each blend and map to a Madden-style scale: 70 + 11*z, clipped to 40-99.
  4. Position OVR = weighted blend of attributes (POSITION_WEIGHTS), standardized the
     same way so a 90 QB and a 90 OL are equally rare.
  5. Primary position = balanced assignment: best fits first, with each position capped
     at a quota proportional to how many starters a league needs.

Run:  python3 scripts/build_data.py
"""
import csv, json, math, os, statistics

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "data", "source_gen1.csv")

ATTRS = ["SPD", "STR", "AGI", "AWR", "CTH", "THP", "THA", "BLK", "TKL", "COV"]
ATTR_NAMES = {
    "SPD": "Speed", "STR": "Strength", "AGI": "Agility", "AWR": "Awareness",
    "CTH": "Catching", "THP": "Throw power", "THA": "Accuracy",
    "BLK": "Blocking", "TKL": "Tackling", "COV": "Coverage",
}
# weights applied to z-scores of the inputs
ATTR_FORMULAS = {
    "SPD": {"speed": 1.0},
    "STR": {"attack": 0.65, "logw": 0.35},
    "AGI": {"speed": 1.0, "logw": -0.45},
    "AWR": {"sp_defense": 0.6, "maturity": 0.4},
    "CTH": {"speed": 0.5, "sp_defense": 0.3, "hp": 0.2},
    "THP": {"sp_attack": 1.0},
    "THA": {"sp_attack": 0.6, "sp_defense": 0.4},
    "BLK": {"defense": 0.45, "logw": 0.35, "logh": 0.2},
    "TKL": {"attack": 0.55, "defense": 0.45},
    "COV": {"speed": 0.5, "sp_defense": 0.3, "defense": 0.2},
}
POSITION_WEIGHTS = {
    "QB": {"THP": 0.35, "THA": 0.35, "AWR": 0.20, "SPD": 0.10},
    "RB": {"SPD": 0.30, "AGI": 0.30, "STR": 0.20, "CTH": 0.10, "AWR": 0.10},
    "WR": {"SPD": 0.40, "CTH": 0.35, "AGI": 0.25},
    "TE": {"CTH": 0.30, "BLK": 0.30, "STR": 0.25, "SPD": 0.15},
    "OL": {"BLK": 0.55, "STR": 0.35, "AWR": 0.10},
    "DL": {"STR": 0.40, "TKL": 0.35, "BLK": 0.15, "SPD": 0.10},
    "LB": {"TKL": 0.40, "AWR": 0.20, "SPD": 0.20, "STR": 0.20},
    "CB": {"COV": 0.45, "SPD": 0.35, "AGI": 0.20},
    "S":  {"COV": 0.35, "TKL": 0.25, "SPD": 0.20, "AWR": 0.20},
}
STAR_OVR = 88       # stars keep their natural best position
TALENT_WEIGHT = 0.30  # share of every position OVR that comes from base stat total

# starters per team: QB1 RB1 WR3 TE1 OL5 | DL4 LB3 CB2 S2  -> scaled to 151 primaries
# Pokemon left out of the draft pool (by Pokedex number). Ratings are scaled across the remaining pool.
BANNED = {150}  # Mewtwo: too powerful

QUOTAS = {"QB": 7, "RB": 7, "WR": 21, "TE": 7, "OL": 34, "DL": 27, "LB": 21, "CB": 14, "S": 12}
assert sum(QUOTAS.values()) == 151 - len(BANNED)


def zscores(vals):
    m, s = statistics.mean(vals), statistics.pstdev(vals)
    return [(v - m) / s for v in vals]


def to_rating(z):
    return max(40, min(99, round(70 + 11 * z)))


def main():
    rows = [r for r in csv.DictReader(open(SRC, encoding="utf-8")) if int(r["id"]) not in BANNED]
    n = len(rows)
    assert n == 151 - len(BANNED), n

    def maturity(r):
        # fully evolved / legendary = mature; mid-stage partially; babies lowest
        if r["legendary"] == "1":
            return 1.25
        if r["is_final"] == "1":
            return 1.0
        return 0.5 if r["evo_stage"] == "2" else 0.0

    inputs = {
        "hp": [int(r["hp"]) for r in rows],
        "attack": [int(r["attack"]) for r in rows],
        "defense": [int(r["defense"]) for r in rows],
        "sp_attack": [int(r["sp_attack"]) for r in rows],
        "sp_defense": [int(r["sp_defense"]) for r in rows],
        "speed": [int(r["speed"]) for r in rows],
        "logw": [math.log(float(r["weight_kg"])) for r in rows],
        "logh": [math.log(float(r["height_m"])) for r in rows],
        "maturity": [maturity(r) for r in rows],
    }
    Z = {k: zscores(v) for k, v in inputs.items()}

    ratings = {}
    for a, f in ATTR_FORMULAS.items():
        blend = [sum(w * Z[k][i] for k, w in f.items()) for i in range(n)]
        ratings[a] = [to_rating(z) for z in zscores(blend)]

    # overall talent: base stat total, so a fast Magikarp is still a Magikarp
    bst = [sum(int(r[k]) for k in ("hp", "attack", "defense", "sp_attack", "sp_defense", "speed")) for r in rows]
    talent = [to_rating(z) for z in zscores(bst)]

    pos_ovr = {}
    for p, f in POSITION_WEIGHTS.items():
        blend = [(1 - TALENT_WEIGHT) * sum(w * ratings[a][i] for a, w in f.items()) + TALENT_WEIGHT * talent[i]
                 for i in range(n)]
        pos_ovr[p] = [to_rating(z) for z in zscores(blend)]

    # primary position
    #  1) stars (best OVR >= STAR_OVR) keep their natural best position
    #  2) everyone else fills the remaining position quotas, best relative fit first
    #     (fit = position OVR minus the Pokemon's own average across positions)
    def best_pos(i):
        return max(POSITION_WEIGHTS, key=lambda p: pos_ovr[p][i])

    left = dict(QUOTAS)
    primary = {}
    for i in range(n):
        if pos_ovr[best_pos(i)][i] >= STAR_OVR:
            primary[i] = best_pos(i)
            left[primary[i]] = max(0, left[primary[i]] - 1)

    def fit(i, p):
        return pos_ovr[p][i] - statistics.mean(pos_ovr[q][i] for q in POSITION_WEIGHTS)

    pairs = sorted(((fit(i, p), pos_ovr[p][i], i, p) for p in POSITION_WEIGHTS for i in range(n) if i not in primary),
                   reverse=True)
    for _, _, i, p in pairs:
        if i not in primary and left[p] > 0:
            primary[i] = p
            left[p] -= 1
    for i in range(n):  # anyone left over (quotas exhausted by stars) gets their best spot
        primary.setdefault(i, best_pos(i))

    out = []
    for i, r in enumerate(rows):
        h_in = round(float(r["height_m"]) * 39.3701)
        out.append({
            "id": int(r["id"]),
            "name": r["name"],
            "types": [t for t in (r["type1"], r["type2"]) if t],
            "pos": primary[i],
            "ovr": pos_ovr[primary[i]][i],
            "attrs": {a: ratings[a][i] for a in ATTRS},
            "posOvr": {p: pos_ovr[p][i] for p in POSITION_WEIGHTS},
            "height": f"{h_in // 12}'{h_in % 12}\"",
            "weightLb": round(float(r["weight_kg"]) * 2.20462),
            "base": {k: int(r[k]) for k in ("hp", "attack", "defense", "sp_attack", "sp_defense", "speed")},
            "legendary": r["legendary"] == "1",
            "family": int(r["family"]),
        })

    meta = {
        "attrNames": ATTR_NAMES,
        "positionWeights": POSITION_WEIGHTS,
        "attrFormulas": ATTR_FORMULAS,
        "source": "Base stats, types, height and weight: PokeAPI open data (github.com/PokeAPI/pokeapi), current-generation values.",
    }
    payload = {"meta": meta, "pokemon": out}
    os.makedirs(os.path.join(ROOT, "js"), exist_ok=True)
    with open(os.path.join(ROOT, "data", "pokemon.json"), "w") as f:
        json.dump(payload, f, indent=1)
    with open(os.path.join(ROOT, "js", "data.js"), "w") as f:
        f.write("// Generated by scripts/build_data.py - do not edit by hand\n")
        f.write("window.POKEDATA = " + json.dumps(payload, separators=(",", ":")) + ";\n")
    print(f"wrote {len(out)} pokemon")


if __name__ == "__main__":
    main()
