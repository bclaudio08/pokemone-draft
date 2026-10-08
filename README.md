# Gridiron 151

A Pokémon football draft. Each team drafts 22 of the original 151 Pokémon (11 offense, 11 defense) in a snake draft, then shares its roster with a link.

- **Draft rooms:** the host picks 2–6 teams and a pick timer, then sends a link. Friends join from their own devices and draft live. Unclaimed seats become AI teams.
- **Practice vs AI:** a 2–6 team draft that runs entirely in the browser.
- **Two Pokémon pools:** the Original 150 (Mewtwo excluded) or all 1,024 Pokémon with a sprite. Both use the same rating formulas, each scaled against its own pool.
- **Season:** after the draft, every team plays a simulated season (play it week by week or all at once), then playoffs. Every snap is simulated, so a strong line and running back produce big rushing days. You get box scores, standings, league leaders, MVP and defensive player of the year. Every device gets the same results for the same league.
- **Draft grades** by position group, plus each team's best-value pick and biggest reach.
- **Chemistry:** bonuses for same-type units, quarterback–receiver type connections and evolution families.
- **Per-team link previews:** shared links show that team's formation, rating, grade and record.

Plain HTML/CSS/JS with no build step. Draft rooms use Supabase (database plus live updates).

## One-time Supabase setup

1. In your Supabase project, enable **Authentication → Sign In / Providers → Allow anonymous sign-ins**.
2. Open **SQL Editor → New query**, paste all of `supabase/setup.sql`, and click **Run**.
3. `js/config.js` holds the project URL and publishable key.

If you change ratings later, run `python3 scripts/build_data.py`, `node scripts/build_norms.js` and `python3 scripts/build_sql.py`, then re-run `supabase/setup.sql`. Re-running is safe and doesn't touch existing rooms.

## Deploy to Netlify

Use a **Git-connected deploy** (or the Netlify CLI) so the two small functions in `netlify/functions/` run; they create each team's link preview. A drag-and-drop deploy still works, but shared links then fall back to the generic preview image. The app detects which applies on its own.


**Drag and drop:** go to app.netlify.com → Add new site → Deploy manually, and drop this whole folder in.

**From Git:** push this folder to a GitHub repo, then Add new site → Import from Git. Leave the build command empty and set the publish directory to `.` (`netlify.toml` already does this).

After the first deploy, change `og:image` in `index.html` to the full URL (for example `https://your-site.netlify.app/og.png`). Some social platforms ignore relative image URLs in link previews.

## Run locally

```
python3 -m http.server 8000
```
Then open http://localhost:8000. Opening `index.html` directly also works.

## Files

| Path | What it is |
|---|---|
| `index.html`, `css/`, `js/app.js` | The app |
| `js/data.js`, `data/pokemon.json` | Generated ratings for the Original 150 pool |
| `js/data-all.js`, `data/pokemon-all.json` | Generated ratings for the All Pokémon pool (loaded only when that pool is picked) |
| `data/source_all.csv` | Base stats etc. for #1–1025 (PokeAPI open data) |
| `data/source_gen1.csv` | Base stats, types, height, weight, evolution stage for #1–151 (PokeAPI open data) |
| `scripts/build_data.py` | Turns the source CSV into ratings. Rerun after changing any formula |
| `sprites/001.png`–`1025.png` | Sprites from github.com/PokeAPI/sprites |
| `og.png` | Social preview image |
| `js/net.js`, `js/config.js`, `js/vendor/supabase.js` | Draft-room connection (Supabase client v2.45.4, bundled) |
| `supabase/schema.sql` | Database tables, security rules and draft functions |
| `supabase/setup.sql` | `schema.sql` plus ratings: the file you run in Supabase |
| `scripts/build_sql.py` | Regenerates `setup.sql` from the current ratings |
| `js/engine.js` | Chemistry, team rating, AI drafting styles, draft grades and the game simulator (shared by the app, the functions and the scripts) |
| `js/norms.js`, `scripts/build_norms.js` | Draft-grade baselines and average draft positions from 1,500 simulated drafts. Rerun `node scripts/build_norms.js` after changing ratings or the engine |
| `netlify/functions/team.mjs` | `/team?...` share page with that team's preview tags |
| `netlify/functions/team-image.mjs`, `netlify/lib/`, `assets/og/` | `/team-image?...` 1200×630 preview image (resvg + fonts loaded from `assets/og/`) |

## Changing ratings

Edit the weights at the top of `scripts/build_data.py`, then run `python3 scripts/build_data.py`. That regenerates `js/data.js` and `data/pokemon.json`.

- `ATTR_FORMULAS`: how base stats, weight and height become the 10 attributes
- `POSITION_WEIGHTS`: which attributes matter at each position
- `TALENT_WEIGHT`: share of every position rating that comes from base stat total (default 30%)
- `STAR_OVR` and `QUOTAS`: how each Pokémon's natural position is assigned

## Share links

A team is encoded in the URL: `?n=<team name>&r=<22 two-character base-36 IDs>`, in a fixed slot order (`SHARE_ORDER` in `app.js`). Don't reorder that list, or old links will break.

## How draft rooms stay fair

All writes go through database functions. Players can't write to the tables directly.
- `g151_make_pick` checks that it's your turn, that the Pokémon is still available, and that the roster spot is open. It locks the room row, so two simultaneous picks can't both succeed.
- `g151_tick` makes AI picks and auto-picks when a pick clock expires. Every open browser calls it when it's due; the lock means only one call counts.
- Room links: `?room=CODE` (re-opens your seat) and `?join=CODE` (invite).
