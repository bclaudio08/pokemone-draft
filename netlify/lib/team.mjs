// Shared helpers for the link-preview functions: decode a shared team from the URL and summarize it.
import E from "../../js/engine.js";
import gen1 from "../../data/pokemon.json";
import all from "../../data/pokemon-all.json";

// each draft pool has its own ratings; shared links say which one with p=all
const POOLS = { gen1: new Map(gen1.pokemon.map(p => [p.id, p])), all: new Map(all.pokemon.map(p => [p.id, p])) };
export const poolFor = searchParams => POOLS[searchParams.get("p") === "all" ? "all" : "gen1"];
export { E };

export function decodeTeam(searchParams) {
  const BY_ID = poolFor(searchParams);
  const r = searchParams.get("r") || "";
  if (r.length !== E.SHARE_ORDER.length * 2) return null;
  const roster = {};
  for (let i = 0; i < E.SHARE_ORDER.length; i++) {
    const id = parseInt(r.slice(i * 2, i * 2 + 2), 36);
    if (BY_ID.has(id)) roster[E.SHARE_ORDER[i]] = id;
  }
  if (Object.keys(roster).length !== E.SHARE_ORDER.length) return null;
  const g = searchParams.get("g"), rec = searchParams.get("rec");
  return {
    name: (searchParams.get("n") || "Gridiron 151 team").slice(0, 40),
    roster, byId: BY_ID,
    grade: g && /^[A-D][+-]?$/.test(g) ? g : null,
    rec: rec && /^\d{1,2}-\d{1,2}(-\d{1,2})?$/.test(rec) ? rec : null,
    champ: searchParams.get("c") === "1",
  };
}

export function summary(team) {
  const r = E.teamRating(team.roster, team.byId);
  const status = team.champ ? `League champions${team.rec ? ` at ${team.rec}` : ""}` : team.rec ? `Record ${team.rec}` : "";
  return { rating: r, status };
}

export const esc = s => String(s).replace(/[&<>"']/g, c => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
