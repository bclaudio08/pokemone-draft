// /team?n=...&r=... : a tiny page whose link-preview tags describe this specific team, then forwards people to the app.
import { decodeTeam, summary, esc } from "../lib/team.mjs";

export default async (req) => {
  const url = new URL(req.url);
  if (url.searchParams.has("probe")) {
    return new Response("ok", { headers: { "x-g151": "1", "cache-control": "no-store" } });
  }
  const team = decodeTeam(url.searchParams);
  const appUrl = `${url.origin}/${url.search}`;
  if (!team) return Response.redirect(`${url.origin}/`, 302);

  const { rating, status } = summary(team);
  const title = `${team.name} | Gridiron 151`;
  const desc = [status, `Team rating ${rating.ovr}`, team.grade ? `draft grade ${team.grade}` : null].filter(Boolean).join(", ")
    + ". Draft Pokémon onto a football team and play the season.";
  const image = `${url.origin}/team-image${url.search}`;

  const html = `<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<title>${esc(title)}</title>
<meta name="description" content="${esc(desc)}">
<meta property="og:type" content="website">
<meta property="og:site_name" content="Gridiron 151">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(desc)}">
<meta property="og:url" content="${esc(url.href)}">
<meta property="og:image" content="${esc(image)}">
<meta property="og:image:width" content="1200">
<meta property="og:image:height" content="630">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${esc(title)}">
<meta name="twitter:description" content="${esc(desc)}">
<meta name="twitter:image" content="${esc(image)}">
<meta http-equiv="refresh" content="0; url=${esc(appUrl)}">
<link rel="canonical" href="${esc(appUrl)}">
</head><body>
<p><a href="${esc(appUrl)}">Open ${esc(team.name)} on Gridiron 151</a></p>
<script>location.replace(${JSON.stringify(appUrl)});</script>
</body></html>`;
  return new Response(html, {
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "public, max-age=300", "x-g151": "1" },
  });
};

export const config = { path: "/team" };
