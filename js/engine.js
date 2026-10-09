/* Gridiron 151 engine: roster spots, chemistry, team ratings, AI drafting, grades, and the game simulator.
   Runs in the browser (window.G151Engine) and in Node (require) for testing and building norms.
   The simulator only uses + - * / and comparisons, so every device produces identical results from the same seed. */
(function (root, factory) {
  const E = factory();
  if (typeof module === "object" && module.exports) module.exports = E;
  else root.G151Engine = E;
})(typeof self !== "undefined" ? self : this, function () {
  "use strict";

  /* ---------- roster ---------- */
  // slot id, label, rating position, side, field x%, field y%
  const SLOTS = [
    { id: "FS", label: "S", pos: "S", side: "def", x: 34, y: 7 },
    { id: "SS", label: "S", pos: "S", side: "def", x: 66, y: 7 },
    { id: "CB1", label: "CB", pos: "CB", side: "def", x: 7, y: 21 },
    { id: "CB2", label: "CB", pos: "CB", side: "def", x: 93, y: 21 },
    { id: "WLB", label: "LB", pos: "LB", side: "def", x: 28, y: 25 },
    { id: "MLB", label: "LB", pos: "LB", side: "def", x: 50, y: 25 },
    { id: "SLB", label: "LB", pos: "LB", side: "def", x: 72, y: 25 },
    { id: "LDE", label: "DL", pos: "DL", side: "def", x: 23, y: 40 },
    { id: "LDT", label: "DL", pos: "DL", side: "def", x: 41, y: 40 },
    { id: "RDT", label: "DL", pos: "DL", side: "def", x: 59, y: 40 },
    { id: "RDE", label: "DL", pos: "DL", side: "def", x: 77, y: 40 },
    { id: "LT", label: "OL", pos: "OL", side: "off", x: 26, y: 58 },
    { id: "LG", label: "OL", pos: "OL", side: "off", x: 38, y: 58 },
    { id: "C", label: "OL", pos: "OL", side: "off", x: 50, y: 58 },
    { id: "RG", label: "OL", pos: "OL", side: "off", x: 62, y: 58 },
    { id: "RT", label: "OL", pos: "OL", side: "off", x: 74, y: 58 },
    { id: "TE", label: "TE", pos: "TE", side: "off", x: 86, y: 71 },
    { id: "WR1", label: "WR", pos: "WR", side: "off", x: 7, y: 58 },
    { id: "WR2", label: "WR", pos: "WR", side: "off", x: 93, y: 58 },
    { id: "WR3", label: "WR", pos: "WR", side: "off", x: 14, y: 71 },
    { id: "QB", label: "QB", pos: "QB", side: "off", x: 50, y: 74 },
    { id: "RB", label: "RB", pos: "RB", side: "off", x: 50, y: 90 },
  ];
  // share-link order (stable forever: don't reorder, only append)
  const SHARE_ORDER = ["QB","RB","WR1","WR2","WR3","TE","LT","LG","C","RG","RT","LDE","LDT","RDT","RDE","WLB","MLB","SLB","CB1","CB2","FS","SS"];
  const SLOT_BY_ID = Object.fromEntries(SLOTS.map(s => [s.id, s]));
  const POSITIONS = ["QB","RB","WR","TE","OL","DL","LB","CB","S"];
  const POS_NAMES = { QB:"Quarterback", RB:"Running back", WR:"Wide receiver", TE:"Tight end", OL:"Offensive line", DL:"Defensive line", LB:"Linebacker", CB:"Cornerback", S:"Safety" };
  const GROUP_NAMES = { QB:"Quarterback", RB:"Running back", WR:"Receivers", TE:"Tight end", OL:"Offensive line", DL:"Defensive line", LB:"Linebackers", CB:"Cornerbacks", S:"Safeties" };
  const ROUNDS = SLOTS.length;

  // how much each roster spot matters to a team's rating (per player)
  const POS_WEIGHT = { QB: 3.0, RB: 1.3, WR: 1.15, TE: 1.0, OL: 0.9, DL: 1.05, LB: 0.9, CB: 1.1, S: 0.9 };
  // ratings above 85 count extra: a 95 is worth 101, a 99 is worth 107.4
  const starValue = (v, k = 1) => v + Math.max(0, v - 85) * 0.6 * k;

  /* ---------- seeded randomness (identical on every device) ---------- */
  function hashStr(s) {
    let h = 2166136261 >>> 0;
    for (let i = 0; i < s.length; i++) { h ^= s.charCodeAt(i); h = Math.imul(h, 16777619) >>> 0; }
    return h >>> 0;
  }
  function rngFrom(seed) {
    let a = (typeof seed === "number" ? seed : hashStr(String(seed))) >>> 0;
    const next = () => {
      a = (a + 0x6D2B79F5) >>> 0;
      let t = a;
      t = Math.imul(t ^ (t >>> 15), t | 1);
      t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
      return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
    };
    next.normal = () => (next() + next() + next() + next() - 2) * 1.7320508075688772; // mean 0, sd 1
    next.pick = arr => arr[Math.floor(next() * arr.length)];
    next.weighted = (items, w) => {
      let total = 0; for (const x of w) total += x;
      let r = next() * total;
      for (let i = 0; i < items.length; i++) { r -= w[i]; if (r <= 0) return items[i]; }
      return items[items.length - 1];
    };
    return next;
  }

  /* ---------- chemistry ---------- */
  const UNITS = [
    { key: "OL", name: "line", slots: ["LT","LG","C","RG","RT"], at: { 3: 2, 4: 3, 5: 4 } },
    { key: "REC", name: "receiving corps", slots: ["WR1","WR2","WR3","TE"], at: { 3: 2, 4: 3 } },
    { key: "DL", name: "front four", slots: ["LDE","LDT","RDT","RDE"], at: { 3: 2, 4: 3 } },
    { key: "LB", name: "linebackers", slots: ["WLB","MLB","SLB"], at: { 3: 2 } },
    { key: "DB", name: "secondary", slots: ["CB1","CB2","FS","SS"], at: { 3: 2, 4: 3 } },
  ];
  const cap = s => s[0].toUpperCase() + s.slice(1);

  // roster: {slotId: pid}; byId: Map pid -> pokemon. Returns per-slot bonus and the badges that explain it.
  function chemistry(roster, byId) {
    const bonus = {}; const badges = [];
    const add = (slot, n) => { bonus[slot] = Math.min(5, (bonus[slot] || 0) + n); };
    const P = slot => roster[slot] ? byId.get(roster[slot]) : null;

    for (const u of UNITS) {
      const members = u.slots.filter(P);
      const counts = {};
      for (const s of members) for (const t of P(s).types) counts[t] = (counts[t] || 0) + 1;
      let bestType = null, best = 0;
      for (const t of Object.keys(counts).sort()) if (counts[t] > best) { best = counts[t]; bestType = t; }
      const amt = u.at[best];
      if (amt) {
        const who = members.filter(s => P(s).types.includes(bestType));
        who.forEach(s => add(s, amt));
        badges.push({ kind: "unit", title: `${cap(bestType)} ${u.name}`, text: `${best} ${cap(bestType)}-type players, +${amt} each`, slots: who });
      }
    }
    // quarterback connection: receivers who share a type with the QB
    const qb = P("QB");
    if (qb) {
      const linked = ["WR1","WR2","WR3","TE","RB"].filter(s => P(s) && P(s).types.some(t => qb.types.includes(t)));
      if (linked.length) {
        linked.forEach(s => add(s, 2)); add("QB", Math.min(3, linked.length));
        badges.push({ kind: "qb", title: "Quarterback connection", text: `${qb.name} shares a type with ${linked.map(s => P(s).name).join(", ")}: +2 each, +${Math.min(3, linked.length)} to ${qb.name}`, slots: ["QB", ...linked] });
      }
    }
    // evolution families on the same roster
    const fam = {};
    for (const s of SLOTS) { const p = P(s.id); if (p) (fam[p.family] = fam[p.family] || []).push(s.id); }
    for (const f of Object.keys(fam)) {
      const slots = fam[f];
      if (slots.length >= 2) {
        slots.forEach(s => add(s, 2));
        badges.push({ kind: "family", title: "Family ties", text: `${slots.map(s => P(s).name).join(" and ")} are one evolution family: +2 each`, slots });
      }
    }
    return { bonus, badges };
  }

  // effective rating at a roster spot (position rating + chemistry)
  function slotRating(roster, byId, chem, slotId) {
    const p = byId.get(roster[slotId]);
    return p ? p.posOvr[SLOT_BY_ID[slotId].pos] + (chem.bonus[slotId] || 0) : 0;
  }

  // weighted team rating with a star premium; offense/defense the same way
  function teamRating(roster, byId, chem) {
    chem = chem || chemistry(roster, byId);
    const calc = side => {
      let sw = 0, sv = 0;
      for (const s of SLOTS) {
        if (side && s.side !== side) continue;
        if (!roster[s.id]) continue;
        const w = POS_WEIGHT[s.pos];
        sw += w; sv += w * starValue(slotRating(roster, byId, chem, s.id));
      }
      return sw ? Math.round(sv / sw) : 0;
    };
    return { ovr: calc(), off: calc("off"), def: calc("def") };
  }

  /* ---------- AI drafting ---------- */
  const AI_STYLES = {
    balanced: { label: "Best player available", pos: {}, star: 1 },
    qb:       { label: "Quarterback first", pos: { QB: 1.7 }, star: 1 },
    air:      { label: "Air raid", pos: { QB: 1.3, WR: 1.35, TE: 1.15 }, star: 1 },
    ground:   { label: "Ground and pound", pos: { RB: 1.6, OL: 1.3 }, star: 1 },
    trenches: { label: "Win the trenches", pos: { OL: 1.35, DL: 1.35 }, star: 1 },
    defense:  { label: "Defense first", pos: { DL: 1.25, LB: 1.3, CB: 1.25, S: 1.3 }, star: 1 },
    stars:    { label: "Stars and scrubs", pos: {}, star: 2.4 },
    loyal:    { label: "Type loyalist", pos: {}, star: 1, typeBonus: 7 },
  };
  const STYLE_KEYS = Object.keys(AI_STYLES);
  const WEIGHT_POW = { QB: 1.93, RB: 1.17, WR: 1.09, TE: 1, OL: 0.94, DL: 1.03, LB: 0.94, CB: 1.06, S: 0.94 }; // POS_WEIGHT ^ 0.6

  // teams: [{roster}], taken: Set of pids. Returns {pid, slot}.
  // Value over replacement: how much better than the player who'd be left at that position once every open spot league-wide is filled.
  function aiChoose(pokemon, teams, teamIdx, taken, opts = {}) {
    const style = AI_STYLES[opts.style] || AI_STYLES.balanced;
    const rnd = opts.rng || Math.random;
    const avail = pokemon.filter(p => !taken.has(p.id));
    const team = teams[teamIdx];
    const open = SLOTS.filter(s => !team.roster[s.id]);
    const demand = {};
    for (const t of teams) for (const s of SLOTS) if (!t.roster[s.id]) demand[s.pos] = (demand[s.pos] || 0) + 1;
    const repl = {};
    for (const pos of POSITIONS) {
      if (!demand[pos]) continue;
      const sorted = avail.map(p => p.posOvr[pos]).sort((a, b) => b - a);
      repl[pos] = sorted[Math.min(sorted.length - 1, demand[pos])] || 40;
    }
    let best = null;
    const seenPos = new Set();
    for (const s of open) {
      if (seenPos.has(s.pos)) continue; seenPos.add(s.pos);
      const mult = (style.pos[s.pos] || 1) * WEIGHT_POW[s.pos];
      const base = starValue(repl[s.pos], style.star);
      for (const p of avail) {
        let v = (starValue(p.posOvr[s.pos], style.star) - base) * mult;
        if (style.typeBonus && opts.favType && p.types.includes(opts.favType)) v += style.typeBonus;
        v += (rnd() * 4 - 2);
        if (!best || v > best.v) best = { v, pid: p.id, slot: s.id };
      }
    }
    return best;
  }

  /* ---------- draft grades ---------- */
  const GROUPS = { QB: ["QB"], RB: ["RB"], WR: ["WR1","WR2","WR3"], TE: ["TE"], OL: ["LT","LG","C","RG","RT"], DL: ["LDE","LDT","RDT","RDE"], LB: ["WLB","MLB","SLB"], CB: ["CB1","CB2"], S: ["FS","SS"] };
  const GRADE_SCALE = [[1.5,"A+"],[1.0,"A"],[0.6,"A-"],[0.25,"B+"],[-0.15,"B"],[-0.5,"B-"],[-0.85,"C+"],[-1.2,"C"],[-1.6,"C-"],[-Infinity,"D"]];
  const letter = z => GRADE_SCALE.find(([t]) => z >= t)[1];

  function groupScores(roster, byId, chem) {
    chem = chem || chemistry(roster, byId);
    const out = {};
    for (const g of Object.keys(GROUPS)) {
      const vals = GROUPS[g].map(s => slotRating(roster, byId, chem, s));
      out[g] = vals.reduce((a, b) => a + b, 0) / vals.length;
    }
    out.TEAM = teamRating(roster, byId, chem).ovr;
    return out;
  }

  // norms: {n: {QB:[mean,sd], ..., TEAM:[mean,sd]}} from simulated drafts (js/norms.js)
  function grades(roster, byId, numTeams, norms) {
    const sizes = Object.keys(norms).map(Number).sort((a, b) => a - b);
    const size = sizes.filter(k => k <= numTeams).pop() || sizes[0];
    const N = norms[size];
    const sc = groupScores(roster, byId);
    const out = {};
    for (const g of [...Object.keys(GROUPS), "TEAM"]) {
      const [mu, sd] = N[g];
      const z = (sc[g] - mu) / (sd || 1);
      out[g] = { score: sc[g], z, grade: letter(z) };
    }
    return out;
  }

  /* ---------- game simulation ---------- */
  function buildSide(team, byId) {
    const chem = chemistry(team.roster, byId);
    const pl = {};
    for (const s of SLOTS) {
      const p = byId.get(team.roster[s.id]);
      const b = chem.bonus[s.id] || 0;
      const a = {}; for (const k of Object.keys(p.attrs)) a[k] = p.attrs[k] + b;
      pl[s.id] = { slot: s.id, pid: p.id, name: p.name, a };
    }
    const avg = (slots, f) => slots.reduce((t, s) => t + f(pl[s].a), 0) / slots.length;
    const OL = ["LT","LG","C","RG","RT"], DL = ["LDE","LDT","RDT","RDE"], LB = ["WLB","MLB","SLB"];
    return {
      name: team.name, pl,
      passBlock: avg(OL, a => 0.7 * a.BLK + 0.3 * a.STR) * 0.85 + (0.6 * pl.TE.a.BLK + 0.4 * pl.RB.a.BLK) * 0.15,
      runBlock: avg(OL, a => 0.55 * a.BLK + 0.45 * a.STR) * 0.85 + pl.TE.a.BLK * 0.15,
      passRush: avg(DL, a => 0.45 * a.STR + 0.35 * a.SPD + 0.2 * a.AGI) * 0.85 + avg(LB, a => 0.5 * a.SPD + 0.5 * a.STR) * 0.15,
      runStop: avg(DL, a => 0.5 * a.STR + 0.5 * a.TKL) * 0.55 + avg(LB, a => 0.6 * a.TKL + 0.4 * a.SPD) * 0.45,
    };
  }

  const rushSkill = a => 0.35 * a.SPD + 0.35 * a.AGI + 0.3 * a.STR;
  const routeSkill = a => 0.5 * a.CTH + 0.3 * a.SPD + 0.2 * a.AGI;
  const covSkill = a => 0.7 * a.COV + 0.3 * a.SPD;
  const clamp = (x, lo, hi) => x < lo ? lo : x > hi ? hi : x;
  // receiver -> who covers him
  const COVERS = { WR1: "CB1", WR2: "CB2", WR3: "FS", TE: "SS", RB: "MLB" };

  function newLine() { return { cmp: 0, att: 0, pyd: 0, ptd: 0, int: 0, sk: 0, car: 0, ryd: 0, rtd: 0, tgt: 0, rec: 0, recyd: 0, rectd: 0, tkl: 0, sacks: 0, dint: 0, ff: 0, long: 0 }; }

  function simGame(teamA, teamB, byId, seed, opts = {}) {
    const rnd = rngFrom(seed);
    const sides = [buildSide(teamA, byId), buildSide(teamB, byId)];
    const stats = [{}, {}];
    const L = (t, slot) => (stats[t][slot] = stats[t][slot] || newLine());
    const score = [0, 0];
    const quarterPts = [[0, 0, 0, 0], [0, 0, 0, 0]];
    const tstats = [0, 1].map(() => ({ plays: 0, ryd: 0, pyd: 0, firstDowns: 0, to: 0, sacked: 0 }));
    const scoring = [];
    const POSS = 10;

    function tackler(t, pool) { // weighted by tackling
      const d = sides[t].pl;
      const slots = pool.map(x => x[0]);
      const slot = rnd.weighted(slots, pool.map(([s, w]) => w * d[s].a.TKL));
      L(t, slot).tkl++;
      return slot;
    }
    const RUN_TACKLERS = [["LDE",.5],["LDT",.6],["RDT",.6],["RDE",.5],["WLB",1],["MLB",1.3],["SLB",1],["FS",.35],["SS",.45],["CB1",.15],["CB2",.15]];
    const LONG_TACKLERS = [["FS",1],["SS",1],["CB1",.6],["CB2",.6],["MLB",.3]];

    function drive(o, startPos, quarter) {
      const off = sides[o], def = sides[1 - o], d = 1 - o;
      let pos = startPos, down = 1, togo = 10, plays = 0;
      const qb = off.pl.QB;
      while (plays < 18) {
        plays++; tstats[o].plays++;
        const yardsToGoal = 100 - pos;
        // 4th down decisions
        if (down === 4) {
          const fgDist = yardsToGoal + 17;
          if (togo <= 1 && pos >= 45 && yardsToGoal > 2 && rnd() < 0.55) { /* go for it */ }
          else if (fgDist <= 55) {
            const pMake = clamp(0.98 - Math.max(0, fgDist - 30) * 0.018, 0.4, 0.98);
            if (rnd() < pMake) { score[o] += 3; quarterPts[o][quarter] += 3; scoring.push({ q: quarter + 1, team: o, text: `${fgDist}-yard field goal` }); return { next: 25 }; }
            return { next: clamp(100 - pos - 7, 20, 80), turnover: true };
          } else {
            const punt = Math.round(38 + rnd() * 12);
            let land = pos + punt; if (land >= 100) land = 80; // touchback -> opponent at own 20
            return { next: clamp(100 - land, 1, 99), punt: true };
          }
        }
        const passPower = (qb.a.THA + qb.a.THP) / 2;
        const runPower = (rushSkill(off.pl.RB.a) + off.runBlock) / 2;
        let runRate = clamp(0.45 + 0.008 * (runPower - passPower) + 0.004 * (def.passRush - off.passBlock), 0.28, 0.62);
        if (down === 3 && togo >= 6) runRate = 0.12;
        if (down >= 3 && togo <= 2) runRate = 0.6;
        let gain = 0, turnover = false, event = "";
        if (rnd() < runRate) {
          // run play
          const qbRun = rnd() < 0.05 + Math.max(0, qb.a.SPD - 75) * 0.004;
          const carrier = qbRun ? "QB" : "RB";
          const ra = off.pl[carrier].a;
          const adv = (rushSkill(ra) + off.runBlock) / 2 - def.runStop;
          gain = Math.round(3.9 + 0.12 * adv + rnd.normal() * 3.3);
          if (gain < -4) gain = -4;
          const breakChance = 0.022 + Math.max(0, ra.SPD + ra.AGI - 150) * 0.0011 + Math.max(0, adv) * 0.0007;
          if (rnd() < breakChance) gain += Math.round(10 + rnd() * 55);
          const line = L(o, carrier); line.car++;
          if (rnd() < 0.008) {
            const t = tackler(d, RUN_TACKLERS); L(d, t).ff++; turnover = true; event = "fumble";
            gain = Math.min(gain, yardsToGoal - 1); line.ryd += gain; tstats[o].ryd += gain;
          } else {
            if (gain >= yardsToGoal) { gain = yardsToGoal; line.rtd++; event = "td"; }
            else tackler(d, gain >= 15 ? LONG_TACKLERS : RUN_TACKLERS);
            line.ryd += gain; tstats[o].ryd += gain; if (gain > line.long) line.long = gain;
          }
          if (event === "td") scoring.push({ q: quarter + 1, team: o, text: `${off.pl[carrier].name} ${gain}-yard run` });
        } else {
          // pass play
          const ql = L(o, "QB");
          const sackP = clamp(0.06 + 0.0035 * (def.passRush - off.passBlock) - Math.max(0, qb.a.AGI - 80) * 0.001, 0.02, 0.15);
          if (rnd() < sackP) {
            const dl = ["LDE","LDT","RDT","RDE","WLB","SLB"];
            const sacker = rnd.weighted(dl, dl.map((s, i) => (i < 4 ? 1 : 0.35) * (def.pl[s].a.SPD + def.pl[s].a.STR)));
            gain = -Math.round(5 + rnd() * 5);
            if (pos + gain < 1) gain = 1 - pos;
            L(d, sacker).sacks++; L(d, sacker).tkl++; ql.sk++; tstats[o].sacked++;
            if (rnd() < 0.08) { L(d, sacker).ff++; turnover = true; event = "fumble"; }
          } else {
            const targets = ["WR1","WR2","WR3","TE","RB"];
            const base = [0.28, 0.22, 0.17, 0.17, 0.16];
            const tgt = rnd.weighted(targets, targets.map((s, i) => base[i] * (routeSkill(off.pl[s].a) - 30)));
            const ta = off.pl[tgt].a, cov = COVERS[tgt], ca = def.pl[cov].a;
            const matchup = routeSkill(ta) - covSkill(ca);
            const pComp = clamp(0.56 + 0.004 * (qb.a.THA - 75) + 0.003 * matchup - 0.002 * (def.passRush - off.passBlock), 0.35, 0.80);
            ql.att++; L(o, tgt).tgt++;
            if (rnd() < pComp) {
              const air = Math.max(0, Math.round((tgt === "RB" ? 0.5 : tgt === "TE" ? 5 : 6.5) + 0.06 * (qb.a.THP - 75) + rnd.normal() * 3.8));
              let yac = Math.max(0, Math.round(2.3 + 0.05 * ((ta.SPD + ta.AGI) / 2 - 70) + rnd.normal() * 2.2));
              if (rnd() < 0.012 + Math.max(0, ta.SPD - 75) * 0.0007) yac += Math.round(8 + rnd() * 40);
              gain = air + yac;
              ql.cmp++; L(o, tgt).rec++;
              if (gain >= yardsToGoal) { gain = yardsToGoal; ql.ptd++; L(o, tgt).rectd++; event = "td"; }
              else tackler(d, [[cov, 2.2], ["FS", .6], ["SS", .6], ["MLB", .5], ["WLB", .3], ["SLB", .3]]);
              ql.pyd += gain; L(o, tgt).recyd += gain; tstats[o].pyd += gain;
              if (gain > L(o, tgt).long) L(o, tgt).long = gain;
              if (event === "td") scoring.push({ q: quarter + 1, team: o, text: `${qb.name} ${gain}-yard pass to ${off.pl[tgt].name}` });
            } else {
              const pInt = clamp(0.075 + 0.003 * (covSkill(ca) - 75) - 0.003 * (qb.a.THA - 75), 0.025, 0.16);
              if (rnd() < pInt) { ql.int++; L(d, cov).dint++; turnover = true; event = "int"; gain = Math.round(air0()); }
              else gain = 0;
            }
          }
        }
        function air0() { return 6 + rnd() * 10; }
        if (turnover) {
          tstats[o].to++;
          const spot = clamp(pos + gain, 1, 99);
          return { next: clamp(100 - spot, 1, 99), turnover: true };
        }
        pos += gain;
        if (event === "td" || pos >= 100) { score[o] += 7; quarterPts[o][quarter] += 7; return { next: 25 }; }
        if (gain >= togo) { down = 1; togo = Math.min(10, 100 - pos); tstats[o].firstDowns++; }
        else { down++; togo -= gain; }
        if (pos < 1) pos = 1;
      }
      // turnover on downs / clock ran out
      return { next: clamp(100 - pos, 1, 99), turnover: true };
    }

    let o = rnd() < 0.5 ? 0 : 1, start = 25;
    const first = o;
    for (let i = 0; i < POSS * 2; i++) {
      const quarter = Math.min(3, Math.floor(i / (POSS / 2)));
      const r = drive(o, start, quarter);
      o = 1 - o; start = r.next;
    }
    let ot = 0;
    const maxOT = opts.noTies ? 12 : 2;
    while (score[0] === score[1] && ot < maxOT) {
      ot++;
      for (const t of [first, 1 - first]) drive(t, 25, 3);
    }
    if (score[0] === score[1] && opts.noTies) { const w = rnd() < 0.5 ? 0 : 1; score[w] += 3; scoring.push({ q: 5, team: w, text: "Overtime field goal" }); }

    const lines = [0, 1].map(t => Object.entries(stats[t]).map(([slot, s]) => ({ slot, pid: sides[t].pl[slot].pid, name: sides[t].pl[slot].name, ...s })));
    const winner = score[0] > score[1] ? 0 : score[1] > score[0] ? 1 : -1;
    const mvpSide = winner === -1 ? (fp(lines[0]) >= fp(lines[1]) ? 0 : 1) : winner;
    const mvp = lines[mvpSide].reduce((b, l) => (!b || fpts(l) > fpts(b) ? l : b), null);
    return { score, quarterPts, ot, lines, team: tstats, scoring, winner, mvp: mvp && { side: mvpSide, pid: mvp.pid, slot: mvp.slot, name: mvp.name } };
  }
  const fpts = l => l.pyd / 25 + l.ptd * 4 - l.int * 2 + l.ryd / 10 + l.rtd * 6 + l.rec * 0.5 + l.recyd / 10 + l.rectd * 6 + l.tkl * 0.6 + l.sacks * 3 + l.dint * 5 + l.ff * 2;
  const fp = lines => lines.reduce((t, l) => t + fpts(l), 0);

  /* ---------- season ---------- */
  function roundRobin(n) {
    const ids = [...Array(n).keys()]; if (n % 2) ids.push(-1);
    const m = ids.length, weeks = [];
    for (let w = 0; w < m - 1; w++) {
      const games = [];
      for (let i = 0; i < m / 2; i++) {
        const a = ids[i], b = ids[m - 1 - i];
        if (a !== -1 && b !== -1) games.push(w % 2 ? [b, a] : [a, b]);
      }
      weeks.push(games);
      ids.splice(1, 0, ids.pop());
    }
    return weeks;
  }

  /* ---------- conferences (8+ teams) ---------- */
  const CONF_NAMES = ["Indigo Conference", "Orange Conference"];
  const DIV_NAMES = [["Kanto", "Johto", "Hoenn", "Sinnoh"], ["Unova", "Kalos", "Alola", "Galar"]];
  const PLAYOFF_ROUND_NAMES = { wild: "Wild card round", div: "Divisional round", semi: "Conference semifinals", conf: "Conference championships", final: "Championship" };

  // 8-15 teams: two conferences; 16-23: two divisions each; 24-32: four divisions each (NFL-style).
  function leagueStructure(n) {
    if (n < 8) return null;
    const nd = n >= 24 ? 4 : n >= 16 ? 2 : 1;
    const conferences = [0, 1].map(c => ({ name: CONF_NAMES[c], divisions: [...Array(nd)].map((_, d) => ({ name: nd > 1 ? DIV_NAMES[c][d] : null, teams: [] })) }));
    for (let i = 0; i < n; i++) conferences[i % 2].divisions[Math.floor(i / 2) % nd].teams.push(i);
    const confOf = [], divOf = [];
    conferences.forEach((C, ci) => C.divisions.forEach((D, di) => D.teams.forEach(t => { confOf[t] = ci; divOf[t] = ci * 4 + di; })));
    return { conferences, confOf, divOf, hasDivisions: nd > 1, playoffPerConf: n >= 24 ? 6 : n >= 12 ? 4 : 2 };
  }

  // 10 weeks: each week pair everyone up, favoring opponents not yet played, then division and conference rivals.
  function conferenceSchedule(n, L, rnd, weeksCount = 10) {
    const met = {};
    const key = (a, b) => a < b ? a + "-" + b : b + "-" + a;
    const weeks = [];
    const byes = Array(n).fill(0);
    for (let w = 0; w < weeksCount; w++) {
      const order = [...Array(n).keys()];
      for (let i = order.length - 1; i > 0; i--) { const j = Math.floor(rnd() * (i + 1)); [order[i], order[j]] = [order[j], order[i]]; }
      const used = new Set(), games = [];
      if (n % 2) { // odd league: the bye goes to a team with the fewest byes so far
        const fewest = Math.min(...byes);
        const sitter = order.find(t => byes[t] === fewest);
        byes[sitter]++; used.add(sitter);
      }
      for (const t of order) {
        if (used.has(t)) continue;
        let best = null, bestScore = -Infinity;
        for (const u of order) {
          if (u === t || used.has(u)) continue;
          const times = met[key(t, u)] || 0;
          const score = -10 * times + (L.divOf[t] === L.divOf[u] ? 3 : L.confOf[t] === L.confOf[u] ? 2 : 0) + rnd() * 0.5;
          if (score > bestScore) { bestScore = score; best = u; }
        }
        if (best == null) continue; // odd team out has a bye
        used.add(t); used.add(best);
        met[key(t, best)] = (met[key(t, best)] || 0) + 1;
        games.push(rnd() < 0.5 ? [t, best] : [best, t]);
      }
      weeks.push(games);
    }
    return weeks;
  }

  // teams: [{name, roster}] (all full). Returns every game, standings, playoffs, leaders and awards.
  function simSeason(teams, byId, seed) {
    const n = teams.length;
    if (n >= 8) return simConferenceSeason(teams, byId, seed);
    let weeks = n === 2 ? [[[0, 1]], [[1, 0]], [[0, 1]]] : n === 3 ? roundRobin(3).concat(roundRobin(3).map(w => w.map(([a, b]) => [b, a]))) : roundRobin(n);
    const rec = teams.map(() => ({ w: 0, l: 0, t: 0, pf: 0, pa: 0 }));
    const season = { weeks: [], playoffs: [], champion: null };
    const totals = teams.map(() => ({}));
    const addStats = (t, lines) => { for (const l of lines) { const k = l.pid; const acc = totals[t][k] = totals[t][k] || { ...newLine(), pid: l.pid, name: l.name, slot: l.slot, team: t, gp: 0 }; acc.gp++; for (const f of Object.keys(newLine())) acc[f] = f === "long" ? Math.max(acc.long, l.long) : acc[f] + l[f]; } };
    const play = (a, b, label, noTies) => {
      const g = simGame(teams[a], teams[b], byId, `${seed}|${label}|${a}-${b}`, { noTies });
      g.a = a; g.b = b; g.label = label;
      addStats(a, g.lines[0]); addStats(b, g.lines[1]);
      return g;
    };
    weeks.forEach((games, wi) => {
      const out = games.map(([a, b]) => {
        const g = play(a, b, `Week ${wi + 1}`, n === 2);
        const [sa, sb] = g.score;
        rec[a].pf += sa; rec[a].pa += sb; rec[b].pf += sb; rec[b].pa += sa;
        if (sa > sb) { rec[a].w++; rec[b].l++; } else if (sb > sa) { rec[b].w++; rec[a].l++; } else { rec[a].t++; rec[b].t++; }
        return g;
      });
      season.weeks.push({ label: n === 2 ? `Game ${wi + 1}` : `Week ${wi + 1}`, games: out });
    });
    const tiebreak = i => hashStr(`${seed}|tb|${i}`);
    const order = [...Array(n).keys()].sort((x, y) =>
      (rec[y].w + rec[y].t / 2) - (rec[x].w + rec[x].t / 2) || (rec[y].pf - rec[y].pa) - (rec[x].pf - rec[x].pa) || rec[y].pf - rec[x].pf || tiebreak(x) - tiebreak(y));
    season.standings = order.map(i => ({ team: i, ...rec[i] }));
    if (n === 2) {
      season.champion = rec[0].w > rec[1].w ? 0 : rec[1].w > rec[0].w ? 1 : order[0];
    } else if (n >= 5) {
      const s1 = play(order[0], order[3], "Semifinal", true), s2 = play(order[1], order[2], "Semifinal", true);
      const w1 = s1.winner === 0 ? s1.a : s1.b, w2 = s2.winner === 0 ? s2.a : s2.b;
      const f = play(w1, w2, "Championship", true);
      season.playoffs = [{ label: "Semifinals", games: [s1, s2] }, { label: "Championship", games: [f] }];
      season.champion = f.winner === 0 ? f.a : f.b;
    } else {
      const f = play(order[0], order[1], "Championship", true);
      season.playoffs = [{ label: "Championship", games: [f] }];
      season.champion = f.winner === 0 ? f.a : f.b;
    }
    return finishSeason(season, totals, rec);
  }

  function finishSeason(season, totals, rec) {
    // leaders and MVP across the whole season (playoffs included)
    const all = totals.flatMap(t => Object.values(t));
    const top = (f, k = 5) => all.filter(x => x[f] > 0).sort((a, b) => b[f] - a[f] || a.pid - b.pid).slice(0, k);
    season.leaders = { passing: top("pyd"), rushing: top("ryd"), receiving: top("recyd"), sacks: top("sacks"), interceptions: top("dint"), tackles: top("tkl") };
    const mvp = all.slice().sort((a, b) => (fpts(b) * (1 + 0.08 * (rec[b.team].w))) - (fpts(a) * (1 + 0.08 * (rec[a.team].w))) || a.pid - b.pid)[0];
    const dpoy = all.slice().sort((a, b) => (b.sacks * 3 + b.dint * 4 + b.ff * 2 + b.tkl * 0.5) - (a.sacks * 3 + a.dint * 4 + a.ff * 2 + a.tkl * 0.5) || a.pid - b.pid)[0];
    season.awards = { mvp, dpoy };
    season.totals = totals;
    return season;
  }

  function simConferenceSeason(teams, byId, seed) {
    const n = teams.length;
    const L = leagueStructure(n);
    const weeks = n === 8 ? roundRobin(8) : conferenceSchedule(n, L, rngFrom(`${seed}|schedule`));
    const rec = teams.map(() => ({ w: 0, l: 0, t: 0, pf: 0, pa: 0 }));
    const season = { weeks: [], playoffs: [], champion: null, structure: L };
    const totals = teams.map(() => ({}));
    const addStats = (t, lines) => { for (const l of lines) { const acc = totals[t][l.pid] = totals[t][l.pid] || { ...newLine(), pid: l.pid, name: l.name, slot: l.slot, team: t, gp: 0 }; acc.gp++; for (const f of Object.keys(newLine())) acc[f] = f === "long" ? Math.max(acc.long, l.long) : acc[f] + l[f]; } };
    const play = (a, b, label, noTies) => {
      const g = simGame(teams[a], teams[b], byId, `${seed}|${label}|${a}-${b}`, { noTies });
      g.a = a; g.b = b; g.label = label;
      addStats(a, g.lines[0]); addStats(b, g.lines[1]);
      return g;
    };
    const winnerOf = g => g.winner === 0 ? g.a : g.b;
    weeks.forEach((games, wi) => {
      const out = games.map(([a, b]) => {
        const g = play(a, b, `Week ${wi + 1}`, false);
        const [sa, sb] = g.score;
        rec[a].pf += sa; rec[a].pa += sb; rec[b].pf += sb; rec[b].pa += sa;
        if (sa > sb) { rec[a].w++; rec[b].l++; } else if (sb > sa) { rec[b].w++; rec[a].l++; } else { rec[a].t++; rec[b].t++; }
        return g;
      });
      season.weeks.push({ label: `Week ${wi + 1}`, games: out });
    });
    const tiebreak = i => hashStr(`${seed}|tb|${i}`);
    const cmp = (x, y) => (rec[y].w + rec[y].t / 2) - (rec[x].w + rec[x].t / 2) || (rec[y].pf - rec[y].pa) - (rec[x].pf - rec[x].pa) || rec[y].pf - rec[x].pf || tiebreak(x) - tiebreak(y);
    season.standings = [...Array(n).keys()].sort(cmp).map(i => ({ team: i, ...rec[i] }));

    // seeds per conference: division winners first, then the best remaining records
    const P = L.playoffPerConf;
    season.seeds = L.conferences.map(C => {
      const winners = C.divisions.length > 1 ? C.divisions.map(D => D.teams.slice().sort(cmp)[0]).sort(cmp) : [];
      const rest = C.divisions.flatMap(D => D.teams).filter(t => !winners.includes(t)).sort(cmp);
      return [...winners, ...rest].slice(0, P);
    });
    const R = PLAYOFF_ROUND_NAMES;
    const champs = [];
    const roundGames = { };
    const push = (label, g) => { (roundGames[label] = roundGames[label] || []).push(g); };
    // each conference bracket is decided round by round, both conferences in the same round
    let alive = season.seeds.map(s => s.slice());
    if (P === 6) {
      alive = alive.map(s => {
        const g1 = play(s[2], s[5], R.wild, true), g2 = play(s[3], s[4], R.wild, true);
        push(R.wild, g1); push(R.wild, g2);
        return [s[0], s[1], winnerOf(g1), winnerOf(g2)].sort((a, b) => season.seeds.flat().indexOf(a) - season.seeds.flat().indexOf(b));
      });
      alive = alive.map(s => {
        const g1 = play(s[0], s[3], R.div, true), g2 = play(s[1], s[2], R.div, true);
        push(R.div, g1); push(R.div, g2);
        return [winnerOf(g1), winnerOf(g2)];
      });
    } else if (P === 4) {
      alive = alive.map(s => {
        const g1 = play(s[0], s[3], R.semi, true), g2 = play(s[1], s[2], R.semi, true);
        push(R.semi, g1); push(R.semi, g2);
        return [winnerOf(g1), winnerOf(g2)];
      });
    }
    alive.forEach(s => { const g = play(s[0], s[1], R.conf, true); push(R.conf, g); champs.push(winnerOf(g)); });
    const f = play(champs[0], champs[1], R.final, true);
    push(R.final, f);
    season.playoffs = [R.wild, R.div, R.semi, R.conf, R.final].filter(l => roundGames[l]).map(l => ({ label: l, games: roundGames[l] }));
    season.champion = winnerOf(f);
    return finishSeason(season, totals, rec);
  }

  return {
    SLOTS, SHARE_ORDER, SLOT_BY_ID, POSITIONS, POS_NAMES, GROUP_NAMES, GROUPS, ROUNDS, POS_WEIGHT,
    AI_STYLES, STYLE_KEYS, starValue, hashStr, rngFrom, chemistry, slotRating, teamRating,
    aiChoose, groupScores, grades, letter, simGame, simSeason, leagueStructure, fpts,
  };
});
