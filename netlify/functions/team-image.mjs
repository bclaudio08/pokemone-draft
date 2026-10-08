// /team-image?n=...&r=... : 1200x630 PNG for link previews, showing the team's formation, rating, grade and record.
// Renderer (resvg, WebAssembly) and fonts are loaded from the site's own /assets/og/ folder, so nothing needs installing.
import { initWasm, Resvg } from "../lib/resvg.mjs";
import { decodeTeam, summary, esc, E } from "../lib/team.mjs";

let assets = null;
const sprites = new Map();

async function load(origin, path) {
  const res = await fetch(origin + path);
  if (!res.ok) throw new Error(`Couldn't load ${path}: ${res.status}`);
  return new Uint8Array(await res.arrayBuffer());
}

function getAssets(origin) {
  if (!assets) {
    assets = (async () => {
      const [wasm, black, xbold, body] = await Promise.all([
        load(origin, "/assets/og/resvg.wasm"),
        load(origin, "/assets/og/BigShouldersDisplay_900Black.ttf"),
        load(origin, "/assets/og/BigShouldersDisplay_800ExtraBold.ttf"),
        load(origin, "/assets/og/Barlow_600SemiBold.ttf"),
      ]);
      await initWasm(wasm);
      return { fonts: [black, xbold, body] };
    })().catch(e => { assets = null; throw e; });
  }
  return assets;
}

async function sprite(origin, id) {
  if (!sprites.has(id)) {
    const p = load(origin, `/sprites/${String(id).padStart(3, "0")}.png`)
      .then(b => "data:image/png;base64," + Buffer.from(b).toString("base64"))
      .catch(() => null);
    sprites.set(id, p);
  }
  return sprites.get(id);
}

const W = 1200, H = 630;
const TURF = "#1E5B3B", TURF2 = "#236843", CHALK = "#F2F4EC", FLAG = "#F2C200", INK = "#1A2230";

async function render(team, origin) {
  const { fonts } = await getAssets(origin);
  const { rating, status } = summary(team);
  const BY_ID = team.byId;
  const chem = E.chemistry(team.roster, BY_ID);

  // field on the right, same formation as the app
  const fx = 712, fy = 28, fw = 460, fh = 574;
  const stripes = [...Array(8).keys()].map(i =>
    `<rect x="${fx}" y="${fy + i * fh / 8}" width="${fw}" height="${fh / 8}" fill="${i % 2 ? TURF2 : TURF}"/>`).join("");
  const chips = (await Promise.all(E.SLOTS.map(async s => {
    const p = BY_ID.get(team.roster[s.id]);
    const v = p.posOvr[s.pos] + (chem.bonus[s.id] || 0);
    const cx = fx + fw * s.x / 100, cy = fy + fh * s.y / 100;
    const img = await sprite(origin, p.id);
    const size = 62;
    const elite = v >= 90;
    return `${img ? `<image href="${img}" x="${cx - size / 2}" y="${cy - size / 2 - 8}" width="${size}" height="${size}" style="image-rendering:pixelated" image-rendering="optimizeSpeed"/>` : ""}
      <rect x="${cx - 17}" y="${cy + 14}" width="34" height="20" rx="3" fill="${elite ? FLAG : INK}"/>
      <text x="${cx}" y="${cy + 30}" text-anchor="middle" font-family="Big Shoulders Display" font-weight="800" font-size="17" fill="${elite ? INK : "#FFFFFF"}">${v}</text>`;
  }))).join("");

  // name sized to fit the left column
  // Big Shoulders runs about 0.4em per character; wrap to two lines when one line would get too small
  const fit = s => Math.min(112, Math.floor(590 / (Math.max(6, s.length) * 0.5)));
  let lines = [team.name];
  if (fit(team.name) < 70 && team.name.includes(" ")) {
    const mid = team.name.length / 2;
    let cut = -1;
    for (let i = 0; i < team.name.length; i++) if (team.name[i] === " " && (cut < 0 || Math.abs(i - mid) < Math.abs(cut - mid))) cut = i;
    lines = [team.name.slice(0, cut), team.name.slice(cut + 1)];
  }
  const nameSize = Math.max(40, Math.min(lines.length > 1 ? 84 : 112, ...lines.map(fit)));
  const bigNum = (x, value, label, color) => `
    <text x="${x}" y="500" font-family="Big Shoulders Display" font-weight="900" font-size="150" fill="${color}">${esc(value)}</text>
    <text x="${x + 4}" y="538" font-family="Barlow" font-weight="600" font-size="24" fill="${CHALK}" fill-opacity="0.8">${label}</text>`;

  const svg = `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">
    <rect width="${W}" height="${H}" fill="${INK}"/>
    <text x="60" y="84" font-family="Big Shoulders Display" font-weight="900" font-size="44" fill="${CHALK}">Gridiron <tspan fill="${FLAG}">151</tspan></text>
    ${lines.map((ln, i) => `<text x="60" y="${(lines.length > 1 ? 180 : 210) + nameSize * 0.35 + i * nameSize * 0.95}" font-family="Big Shoulders Display" font-weight="900" font-size="${nameSize}" fill="${CHALK}">${esc(ln)}</text>`).join("")}
    ${status ? `<text x="62" y="${(lines.length > 1 ? 180 : 210) + nameSize * 0.35 + (lines.length - 1) * nameSize * 0.95 + 58}" font-family="Barlow" font-weight="600" font-size="32" fill="${FLAG}">${esc(status)}</text>` : ""}
    ${bigNum(60, String(rating.ovr), "Team rating", CHALK)}
    ${team.grade ? bigNum(300, team.grade, "Draft grade", FLAG) : ""}
    <text x="62" y="596" font-family="Barlow" font-weight="600" font-size="22" fill="${CHALK}" fill-opacity="0.65">Draft Pokémon onto a football team and play the season.</text>
    <rect x="${fx - 4}" y="${fy - 4}" width="${fw + 8}" height="${fh + 8}" rx="12" fill="${CHALK}"/>
    <clipPath id="f"><rect x="${fx}" y="${fy}" width="${fw}" height="${fh}" rx="9"/></clipPath>
    <g clip-path="url(#f)">${stripes}<rect x="${fx}" y="${fy + fh / 2 - 2}" width="${fw}" height="4" fill="${FLAG}"/></g>
    ${chips}
  </svg>`;

  const r = new Resvg(svg, {
    fitTo: { mode: "width", value: W },
    font: { fontBuffers: fonts, defaultFontFamily: "Barlow" },
  });
  return r.render().asPng();
}

export default async (req) => {
  const url = new URL(req.url);
  const team = decodeTeam(url.searchParams);
  if (!team) return Response.redirect(`${url.origin}/og.png`, 302);
  try {
    const png = await render(team, url.origin);
    return new Response(png, {
      headers: {
        "content-type": "image/png",
        "cache-control": "public, max-age=86400",
        "netlify-cdn-cache-control": "public, durable, max-age=31536000, immutable",
      },
    });
  } catch (e) {
    console.error(e);
    return Response.redirect(`${url.origin}/og.png`, 302);
  }
};

export const config = { path: "/team-image" };
