/* Gridiron 151 — Pokémon football draft and season. Practice against AI locally, or draft live in a shared room. */
(() => {
  "use strict";

  /* Draft pools: "gen1" (Original 150, always loaded) and "all" (every Pokemon with a sprite, loaded on demand).
     The rest of the app reads the active pool through these variables; usePool() switches them. */
  const POOL_FILES = { all: { file: "js/data-all.js", global: "POKEDATA_ALL" } };
  const POOL_DATA = {};
  let POOL = "gen1", meta, POKEMON, BY_ID, TYPES;
  function registerPool(key, payload) {
    const byId = new Map(payload.pokemon.map(p => [p.id, p]));
    POOL_DATA[key] = { meta: payload.meta, pokemon: payload.pokemon, byId, types: [...new Set(payload.pokemon.flatMap(p => p.types))].sort() };
  }
  function usePool(key) {
    const d = POOL_DATA[key] || POOL_DATA.gen1;
    POOL = POOL_DATA[key] ? key : "gen1";
    meta = d.meta; POKEMON = d.pokemon; BY_ID = d.byId; TYPES = d.types;
  }
  const poolLoads = {};
  function ensurePool(key) {
    if (POOL_DATA[key] || !POOL_FILES[key]) return Promise.resolve();
    if (!poolLoads[key]) poolLoads[key] = new Promise((resolve, reject) => {
      const s = document.createElement("script");
      s.src = POOL_FILES[key].file;
      s.onload = () => { registerPool(key, window[POOL_FILES[key].global]); resolve(); };
      s.onerror = () => { delete poolLoads[key]; reject(new Error("Couldn't load the Pokémon list. Check your connection and try again.")); };
      document.head.appendChild(s);
    });
    return poolLoads[key];
  }
  const poolKey = v => v === "all" ? "all" : "gen1";
  const poolLabel = key => key === "all" ? `All Pokémon` : "Original 150";
  const ALL_COUNT = ((window.G151_NORMS || {}).all || {}).count || 1024; // pool size, shown before the big list loads
  registerPool("gen1", window.POKEDATA);
  usePool("gen1");
  const Net = window.G151Net;

  const SOLO_TEAMS = 6;
  const AI_DELAY = 420;

  const E = window.G151Engine;
  const normsFor = () => (window.G151_NORMS || {})[POOL] || { norms: {}, adp: {} };
  const { SLOTS, SHARE_ORDER, SLOT_BY_ID, ROUNDS, POSITIONS, POS_NAMES, GROUP_NAMES, AI_STYLES, STYLE_KEYS } = E;
  const ATTRS = Object.keys(meta.attrNames);
  const TYPE_COLORS = {
    normal:"#A8A77A", fire:"#EE8130", water:"#6390F0", electric:"#F7D02C", grass:"#7AC74C", ice:"#96D9D6",
    fighting:"#C22E28", poison:"#A33EA1", ground:"#E2BF65", flying:"#A98FF3", psychic:"#F95587", bug:"#A6B91A",
    rock:"#B6A136", ghost:"#735797", dragon:"#6F35FC", dark:"#705746", steel:"#B7B7CE", fairy:"#D685AD",
  };
  const AI_NAMES = ["Pewter Boulders","Cerulean Surge","Vermilion Voltage","Celadon Thorns","Saffron Minds","Cinnabar Blaze","Fuchsia Venom","Lavender Haunts","Viridian Rangers"];

  const $ = (sel, root = document) => root.querySelector(sel);
  const app = $("#app");
  const esc = s => String(s ?? "").replace(/[&<>"']/g, c => ({ "&":"&amp;","<":"&lt;",">":"&gt;",'"':"&quot;","'":"&#39;" }[c]));
  const pad = n => String(n).padStart(3, "0");
  const store = {
    get(k) { try { return JSON.parse(localStorage.getItem(k)); } catch { return null; } },
    set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch {} },
    del(k) { try { localStorage.removeItem(k); } catch {} },
  };

  /* ---------- shared rendering ---------- */

  function sprite(p, cls = "") {
    const t = p.types[0];
    return `<span class="sprite ${cls}" style="--type:${TYPE_COLORS[t]}">
      <img src="sprites/${pad(p.id)}.png" alt="${esc(p.name)}" loading="lazy" decoding="async"
        onerror="this.remove()"><b aria-hidden="true">${esc(p.name[0])}</b></span>`;
  }
  const typeChips = p => p.types.map(t => `<span class="type" style="--type:${TYPE_COLORS[t]}">${t}</span>`).join("");
  const ovrClass = v => v >= 90 ? "elite" : v >= 80 ? "good" : v >= 70 ? "ok" : "low";

  function playerCard(p, opts = {}) {
    const attrs = ATTRS.map(a => `
      <div class="attr"><span>${meta.attrNames[a]}</span>
        <span class="bar"><i style="width:${(p.attrs[a] - 40) / 59 * 100}%"></i></span>
        <b class="${ovrClass(p.attrs[a])}">${p.attrs[a]}</b></div>`).join("");
    const posRow = POSITIONS.map(pos => `
      <div class="pr ${pos === p.pos ? "is-primary" : ""}"><span>${pos}</span><b class="${ovrClass(p.posOvr[pos])}">${p.posOvr[pos]}</b></div>`).join("");
    return `
    <article class="pcard" style="--type:${TYPE_COLORS[p.types[0]]};--type2:${TYPE_COLORS[p.types[1] || p.types[0]]}">
      <div class="pcard-top">
        <div class="pcard-ovr"><b>${p.ovr}</b><span>${p.pos}</span></div>
        ${sprite(p, "lg")}
        <div class="pcard-no">#${pad(p.id)}</div>
      </div>
      <div class="pcard-id">
        <h3>${esc(p.name)}</h3>
        <div class="pcard-sub">${typeChips(p)}<span class="hw">${p.height}, ${p.weightLb} lb</span></div>
        <p class="pcard-pos">Natural ${POS_NAMES[p.pos].toLowerCase()}${p.legendary ? `<span class="legend">Legendary</span>` : ""}</p>
      </div>
      <div class="attrs">${attrs}</div>
      <div class="posrow" aria-label="Rating at each position">${posRow}</div>
      ${opts.footer || ""}
    </article>`;
  }

  function field(roster, opts = {}) {
    const chem = E.chemistry(roster, BY_ID);
    const chips = SLOTS.map(s => {
      const p = roster[s.id] ? BY_ID.get(roster[s.id]) : null;
      const style = `left:${s.x}%;top:${s.y}%`;
      if (!p) {
        const tag = opts.interactive ? "button" : "div";
        return `<${tag} class="chip empty ${opts.focusPos === s.pos ? "hint" : ""}" style="${style}" data-slot="${s.id}" ${opts.interactive ? `type="button" aria-label="Show best available ${POS_NAMES[s.pos]}"` : ""}>${s.label}</${tag}>`;
      }
      const b = chem.bonus[s.id] || 0;
      const v = p.posOvr[s.pos] + b;
      return `<button class="chip ${s.side}" type="button" style="${style}" data-pid="${p.id}" aria-label="${esc(p.name)}, ${s.label} ${v}${b ? `, includes +${b} chemistry` : ""}">
        ${sprite(p)}<span class="chip-ovr ${ovrClass(v)} ${b ? "chem" : ""}">${v}</span>${opts.names ? `<span class="chip-name">${esc(p.name)}</span>` : ""}</button>`;
    }).join("");
    return `<div class="field ${opts.big ? "big" : ""}">
      <span class="side-label top">Defense</span><span class="side-label bottom">Offense</span>
      <div class="los"></div>
      ${chips}</div>`;
  }

  const teamRatings = roster => E.teamRating(roster, BY_ID);

  function chemList(roster, opts = {}) {
    const { badges } = E.chemistry(roster, BY_ID);
    if (!badges.length) return opts.empty ? `<p class="fine">No chemistry yet. Players who share a type in the same unit, receivers who share a type with the quarterback, and evolution families all earn bonuses.</p>` : "";
    return `<ul class="chem-list">${badges.map(b => `<li class="chem-${b.kind}"><b>${esc(b.title)}</b><span>${esc(b.text)}</span></li>`).join("")}</ul>`;
  }

  /* ---------- draft state ----------
     S is the same shape for practice and online drafts:
     { mode, teams:[{name, ai, roster}], user, pick, order, taken, log, done, ...online fields } */

  let S = null;
  let ui = freshUI();
  let aiTimer = null;
  function freshUI() { return { pos: "BEST", type: "", q: "", natural: false, selected: null, tab: "pool", home: "create", rtab: "season" }; }

  // snake reverses the order every other round; linear keeps the same order every round
  const teamOnClock = (pick, st = S) => {
    const n = st.order.length, round = Math.floor(pick / n), i = pick % n;
    if (st.orderType === "linear") return st.order[i];
    return round % 2 === 0 ? st.order[i] : st.order[n - 1 - i];
  };
  const openSlots = team => SLOTS.filter(s => !team.roster[s.id]);
  const isTaken = id => S.taken.includes(id);
  const totalPicks = () => S.teams.length * ROUNDS;

  function bestSlotFor(team, p) {
    let best = null;
    for (const s of openSlots(team)) if (!best || p.posOvr[s.pos] > p.posOvr[best.pos]) best = s;
    return best;
  }

  /* ----- practice (local) ----- */

  function newPractice(teamName, slot, numTeams, orderType, pool) {
    usePool(poolKey(pool));
    const n = Math.min(6, Math.max(2, Number(numTeams) || SOLO_TEAMS));
    const names = [...AI_NAMES].sort(() => Math.random() - 0.5);
    const user = slot === "random" || Number(slot) > n ? Math.floor(Math.random() * n) : Number(slot) - 1;
    const teams = Array.from({ length: n }, (_, i) => ({
      name: i === user ? (teamName.trim() || "My team") : names.pop(), ai: i !== user, roster: {},
      style: i === user ? null : STYLE_KEYS[Math.floor(Math.random() * STYLE_KEYS.length)],
      fav: TYPES[Math.floor(Math.random() * TYPES.length)],
    }));
    S = { mode: "solo", pool: POOL, teams, user, pick: 0, order: teams.map((_, i) => i), taken: [], log: [], done: false,
          orderType: orderType === "linear" ? "linear" : "snake",
          seasonSeed: Math.random().toString(36).slice(2, 10) };
    saveSolo();
  }
  const saveSolo = () => S && S.mode === "solo" && store.set("g151-draft", S);
  // A saved practice draft from an older version may include Pokemon that are no longer in the pool. Drop it.
  function loadSolo() {
    const saved = store.get("g151-draft");
    if (!saved) return null;
    const pk = poolKey(saved.pool);
    if (!POOL_DATA[pk]) return null; // big pool not loaded yet; boot loads it first when needed
    usePool(pk);
    const ok = saved.mode === "solo" && Array.isArray(saved.teams) && Array.isArray(saved.order)
      && saved.teams.every(t => t && t.roster && Object.values(t.roster).every(id => BY_ID.has(id)))
      && (saved.taken || []).every(id => BY_ID.has(id));
    if (!ok) { store.del("g151-draft"); return null; }
    return saved;
  }
  const rosterComplete = t => SLOTS.every(s => BY_ID.has(t.roster[s.id]));

  function localPick(teamIdx, pid, slotId) {
    S.teams[teamIdx].roster[slotId] = pid;
    S.taken.push(pid);
    S.log.push({ pick: S.pick, team: teamIdx, pid, slot: slotId });
    S.pick++;
    if (S.pick >= totalPicks()) S.done = true;
    saveSolo();
  }

  // AI pick: value over replacement, shaped by each AI team's drafting style (js/engine.js)
  function aiPick(teamIdx) {
    const t = S.teams[teamIdx];
    const c = E.aiChoose(POKEMON, S.teams, teamIdx, new Set(S.taken), { style: t.style, favType: t.fav });
    localPick(teamIdx, c.pid, c.slot);
  }

  function runAI() {
    clearTimeout(aiTimer);
    if (!S || S.mode !== "solo" || S.done) return render();
    const t = teamOnClock(S.pick);
    if (!S.teams[t].ai) return render();
    render();
    aiTimer = setTimeout(() => { aiPick(t); runAI(); }, AI_DELAY);
  }

  /* ----- online rooms ----- */

  const online = { code: null, unsub: null, poll: null, tickTimer: null, clock: null, sig: "", busy: false };

  function fromSnapshot(snap) {
    const r = snap.room;
    const teams = snap.seats.map(s => ({ name: s.team_name || "Open seat", ai: s.is_ai, claimed: s.claimed, roster: {}, style: s.style }));
    for (const p of snap.picks) teams[p.seat].roster[p.slot] = p.pid;
    const mine = snap.seats.find(s => s.mine);
    return {
      mode: "online", code: r.code, roomId: r.id, isHost: r.is_host, status: r.status,
      pickSeconds: r.pick_seconds, deadline: r.deadline ? Date.parse(r.deadline) : null,
      offset: Date.parse(snap.now) - Date.now(),
      teams, user: mine ? mine.seat : -1, pick: r.pick, order: r.draft_order || [],
      taken: snap.picks.map(p => p.pid),
      log: snap.picks.map(p => ({ pick: p.pick_no, team: p.seat, pid: p.pid, slot: p.slot, auto: p.auto })),
      done: r.status === "done", seasonSeed: r.id, orderType: r.draft_type || "snake", pool: poolKey(r.pool),
    };
  }

  async function openRoom(code) {
    leaveRoom();
    online.code = code.toUpperCase();
    history.replaceState(null, "", "?room=" + online.code);
    await refreshRoom(true);
    if (!S || S.mode !== "online") return;
    online.unsub = Net.subscribe(S.roomId, () => { clearTimeout(online.deb); online.deb = setTimeout(refreshRoom, 120); });
    online.poll = setInterval(refreshRoom, 4000);
    online.clock = setInterval(updateClock, 250);
  }

  function leaveRoom() {
    online.unsub && online.unsub();
    clearInterval(online.poll); clearInterval(online.clock); clearTimeout(online.tickTimer);
    Object.assign(online, { code: null, unsub: null, poll: null, clock: null, tickTimer: null, sig: "" });
  }

  async function refreshRoom(force) {
    if (!online.code || online.busy) return;
    online.busy = true;
    let snap;
    try { snap = await Net.rpc("g151_get_room", { p_code: online.code }); }
    catch (e) { online.busy = false; if (force) roomError(e.message); return; }
    online.busy = false;
    if (!snap || !snap.room) { const c = online.code; leaveRoom(); return roomError(`No room with code ${c}. Check the code and try again.`); }
    try { await ensurePool(poolKey(snap.room.pool)); } catch (e) { if (force) roomError(e.message); return; }
    usePool(poolKey(snap.room.pool));
    const next = fromSnapshot(snap);
    const sig = [next.status, next.pick, snap.seats.map(s => `${s.team_name}|${s.claimed}|${s.is_ai}`).join(",")].join(";");
    const changed = force || sig !== online.sig;
    if (S && S.mode === "online" && S.pick !== next.pick && S.log.length) announce(next);
    S = next; online.sig = sig;
    if (changed) render();
    scheduleTick();
  }

  function announce(next) {
    const last = next.log[next.log.length - 1];
    if (!last || last.team === next.user) return;
    const p = BY_ID.get(last.pid);
    if (teamOnClock(next.pick, next) === next.user && next.status === "drafting") toast(`${next.teams[last.team].name} took ${p.name}. You're up.`);
  }

  // If an AI team is up or the clock ran out, ask the server to make that pick.
  function scheduleTick() {
    clearTimeout(online.tickTimer);
    if (!S || S.mode !== "online" || S.status !== "drafting") return;
    const seat = teamOnClock(S.pick);
    const now = Date.now() + S.offset;
    let wait = null;
    if (S.teams[seat].ai) wait = 1000 + Math.random() * 300;
    else if (S.deadline) wait = Math.max(0, S.deadline - now) + 400 + Math.random() * 300;
    if (wait == null) return;
    online.tickTimer = setTimeout(async () => {
      try { if (await Net.rpc("g151_tick", { p_code: S.code })) refreshRoom(); else setTimeout(refreshRoom, 600); }
      catch { setTimeout(refreshRoom, 1500); }
    }, wait);
  }

  function updateClock() {
    const el = $("#clock");
    if (!el || !S || S.mode !== "online" || !S.deadline || S.status !== "drafting") return;
    const left = Math.max(0, Math.ceil((S.deadline - (Date.now() + S.offset)) / 1000));
    el.textContent = `0:${String(left).padStart(2, "0")}`;
    el.classList.toggle("low", left <= 10);
  }

  async function roomCall(fn, args, okMsg) {
    try { const r = await Net.rpc(fn, args); if (okMsg) toast(okMsg); return r; }
    catch (e) { toast(e.message, true); throw e; }
  }

  function roomError(msg) {
    S = null;
    history.replaceState(null, "", location.pathname);
    ui.home = "join";
    renderHome(msg);
  }

  /* ---------- share links ---------- */

  function encodeTeam(team, extra = {}) {
    const ids = SHARE_ORDER.map(id => (team.roster[id] || 0).toString(36).padStart(2, "0")).join("");
    let q = `?n=${encodeURIComponent(team.name)}&r=${ids}`;
    if (POOL !== "gen1") q += `&p=${POOL}`;
    if (extra.g) q += `&g=${encodeURIComponent(extra.g)}`;
    if (extra.rec) q += `&rec=${encodeURIComponent(extra.rec)}`;
    if (extra.c) q += `&c=1`;
    return q;
  }
  function decodeTeam(params) {
    const r = params.get("r") || "";
    if (r.length !== SHARE_ORDER.length * 2) return null;
    const roster = {};
    for (let i = 0; i < SHARE_ORDER.length; i++) {
      const id = parseInt(r.slice(i * 2, i * 2 + 2), 36);
      if (BY_ID.has(id)) roster[SHARE_ORDER[i]] = id;
    }
    const g = params.get("g"), rec = params.get("rec");
    return {
      name: (params.get("n") || "Shared team").slice(0, 40), roster,
      grade: g && /^[A-D][+-]?$/.test(g) ? g : null,
      rec: rec && /^\d{1,2}-\d{1,2}(-\d{1,2})?$/.test(rec) ? rec : null,
      champ: params.get("c") === "1",
    };
  }
  const baseUrl = () => location.origin + location.pathname;

  // Netlify functions give each shared team its own link preview. Fall back to plain links without them.
  let prettyLinks = null;
  async function hasPrettyLinks() {
    if (prettyLinks != null) return prettyLinks;
    if (location.protocol === "file:") return (prettyLinks = false);
    try {
      const ctl = new AbortController(); const t = setTimeout(() => ctl.abort(), 2000);
      const res = await fetch(new URL("team?probe=1", baseUrl()), { signal: ctl.signal, cache: "no-store" });
      clearTimeout(t);
      prettyLinks = res.ok && res.headers.get("x-g151") === "1";
    } catch { prettyLinks = false; }
    return prettyLinks;
  }

  async function shareLink(url, text, copiedMsg) {
    if (navigator.share && matchMedia("(pointer: coarse)").matches) {
      try { await navigator.share({ title: "Gridiron 151", text, url }); return; } catch {}
    }
    try { await navigator.clipboard.writeText(url); toast(copiedMsg); }
    catch { prompt("Copy this link:", url); }
  }
  async function shareTeam(team, extra = {}) {
    const r = teamRatings(team.roster);
    const q = encodeTeam(team, extra);
    const url = (await hasPrettyLinks()) ? new URL("team" + q, baseUrl()).href : baseUrl() + q;
    const brag = extra.c ? `League champions at ${extra.rec}. ` : extra.rec ? `Went ${extra.rec}. ` : "";
    shareLink(url, `${team.name}: ${brag}${r.ovr} team rating${extra.g ? `, draft grade ${extra.g}` : ""} on Gridiron 151. Think you can out-draft me?`, "Team link copied");
  }

  /* ---------- screens ---------- */

  function setTicker(html) { $("#ticker").innerHTML = html; }
  const lastName = () => store.get("g151-name") || "";

  function renderHome(errorMsg) {
    const saved = loadSolo();
    const resume = saved && saved.mode === "solo" && !saved.done && saved.pick > 0;
    const qs = new URLSearchParams(location.search);
    const roomFromUrl = (qs.get("join") || qs.get("room") || "").toUpperCase();
    setTicker("");
    app.className = "screen-setup";
    const seg = (name, values, checked, fmt = v => v) =>
      `<div class="seg">${values.map(v => `<label><input type="radio" name="${name}" value="${v}" ${String(v) === String(checked) ? "checked" : ""}><span>${fmt(v)}</span></label>`).join("")}</div>`;
    const modes = { create: "Start a room", join: "Join a room", solo: "Practice vs AI" };
    if (!Net.available && ui.home !== "solo") ui.home = "solo";
    app.innerHTML = `
      <section class="setup">
        <div class="setup-copy">
          <h1>Draft Pokémon onto a football team.</h1>
          <p class="lede">Each team drafts 22 Pokémon: 11 on offense, 11 on defense. Start a room and send the link to friends, or practice against AI.</p>
          <p class="fine">Every Pokémon is rated at all nine positions from its real base stats, height and weight, so a great quarterback might be a decent running back.</p>
          <div class="modes" role="tablist" aria-label="How do you want to draft?">
            ${Object.entries(modes).map(([k, v]) => `<button type="button" role="tab" data-home="${k}" aria-selected="${ui.home === k}" ${!Net.available && k !== "solo" ? "disabled" : ""}>${v}</button>`).join("")}
          </div>
          ${errorMsg ? `<p class="form-error" role="alert">${esc(errorMsg)}</p>` : ""}
          ${ui.home === "create" ? `
          <form id="createForm" class="setup-form">
            <label>Your team name<input name="name" maxlength="28" placeholder="Pallet Town Pros" value="${esc(lastName())}" autocomplete="off" required></label>
            <fieldset><legend>Number of teams</legend>${seg("teams", [2,3,4,5,6], 4)}</fieldset>
            <fieldset><legend>Time per pick</legend>${seg("timer", [0,30,60,90], 60, v => v ? v + " sec" : "No limit")}</fieldset>
            <fieldset><legend>Pokémon pool</legend>${seg("pool", ["gen1","all"], store.get("g151-pool") || "gen1", v => v === "gen1" ? "Original 150" : `All Pokémon (${ALL_COUNT.toLocaleString()})`)}</fieldset>
            <fieldset><legend>Draft order</legend>${seg("order", ["snake","linear"], store.get("g151-order") || "snake", v => v === "snake" ? "Snake" : "Same every round")}</fieldset>
            <p class="fine">Snake reverses the order every round, so the team that picks last in round 1 picks first in round 2. Same every round keeps one order all draft.</p>
            <p class="fine">Seats nobody claims become AI teams when you start the draft.</p>
            <button class="btn primary" type="submit">Create room</button>
          </form>` : ""}
          ${ui.home === "join" ? `
          <form id="joinForm" class="setup-form">
            <label>Room code<input name="code" maxlength="4" placeholder="K7Q2" value="${esc(roomFromUrl)}" autocomplete="off" autocapitalize="characters" required class="code-input"></label>
            <label>Your team name<input name="name" maxlength="28" placeholder="Pallet Town Pros" value="${esc(lastName())}" autocomplete="off" required></label>
            <button class="btn primary" type="submit">Join room</button>
          </form>` : ""}
          ${ui.home === "solo" ? `
          <form id="soloForm" class="setup-form">
            <label>Team name<input name="name" maxlength="28" placeholder="Pallet Town Pros" value="${esc(lastName())}" autocomplete="off" required></label>
            <fieldset><legend>Number of teams</legend>${seg("teams", [2,3,4,5,6], store.get("g151-solo-teams") || 6)}</fieldset>
            <fieldset><legend>Pokémon pool</legend>${seg("pool", ["gen1","all"], store.get("g151-pool") || "gen1", v => v === "gen1" ? "Original 150" : `All Pokémon (${ALL_COUNT.toLocaleString()})`)}</fieldset>
            <fieldset><legend>Draft order</legend>${seg("order", ["snake","linear"], store.get("g151-order") || "snake", v => v === "snake" ? "Snake" : "Same every round")}</fieldset>
            <fieldset><legend>Your draft slot</legend><div id="slotSeg"></div></fieldset>
            <button class="btn primary" type="submit">Start practice draft</button>
            ${resume ? `<button class="btn ghost" type="button" id="resumeBtn">Resume ${esc(saved.teams[saved.user].name)} (pick ${saved.pick + 1})</button>` : ""}
          </form>` : ""}
        </div>
        <div class="setup-field">${field({}, { big: true })}</div>
      </section>`;

    app.querySelectorAll("[data-home]").forEach(b => b.onclick = () => { ui.home = b.dataset.home; renderHome(); });
    const busy = (form, on) => { const b = form.querySelector("[type=submit]"); b.disabled = on; b.textContent = on ? "Connecting…" : b.dataset.label || b.textContent; };
    $("#createForm")?.addEventListener("submit", async e => {
      e.preventDefault();
      const fd = new FormData(e.target); store.set("g151-name", fd.get("name"));
      const btn = e.target.querySelector("[type=submit]"); btn.dataset.label = btn.textContent; busy(e.target, true);
      try {
        store.set("g151-order", fd.get("order"));
        store.set("g151-pool", fd.get("pool"));
        const code = await roomCall("g151_create_room", { p_num_teams: +fd.get("teams"), p_pick_seconds: +fd.get("timer"), p_team_name: fd.get("name"), p_draft_type: fd.get("order"), p_pool: poolKey(fd.get("pool")) });
        ui = freshUI(); await openRoom(code);
      } catch { busy(e.target, false); }
    });
    $("#joinForm")?.addEventListener("submit", async e => {
      e.preventDefault();
      const fd = new FormData(e.target); store.set("g151-name", fd.get("name"));
      const code = String(fd.get("code")).trim().toUpperCase();
      const btn = e.target.querySelector("[type=submit]"); btn.dataset.label = btn.textContent; busy(e.target, true);
      try { await roomCall("g151_join_room", { p_code: code, p_team_name: fd.get("name") }); ui = freshUI(); await openRoom(code); }
      catch { busy(e.target, false); }
    });
    const soloForm = $("#soloForm");
    if (soloForm) {
      const drawSlots = () => {
        const n = +new FormData(soloForm).get("teams");
        const cur = soloForm.querySelector("input[name=slot]:checked")?.value || "random";
        const keep = cur === "random" || +cur <= n ? cur : "random";
        $("#slotSeg").outerHTML = `<div id="slotSeg">${seg("slot", [...Array(n).keys()].map(i => i + 1).concat("random"), keep, v => v === "random" ? "Random" : v)}</div>`;
      };
      drawSlots();
      soloForm.querySelectorAll("input[name=teams]").forEach(r => r.addEventListener("change", drawSlots));
    }
    soloForm?.addEventListener("submit", async e => {
      e.preventDefault();
      const fd = new FormData(e.target); store.set("g151-name", fd.get("name")); store.set("g151-solo-teams", +fd.get("teams"));
      store.set("g151-order", fd.get("order")); store.set("g151-pool", fd.get("pool"));
      const btn = e.target.querySelector("[type=submit]");
      btn.disabled = true; btn.textContent = "Loading Pokémon…";
      try { await ensurePool(poolKey(fd.get("pool"))); }
      catch (err) { toast(err.message, true); btn.disabled = false; btn.textContent = "Start practice draft"; return; }
      newPractice(fd.get("name"), fd.get("slot"), fd.get("teams"), fd.get("order"), fd.get("pool"));
      ui = freshUI(); runAI();
    });
    $("#resumeBtn")?.addEventListener("click", () => { usePool(poolKey(saved.pool)); S = saved; ui = freshUI(); runAI(); });
  }

  function renderLobby() {
    const n = S.teams.length;
    const filled = S.teams.filter(t => t.claimed).length;
    const host = S.teams[0];
    setTicker(`<span class="tk-round">Room ${esc(S.code)}</span><span class="tk-clock">Waiting to start</span>`);
    app.className = "screen-lobby";
    app.innerHTML = `
      <section class="lobby">
        <div>
          <h1>Room <span class="room-code">${esc(S.code)}</span></h1>
          <p class="lede">Send this link to the people drafting with you. They pick a team name and take an open seat.</p>
          <div class="share-row">
            <button class="btn primary" type="button" id="inviteBtn">Copy invite link</button>
            ${S.isHost ? `<button class="btn ghost" type="button" id="startBtn">Start draft (${filled} of ${n} seats filled)</button>` : ""}
          </div>
          <p class="fine">${S.isHost
            ? (filled < n ? `${n - filled} open ${n - filled === 1 ? "seat becomes an AI team" : "seats become AI teams"} when you start. ` : "") + `${poolLabel(S.pool)}. ${S.orderType === "linear" ? "Same order every round" : "Snake draft"}, with the order randomized at the start. ${S.pickSeconds ? `Each pick has ${S.pickSeconds} seconds; when time runs out, the best available player is picked automatically.` : "There's no pick timer."}`
            : `Waiting for ${esc(host.name)} to start the draft. ${poolLabel(S.pool)}. ${S.orderType === "linear" ? "Same order every round. " : "Snake draft. "}${S.pickSeconds ? `Each pick has ${S.pickSeconds} seconds.` : ""}`}</p>
        </div>
        <ol class="seats">
          ${S.teams.map((t, i) => `<li class="${i === S.user ? "mine" : ""} ${t.claimed ? "" : "open"}">
            <span class="rk">${i + 1}</span>
            <span>${t.claimed ? esc(t.name) : "Open seat"}${i === 0 ? ` <small>host</small>` : ""}${i === S.user ? ` <small>you</small>` : ""}</span>
          </li>`).join("")}
        </ol>
      </section>`;
    $("#inviteBtn").onclick = () => shareLink(`${baseUrl()}?join=${S.code}`, `Join my Gridiron 151 draft. Room code ${S.code}.`, "Invite link copied");
    $("#startBtn")?.addEventListener("click", async e => {
      e.target.disabled = true;
      try { await roomCall("g151_start_room", { p_code: S.code }); refreshRoom(true); } catch { e.target.disabled = false; }
    });
  }

  function poolList() {
    const me = S.teams[S.user];
    const openPos = [...new Set(openSlots(me).map(s => s.pos))];
    const useful = openPos.length ? openPos : POSITIONS;
    const q = ui.q.trim().toLowerCase();
    return POKEMON.filter(p => !isTaken(p.id)
        && (!ui.type || p.types.includes(ui.type))
        && (!q || p.name.toLowerCase().includes(q) || String(p.id) === q)
        && (!ui.natural || ui.pos === "BEST" || p.pos === ui.pos))
      .map(p => {
        const at = ui.pos === "BEST" ? useful.reduce((a, pos) => p.posOvr[pos] > p.posOvr[a] ? pos : a, useful[0]) : ui.pos;
        return { p, at, v: p.posOvr[at] };
      })
      .sort((a, b) => b.v - a.v || a.p.id - b.p.id);
  }

  function renderDraft() {
    const me = S.teams[S.user];
    const onClock = teamOnClock(S.pick);
    const myTurn = onClock === S.user;
    const round = Math.floor(S.pick / S.teams.length) + 1;
    const r = teamRatings(me.roster);
    const clock = S.mode === "online" && S.deadline ? `<span class="tk-timer" id="clock"></span>` : "";
    setTicker(`<span class="tk-round">${S.mode === "online" ? `Room ${esc(S.code)}, round` : "Round"} ${round} of ${ROUNDS}</span>
      <span class="tk-clock ${myTurn ? "mine" : ""}">${myTurn ? "Your pick" : `${esc(S.teams[onClock].name)} picking…`}</span>${clock}`);

    const rows = poolList();
    const sel = ui.selected && !isTaken(ui.selected) ? BY_ID.get(ui.selected) : (rows[0] && rows[0].p);
    const recent = S.log.slice(-8).reverse();
    const upNext = [1, 2, 3].map(k => S.pick + k < totalPicks() ? teamOnClock(S.pick + k) : null).filter(x => x != null);
    const picksUntilMe = (() => { for (let k = 0; S.pick + k < totalPicks(); k++) if (teamOnClock(S.pick + k) === S.user) return k; return null; })();

    app.className = "screen-draft tab-" + ui.tab;
    app.innerHTML = `
      <nav class="tabs" aria-label="Draft views">
        ${["pool","card","team"].map(t => `<button type="button" data-tab="${t}" aria-pressed="${ui.tab === t}">${{pool:"Players",card:"Card",team:"My team"}[t]}</button>`).join("")}
      </nav>
      <section class="pool panel" aria-label="Available players">
        <div class="filters">
          <input type="search" id="q" placeholder="Search name or number" value="${esc(ui.q)}" aria-label="Search">
          <select id="posSel" aria-label="Rate players at position">
            <option value="BEST" ${ui.pos === "BEST" ? "selected" : ""}>Best fit for my open spots</option>
            ${POSITIONS.map(p => `<option value="${p}" ${ui.pos === p ? "selected" : ""}>Rated at ${POS_NAMES[p].toLowerCase()}</option>`).join("")}
          </select>
          <select id="typeSel" aria-label="Filter by type">
            <option value="">All types</option>
            ${TYPES.map(t => `<option value="${t}" ${ui.type === t ? "selected" : ""}>${t[0].toUpperCase() + t.slice(1)}</option>`).join("")}
          </select>
          ${ui.pos !== "BEST" ? `<label class="check"><input type="checkbox" id="natural" ${ui.natural ? "checked" : ""}> Natural ${ui.pos}s only</label>` : ""}
        </div>
        <ol class="plist">
          ${rows.slice(0, ui.q.trim() ? 400 : 200).map(({ p, v, at }) => `
            <li><button type="button" class="prow ${sel && sel.id === p.id ? "is-sel" : ""}" data-pid="${p.id}">
              ${sprite(p, "sm")}
              <span class="prow-name">${esc(p.name)}<small>${p.types.join(" / ")}, natural ${p.pos}</small></span>
              <span class="prow-at">${at}</span>
              <b class="prow-v ${ovrClass(v)}">${v}</b>
            </button></li>`).join("") || `<li class="empty-list">No available Pokémon match. Clear the search or type filter.</li>`}
          ${rows.length > (ui.q.trim() ? 400 : 200) ? `<li class="empty-list">Showing the top ${ui.q.trim() ? 400 : 200} of ${rows.length}. Search or filter by type to find others.</li>` : ""}
        </ol>
      </section>
      <section class="card-col panel" aria-label="Selected player">
        ${sel ? playerCard(sel, { footer: draftActions(sel, myTurn, picksUntilMe) }) : ""}
      </section>
      <section class="team-col" aria-label="My team">
        <div class="team-head">
          <h2>${esc(me.name)}</h2>
          <div class="team-nums"><span>Team <b>${r.ovr || "—"}</b></span><span>Off <b>${r.off || "—"}</b></span><span>Def <b>${r.def || "—"}</b></span></div>
        </div>
        ${field(me.roster, { interactive: true, focusPos: sel ? bestSlotFor(me, sel)?.pos : null })}
        ${upNext.length ? `<p class="up-next">Up next: ${upNext.map(i => i === S.user ? "<b>you</b>" : esc(S.teams[i].name)).join(", ")}</p>` : ""}
        ${chemList(me.roster)}
        <div class="log">
          <h3>Recent picks</h3>
          <ol>${recent.map(l => {
            const p = BY_ID.get(l.pid);
            return `<li class="${l.team === S.user ? "mine" : ""}"><span class="log-no">${l.pick + 1}</span>${sprite(p, "xs")}<span>${esc(p.name)}<small>${esc(S.teams[l.team].name)}, ${SLOT_BY_ID[l.slot].label}${l.auto && !S.teams[l.team].ai ? ", auto-picked" : ""}</small></span><b>${p.posOvr[SLOT_BY_ID[l.slot].pos]}</b></li>`;
          }).join("") || `<li class="muted">No picks yet.</li>`}</ol>
        </div>
      </section>`;
    bindDraft();
    updateClock();
  }

  function draftActions(p, myTurn, picksUntilMe) {
    const me = S.teams[S.user];
    const open = openSlots(me);
    const best = bestSlotFor(me, p);
    if (!best) return "";
    const seen = new Set(); const opts = [];
    [...open].sort((a, b) => p.posOvr[b.pos] - p.posOvr[a.pos]).forEach(s => { if (!seen.has(s.pos)) { seen.add(s.pos); opts.push(s); } });
    if (!myTurn) {
      const when = picksUntilMe == null ? "" : picksUntilMe === 1 ? " You pick next." : ` You pick in ${picksUntilMe} picks.`;
      return `<div class="actions"><p class="wait">Waiting for ${esc(S.teams[teamOnClock(S.pick)].name)}.${when}</p></div>`;
    }
    const before = E.chemistry(me.roster, BY_ID);
    const after = E.chemistry({ ...me.roster, [best.id]: p.id }, BY_ID);
    const sum = c => Object.values(c.bonus).reduce((a, b) => a + b, 0);
    const gain = sum(after) - sum(before);
    const newBadges = after.badges.filter(b => !before.badges.some(x => x.title === b.title && x.slots.length === b.slots.length));
    const chemNote = gain > 0 ? `<p class="chem-note">Adds +${gain} chemistry${newBadges.length ? `: ${newBadges.map(b => esc(b.title)).join(", ")}` : ""}</p>` : "";
    return `<div class="actions">
      ${chemNote}
      <button class="btn primary" type="button" data-draft="${p.id}" data-slot="${best.id}">Draft at ${best.label} (${p.posOvr[best.pos]})</button>
      ${opts.length > 1 ? `<div class="alt-slots">or play at ${opts.filter(s => s.id !== best.id).map(s =>
        `<button type="button" class="pill" data-draft="${p.id}" data-slot="${s.id}">${s.label} ${p.posOvr[s.pos]}</button>`).join("")}</div>` : ""}
    </div>`;
  }

  function bindDraft() {
    app.querySelectorAll("[data-tab]").forEach(b => b.onclick = () => { ui.tab = b.dataset.tab; render(); });
    const q = $("#q");
    q.oninput = () => { ui.q = q.value; render(); };
    $("#posSel").onchange = e => { ui.pos = e.target.value; ui.selected = null; render(); };
    $("#typeSel").onchange = e => { ui.type = e.target.value; ui.selected = null; render(); };
    $("#natural")?.addEventListener("change", e => { ui.natural = e.target.checked; render(); });
    app.querySelectorAll(".prow").forEach(b => b.onclick = () => {
      ui.selected = +b.dataset.pid;
      if (matchMedia("(max-width: 900px)").matches) ui.tab = "card";
      render();
    });
    app.querySelectorAll("[data-draft]").forEach(b => b.onclick = async () => {
      if (teamOnClock(S.pick) !== S.user) return;
      const p = BY_ID.get(+b.dataset.draft), slot = b.dataset.slot;
      if (S.mode === "solo") {
        localPick(S.user, p.id, slot);
        toast(`Drafted ${p.name} at ${SLOT_BY_ID[slot].label}`);
        ui.selected = null; ui.tab = "pool";
        return runAI();
      }
      app.querySelectorAll("[data-draft]").forEach(x => x.disabled = true);
      try {
        await roomCall("g151_make_pick", { p_code: S.code, p_pid: p.id, p_slot: slot }, `Drafted ${p.name} at ${SLOT_BY_ID[slot].label}`);
        ui.selected = null; ui.tab = "pool";
      } catch {}
      refreshRoom(true);
    });
    app.querySelectorAll(".field .chip.empty[data-slot]").forEach(b => b.onclick = () => {
      ui.pos = SLOT_BY_ID[b.dataset.slot].pos; ui.selected = null; ui.tab = "pool"; render();
    });
    app.querySelectorAll(".field .chip[data-pid]").forEach(b => b.onclick = () => openCard(+b.dataset.pid));
  }

  /* ---------- season ---------- */

  const seasonCache = {};
  const leagueKey = () => S.mode === "online" ? "room-" + S.roomId : "solo-" + (S.seasonSeed || "legacy");
  function getSeason() {
    if (!S.teams.every(rosterComplete)) throw new Error("This league has a roster with a Pokémon that's no longer in the game, so its season can't be played.");
    const k = leagueKey();
    if (!seasonCache[k]) seasonCache[k] = E.simSeason(S.teams.map(t => ({ name: t.name, roster: t.roster })), BY_ID, S.seasonSeed || k);
    return seasonCache[k];
  }
  const allRounds = season => [...season.weeks, ...season.playoffs];
  const progKey = () => "g151-prog-" + leagueKey();
  const getProg = () => +(store.get(progKey()) || 0);
  const setProg = n => store.set(progKey(), n);
  const recStr = x => `${x.w}-${x.l}${x.t ? "-" + x.t : ""}`;
  const STAT_FIELDS = ["cmp","att","pyd","ptd","int","sk","car","ryd","rtd","tgt","rec","recyd","rectd","tkl","sacks","dint","ff"];

  function standingsFrom(season, weeks) {
    const rec = S.teams.map((_, i) => ({ team: i, w: 0, l: 0, t: 0, pf: 0, pa: 0 }));
    season.weeks.slice(0, weeks).forEach(w => w.games.forEach(g => {
      const [sa, sb] = g.score;
      rec[g.a].pf += sa; rec[g.a].pa += sb; rec[g.b].pf += sb; rec[g.b].pa += sa;
      if (sa > sb) { rec[g.a].w++; rec[g.b].l++; } else if (sb > sa) { rec[g.b].w++; rec[g.a].l++; } else { rec[g.a].t++; rec[g.b].t++; }
    }));
    return rec.sort((x, y) => (y.w + y.t / 2) - (x.w + x.t / 2) || (y.pf - y.pa) - (x.pf - x.pa) || y.pf - x.pf || x.team - y.team);
  }

  function aggregate(games) {
    const acc = {};
    for (const g of games) for (let s = 0; s < 2; s++) {
      const team = s === 0 ? g.a : g.b;
      for (const l of g.lines[s]) {
        const k = team + ":" + l.pid;
        const a = acc[k] = acc[k] || { team, pid: l.pid, slot: l.slot, name: l.name, gp: 0, ...Object.fromEntries(STAT_FIELDS.map(f => [f, 0])) };
        a.gp++; for (const f of STAT_FIELDS) a[f] += l[f];
      }
    }
    return Object.values(acc);
  }

  function statLine(l) {
    const parts = [];
    if (l.att) parts.push(`${l.cmp}/${l.att}, ${l.pyd} yds, ${l.ptd} TD${l.int ? `, ${l.int} INT` : ""}`);
    if (l.car) parts.push(`${l.car} car, ${l.ryd} yds${l.rtd ? `, ${l.rtd} TD` : ""}`);
    if (l.rec) parts.push(`${l.rec} rec, ${l.recyd} yds${l.rectd ? `, ${l.rectd} TD` : ""}`);
    const d = [l.tkl && `${l.tkl} tkl`, l.sacks && `${l.sacks} ${l.sacks === 1 ? "sack" : "sacks"}`, l.dint && `${l.dint} INT`, l.ff && `${l.ff} FF`].filter(Boolean);
    if (d.length) parts.push(d.join(", "));
    return parts.join("; ");
  }

  function nextLabel(rd, n) {
    if (rd.label === "Semifinals") return "Play the semifinals";
    if (rd.label === "Championship") return "Play the championship";
    return "Play " + rd.label.toLowerCase();
  }

  function gameCard(g, ri, gi) {
    const t = [S.teams[g.a], S.teams[g.b]];
    const mine = g.a === S.user || g.b === S.user;
    const row = s => `<span class="g-row ${g.winner === s ? "won" : ""}"><span>${esc(t[s].name)}</span><b>${g.score[s]}</b></span>`;
    const mvpLine = g.mvp ? g.lines[g.mvp.side].find(l => l.pid === g.mvp.pid) : null;
    return `<button type="button" class="game ${mine ? "mine" : ""}" data-game="${ri}:${gi}" aria-label="Box score: ${esc(t[0].name)} ${g.score[0]}, ${esc(t[1].name)} ${g.score[1]}">
      ${row(0)}${row(1)}
      <small>${g.ot ? "Overtime. " : ""}${g.winner === -1 ? "Tie. " : ""}${mvpLine ? `Player of the game: ${esc(mvpLine.name)}, ${statLine(mvpLine)}` : ""}</small>
    </button>`;
  }

  function leaderBlock(title, rows, f, unit) {
    if (!rows.length) return "";
    return `<div class="leader"><h4>${title}</h4><ol>${rows.map(l => {
      const p = BY_ID.get(l.pid);
      return `<li class="${l.team === S.user ? "mine" : ""}">${sprite(p, "xs")}<span>${esc(l.name)}<small>${esc(S.teams[l.team].name)}</small></span><b>${l[f]}</b></li>`;
    }).join("")}</ol></div>`;
  }

  function seasonTab(season, prog) {
    const R = allRounds(season);
    const done = prog >= R.length;
    const regWeeks = Math.min(prog, season.weeks.length);
    const table = done ? season.standings : standingsFrom(season, regWeeks);
    const ties = table.some(x => x.t);
    const champ = done ? season.champion : null;
    const revealed = R.slice(0, prog);
    const players = aggregate(revealed.flatMap(r => r.games));
    const top = (f, k = 3) => players.filter(x => x[f] > 0).sort((a, b) => b[f] - a[f] || a.pid - b.pid).slice(0, k);
    const ctl = done
      ? `<div class="champ ${champ === S.user ? "mine" : ""}"><span>League champions</span><b>${esc(S.teams[champ].name)}</b>
          <small>${champ === S.user ? "Your team won the title." : `Regular season ${recStr(season.standings.find(x => x.team === champ))}`}</small></div>`
      : `<div class="season-ctl">
          <button class="btn primary" type="button" id="playNext">${nextLabel(R[prog], S.teams.length)}</button>
          ${R.length - prog > 1 ? `<button class="btn ghost" type="button" id="playAll">Play the rest</button>` : ""}
          <p class="fine">${prog === 0 ? `${season.weeks.length} ${S.teams.length === 2 ? "games" : "weeks"}, then ${season.playoffs.length ? (season.playoffs.length > 1 ? "semifinals and a championship" : "a championship game") : "the series decides the title"}. Every snap is simulated from your roster.` : ""}</p>
        </div>`;
    const awards = done && season.awards ? `<h3>Season awards</h3><div class="awards">${[["Most valuable player", season.awards.mvp], ["Defensive player of the year", season.awards.dpoy]].map(([t, a]) => {
        const p = BY_ID.get(a.pid);
        return `<button type="button" class="award ${a.team === S.user ? "mine" : ""}" data-pid="${a.pid}">${sprite(p, "sm")}<span><small>${t}</small><b>${esc(a.name)}</b><small>${esc(S.teams[a.team].name)}, ${statLine(a)}</small></span></button>`;
      }).join("")}</div>` : "";
    return `
      ${ctl}
      ${prog ? `
      <h3>Standings</h3>
      <table class="tbl"><thead><tr><th>Team</th><th>W</th><th>L</th>${ties ? "<th>T</th>" : ""}<th>PF</th><th>PA</th></tr></thead><tbody>
        ${table.map(x => `<tr class="${x.team === S.user ? "mine" : ""}"><td>${esc(S.teams[x.team].name)}${x.team === champ ? ` <span class="trophy">Champions</span>` : ""}</td><td>${x.w}</td><td>${x.l}</td>${ties ? `<td>${x.t}</td>` : ""}<td>${x.pf}</td><td>${x.pa}</td></tr>`).join("")}
      </tbody></table>
      ${awards}
      <h3>Results</h3>
      ${revealed.map((rd, ri) => ({ rd, ri })).reverse().map(({ rd, ri }) => `<h4 class="round-label">${rd.label}</h4><div class="games">${rd.games.map((g, gi) => gameCard(g, ri, gi)).join("")}</div>`).join("")}
      <h3>League leaders</h3>
      <div class="leaders">
        ${leaderBlock("Passing yards", top("pyd"), "pyd")}${leaderBlock("Rushing yards", top("ryd"), "ryd")}${leaderBlock("Receiving yards", top("recyd"), "recyd")}
        ${leaderBlock("Sacks", top("sacks"), "sacks")}${leaderBlock("Interceptions", top("dint"), "dint")}${leaderBlock("Tackles", top("tkl"), "tkl")}
      </div>` : ""}`;
  }

  function gradesTab() {
    const n = S.teams.length;
    const rows = S.teams.map((t, i) => ({ t, i, g: E.grades(t.roster, BY_ID, n, normsFor().norms) })).sort((a, b) => b.g.TEAM.z - a.g.TEAM.z);
    const value = i => {
      const picks = S.log.filter(l => l.team === i).map(l => ({ ...l, adp: normsFor().adp[l.pid], no: l.pick + 1 })).filter(l => l.adp);
      const steal = picks.slice().sort((a, b) => (b.no - b.adp) - (a.no - a.adp))[0];
      const reach = picks.slice().sort((a, b) => (a.no - a.adp) - (b.no - b.adp))[0];
      const out = [];
      if (steal && steal.no - steal.adp >= 8) out.push(`Best value: ${esc(BY_ID.get(steal.pid).name)} at pick ${steal.no} (usually goes around ${Math.round(steal.adp)})`);
      if (reach && reach.adp - reach.no >= 10) out.push(`Biggest reach: ${esc(BY_ID.get(reach.pid).name)} at pick ${reach.no} (usually goes around ${Math.round(reach.adp)})`);
      return out;
    };
    return `<p class="fine">Grades compare each position group to what teams typically draft in a ${n}-team league, chemistry included.</p>
      ${rows.map(({ t, i, g }) => `
      <article class="grade-card ${i === S.user ? "mine" : ""}">
        <div class="grade-head">
          <div><h3>${esc(t.name)}</h3><p class="sm">${t.ai ? `AI${t.style && AI_STYLES[t.style] ? `, ${AI_STYLES[t.style].label.toLowerCase()}` : ""}` : i === S.user ? "Your team" : "Human"}</p></div>
          <b class="grade-big g-${g.TEAM.grade[0]}">${g.TEAM.grade}</b>
        </div>
        <div class="gchips">${Object.keys(GROUP_NAMES).map(k => `<span class="gchip g-${g[k].grade[0]}" title="${GROUP_NAMES[k]}: ${g[k].score.toFixed(1)}"><span>${k}</span><b>${g[k].grade}</b></span>`).join("")}</div>
        ${value(i).map(v => `<p class="value-note">${v}</p>`).join("")}
      </article>`).join("")}`;
  }

  function teamsTab() {
    const list = S.teams.map((t, i) => ({ t, i, r: teamRatings(t.roster) })).sort((a, b) => b.r.ovr - a.r.ovr || b.r.off - a.r.off);
    return `<p class="fine">Team rating weighs each spot by importance and counts stars and chemistry extra. Tap a team to see its roster.</p>
      <ol class="standings">${list.map((x, k) => `
      <li class="${x.i === S.user ? "mine" : ""}"><span class="rk">${k + 1}</span><button type="button" class="link-btn" data-team="${x.i}">${esc(x.t.name)}${x.t.ai ? " <small>AI</small>" : ""}</button>
        <span class="sm">Off ${x.r.off}, Def ${x.r.def}</span><b>${x.r.ovr}</b></li>`).join("")}</ol>`;
  }

  function renderWatch() {
    const list = S.teams.map((t, i) => ({ t, i, r: teamRatings(t.roster), n: Object.keys(t.roster).length }));
    setTicker(`<span class="tk-round">Room ${esc(S.code)}: draft in progress</span>`);
    app.className = "screen-results";
    app.innerHTML = `<section class="results"><div class="results-head">
      <h1>Draft in progress</h1><p class="lede">This draft started before you joined. You can follow it here; the page updates as picks come in.</p>
      <ol class="standings">${list.map((x, k) => `<li><span class="rk">${k + 1}</span><button type="button" class="link-btn" data-team="${x.i}">${esc(x.t.name)}</button><span class="sm">${x.n} of ${ROUNDS} picks</span><b>${x.r.ovr || "—"}</b></li>`).join("")}</ol>
      </div></section>`;
    app.querySelectorAll("[data-team]").forEach(b => b.onclick = () => openTeam(S.teams[+b.dataset.team]));
  }

  function renderResults() {
    if (S.mode === "online" && S.status === "drafting") return renderWatch();
    const season = getSeason();
    const R = allRounds(season);
    const prog = Math.min(getProg(), R.length);
    const done = prog >= R.length;
    const table = done ? season.standings : standingsFrom(season, Math.min(prog, season.weeks.length));
    const spectator = S.user < 0;
    const meIdx = spectator ? table[0].team : S.user;
    const me = S.teams[meIdx];
    const r = teamRatings(me.roster);
    const gr = E.grades(me.roster, BY_ID, S.teams.length, normsFor().norms);
    const myRec = table.find(x => x.team === meIdx);
    const tab = ui.rtab || "season";
    setTicker(`<span class="tk-round">${S.mode === "online" ? `Room ${esc(S.code)}: ` : ""}${done ? "season complete" : prog ? `after ${R[prog - 1].label.toLowerCase()}` : "draft complete"}</span>`);
    app.className = "screen-results";
    app.innerHTML = `
      <section class="results">
        <div class="results-head">
          <h1>${esc(me.name)}</h1>
          <p class="lede">${done && season.champion === meIdx ? "League champions. " : ""}${prog ? `Record ${recStr(myRec)}. ` : ""}Draft grade ${gr.TEAM.grade}.</p>
          <div class="big-nums"><div><b>${r.ovr}</b><span>Team</span></div><div><b>${r.off}</b><span>Offense</span></div><div><b>${r.def}</b><span>Defense</span></div><div><b class="g-${gr.TEAM.grade[0]}">${gr.TEAM.grade}</b><span>Grade</span></div></div>
          <div class="share-row">
            ${spectator ? "" : `<button class="btn primary" type="button" id="shareBtn">Share my team</button>`}
            <button class="btn ghost" type="button" id="againBtn">${S.mode === "online" ? "New draft" : "Draft again"}</button>
          </div>
          <nav class="rtabs" aria-label="League views">
            ${[["season", "Season"], ["grades", "Draft grades"], ["teams", "Teams"]].map(([k, v]) => `<button type="button" data-rtab="${k}" aria-pressed="${tab === k}">${v}</button>`).join("")}
          </nav>
          <div class="rtab-body">${tab === "season" ? seasonTab(season, prog) : tab === "grades" ? gradesTab() : teamsTab()}</div>
        </div>
        <div class="results-field">${field(me.roster, { big: true, names: true })}${chemList(me.roster, { empty: true })}</div>
      </section>`;
    $("#shareBtn")?.addEventListener("click", () => shareTeam(me, { g: gr.TEAM.grade, rec: done ? recStr(myRec) : null, c: done && season.champion === meIdx }));
    $("#againBtn").onclick = () => {
      if (S.mode === "solo") store.del("g151-draft");
      leaveRoom(); S = null; ui = freshUI(); history.replaceState(null, "", location.pathname); render();
    };
    app.querySelectorAll("[data-rtab]").forEach(b => b.onclick = () => { ui.rtab = b.dataset.rtab; render(); });
    $("#playNext")?.addEventListener("click", () => { setProg(prog + 1); render(); });
    $("#playAll")?.addEventListener("click", () => { setProg(R.length); render(); });
    app.querySelectorAll("[data-game]").forEach(b => b.onclick = () => { const [ri, gi] = b.dataset.game.split(":").map(Number); openBox(R[ri].games[gi], R[ri].label); });
    app.querySelectorAll("[data-team]").forEach(b => b.onclick = () => openTeam(S.teams[+b.dataset.team]));
    app.querySelectorAll(".award[data-pid], .field .chip[data-pid]").forEach(b => b.onclick = () => openCard(+b.dataset.pid));
  }

  function openBox(g, label) {
    const names = [S.teams[g.a].name, S.teams[g.b].name];
    const q = g.quarterPts;
    const teamRow = (title, f) => `<tr><th>${title}</th><td>${f(0)}</td><td>${f(1)}</td></tr>`;
    const table = (s, title, rows, cols) => rows.length ? `<h5>${title}</h5><table class="tbl box"><thead><tr><th></th>${cols.map(c => `<th>${c[0]}</th>`).join("")}</tr></thead><tbody>
      ${rows.map(l => `<tr><td>${sprite(BY_ID.get(l.pid), "xs")}<span>${esc(l.name)}</span></td>${cols.map(c => `<td>${c[1](l)}</td>`).join("")}</tr>`).join("")}</tbody></table>` : "";
    const side = s => {
      const L = g.lines[s];
      return `<div class="box-side"><h4>${esc(names[s])}</h4>
        ${table(s, "Passing", L.filter(l => l.att), [["C/ATT", l => `${l.cmp}/${l.att}`], ["YDS", l => l.pyd], ["TD", l => l.ptd], ["INT", l => l.int], ["SK", l => l.sk]])}
        ${table(s, "Rushing", L.filter(l => l.car).sort((a, b) => b.ryd - a.ryd), [["CAR", l => l.car], ["YDS", l => l.ryd], ["TD", l => l.rtd], ["LONG", l => l.long]])}
        ${table(s, "Receiving", L.filter(l => l.tgt).sort((a, b) => b.recyd - a.recyd), [["REC", l => l.rec], ["TGT", l => l.tgt], ["YDS", l => l.recyd], ["TD", l => l.rectd]])}
        ${table(s, "Defense", L.filter(l => l.tkl || l.sacks || l.dint || l.ff).sort((a, b) => (b.sacks * 3 + b.dint * 4 + b.tkl) - (a.sacks * 3 + a.dint * 4 + a.tkl)), [["TKL", l => l.tkl], ["SACK", l => l.sacks], ["INT", l => l.dint], ["FF", l => l.ff]])}
      </div>`;
    };
    $("#cardDialogBody").innerHTML = `<div class="boxscore">
      <p class="sm">${esc(label)}${g.ot ? ", overtime" : ""}</p>
      <div class="box-score-line">
        <div class="${g.winner === 0 ? "won" : ""}"><span>${esc(names[0])}</span><b>${g.score[0]}</b></div>
        <div class="${g.winner === 1 ? "won" : ""}"><span>${esc(names[1])}</span><b>${g.score[1]}</b></div>
      </div>
      <table class="tbl qtr"><thead><tr><th></th><th>1</th><th>2</th><th>3</th><th>4${g.ot ? "/OT" : ""}</th><th>Final</th></tr></thead><tbody>
        ${[0, 1].map(s => `<tr><th>${esc(names[s])}</th>${q[s].map(x => `<td>${x}</td>`).join("")}<td><b>${g.score[s]}</b></td></tr>`).join("")}
      </tbody></table>
      ${g.scoring.length ? `<h4>Scoring</h4><ol class="scoring">${g.scoring.map(x => `<li><span>${x.q > 4 ? "OT" : "Q" + x.q}</span><b>${esc(names[x.team])}</b> ${esc(x.text)}</li>`).join("")}</ol>` : ""}
      <h4>Team stats</h4>
      <table class="tbl"><thead><tr><th></th><th>${esc(names[0])}</th><th>${esc(names[1])}</th></tr></thead><tbody>
        ${teamRow("Total yards", s => g.team[s].pyd + g.team[s].ryd)}${teamRow("Passing", s => g.team[s].pyd)}${teamRow("Rushing", s => g.team[s].ryd)}
        ${teamRow("First downs", s => g.team[s].firstDowns)}${teamRow("Turnovers", s => g.team[s].to)}${teamRow("Sacked", s => g.team[s].sacked)}
      </tbody></table>
      <div class="box-sides">${side(0)}${side(1)}</div>
    </div>`;
    openDialog(true);
  }

  function renderShared(team) {
    const r = teamRatings(team.roster);
    const bits = [team.champ ? "League champions" : null, team.rec ? `Record ${team.rec}` : null, team.grade ? `Draft grade ${team.grade}` : null].filter(Boolean);
    setTicker(`<span class="tk-round">Shared roster</span>`);
    app.className = "screen-results";
    app.innerHTML = `
      <section class="results">
        <div class="results-head">
          <h1>${esc(team.name)}</h1>
          <p class="lede">${bits.length ? bits.join(". ") + ". " : ""}A Gridiron 151 roster. Tap any player to see their card.</p>
          <div class="big-nums"><div><b>${r.ovr}</b><span>Team</span></div><div><b>${r.off}</b><span>Offense</span></div><div><b>${r.def}</b><span>Defense</span></div>${team.grade ? `<div><b class="g-${team.grade[0]}">${team.grade}</b><span>Grade</span></div>` : ""}</div>
          <div class="share-row"><a class="btn primary" href="./">Draft your own team</a></div>
          <h2>Roster</h2>
          <ol class="roster-list">${SHARE_ORDER.filter(id => team.roster[id]).map(id => {
            const p = BY_ID.get(team.roster[id]); const s = SLOT_BY_ID[id];
            return `<li><span class="rk">${s.label}</span>${sprite(p, "xs")}<button type="button" class="link-btn" data-pid="${p.id}">${esc(p.name)}</button><b>${p.posOvr[s.pos]}</b></li>`;
          }).join("")}</ol>
        </div>
        <div class="results-field">${field(team.roster, { big: true, names: true })}${chemList(team.roster)}</div>
      </section>`;
    app.querySelectorAll("[data-pid]").forEach(b => b.onclick = () => openCard(+b.dataset.pid));
  }

  function openDialog(wide) {
    const d = $("#cardDialog");
    d.classList.toggle("wide", !!wide);
    if (!d.open) d.showModal();
    d.scrollTop = 0;
  }
  function openCard(pid) {
    $("#cardDialogBody").innerHTML = playerCard(BY_ID.get(pid));
    openDialog();
  }
  function openTeam(team) {
    const r = teamRatings(team.roster);
    const style = team.ai && team.style && AI_STYLES[team.style] ? `AI, ${AI_STYLES[team.style].label.toLowerCase()}. ` : "";
    $("#cardDialogBody").innerHTML = `<div class="team-pop"><h2>${esc(team.name)}</h2>
      <p class="sm">${style}Team ${r.ovr}, offense ${r.off}, defense ${r.def}</p>${field(team.roster, { names: true })}${chemList(team.roster)}</div>`;
    openDialog();
    $("#cardDialogBody").querySelectorAll(".chip[data-pid]").forEach(b => b.onclick = () => openCard(+b.dataset.pid));
  }

  function renderHow() {
    const fmt = f => Object.entries(f).map(([k, w]) => `${w < 0 ? "minus " : ""}${Math.round(Math.abs(w) * 100)}% ${({hp:"HP",attack:"Attack",defense:"Defense",sp_attack:"Sp. Atk",sp_defense:"Sp. Def",speed:"Speed",logw:"weight",logh:"height",maturity:"evolution stage"})[k] || (meta.attrNames[k] || k).toLowerCase()}`).join(", ");
    $("#howBody").innerHTML = `
      <p>Pick a pool when you set up a draft: the original 150, or every Pokémon with a sprite (${ALL_COUNT.toLocaleString()}). Each pool is rated with the same formulas, scaled against the Pokémon in that pool, so a Pokémon's ratings can differ between pools. Mewtwo is left out of the Original 150 for balance; in All Pokémon it has plenty of legendaries to compete with.</p>
      <p>Ratings are calculated, not hand-picked. Each Pokémon's base stats, height and weight feed ten football attributes on a 40–99 scale, where 70 is average among the pool.</p>
      <h3>Attributes</h3>
      <dl class="how">${ATTRS.map(a => `<dt>${meta.attrNames[a]}</dt><dd>${fmt(meta.attrFormulas[a])}</dd>`).join("")}</dl>
      <h3>Position ratings</h3>
      <p>Every Pokémon has a rating at all nine positions and can be drafted into any open spot. Each position rating blends the attributes that matter there (70%) with the Pokémon's base stat total (30%), so raw talent still counts. "Natural" position is simply where it rates best relative to the rest of the pool.</p>
      <dl class="how">${POSITIONS.map(p => `<dt>${POS_NAMES[p]}</dt><dd>${fmt(meta.positionWeights[p])}</dd>`).join("")}</dl>
      <h3>Team rating</h3>
      <p>Spots are weighted by how much they matter. A quarterback counts 3 times as much as a guard; running backs, receivers, corners and defensive linemen count a little more than linebackers, safeties and linemen. Stars count extra: every point above 85 is worth 1.6 points.</p>
      <h3>Chemistry</h3>
      <p>Three or more players of one type in the same unit (line, receivers, front four, linebackers, secondary) get +2 to +4. Receivers who share a type with the quarterback get +2, and the quarterback gets up to +3. Two or more Pokémon from one evolution family get +2 each. No player gets more than +5.</p>
      <h3>Games</h3>
      <p>Every snap is simulated. Runs pit the ball carrier and blockers against the defensive line and linebackers. Passes pit the quarterback and the targeted receiver against his defender and the pass rush. Strong units produce big stat lines, and luck still decides close games. Every device gets the same results for the same league.</p>
      <p class="fine">${esc(meta.source)}</p>`;
  }

  function toast(msg, isError) {
    const t = $("#toast"); t.textContent = msg; t.classList.add("show"); t.classList.toggle("error", !!isError);
    clearTimeout(toast.t); toast.t = setTimeout(() => t.classList.remove("show"), isError ? 3500 : 2000);
  }

  // re-render without losing the player list's scroll position or the search box focus
  function render() {
    const list = $(".plist");
    const listTop = list ? list.scrollTop : 0;
    const winY = window.scrollY;
    const active = document.activeElement && document.activeElement.id;
    const caret = active === "q" ? document.activeElement.selectionStart : null;
    try { draw(); }
    catch (e) {
      console.error(e);
      setTicker("");
      app.className = "screen-setup";
      app.innerHTML = `<section class="setup"><div class="setup-copy">
        <h1>Something went wrong.</h1>
        <p class="lede">${esc(e && e.message && /Pokémon/.test(e.message) ? e.message : "This screen couldn't load.")} Start a new draft to keep playing.</p>
        <div class="share-row"><button class="btn primary" type="button" id="resetBtn">Start over</button></div>
      </div></section>`;
      $("#resetBtn").onclick = () => { store.del("g151-draft"); leaveRoom(); S = null; ui = freshUI(); history.replaceState(null, "", location.pathname); render(); };
      return;
    }
    const nl = $(".plist"); if (nl) nl.scrollTop = listTop;
    window.scrollTo(0, winY);
    if (active) { const el = document.getElementById(active); if (el) { el.focus({ preventScroll: true }); if (caret != null) el.setSelectionRange(caret, caret); } }
  }
  function draw() {
    if (S) usePool(poolKey(S.pool));
    if (!S) return renderHome();
    if (S.mode === "online") {
      if (S.status === "lobby") return S.user < 0 ? (ui.home = "join", renderHome()) : renderLobby();
      if (S.done || S.user < 0) return renderResults();
      return renderDraft();
    }
    if (S.done) return renderResults();
    renderDraft();
  }

  /* ---------- boot ---------- */

  document.querySelectorAll("dialog").forEach(d => {
    d.addEventListener("click", e => { if (e.target === d || e.target.closest("[data-close]")) d.close(); });
  });
  $("#howBtn").onclick = () => { renderHow(); $("#howDialog").showModal(); };

  const params = new URLSearchParams(location.search);
  (async () => {
    if (params.has("r")) {
      const key = poolKey(params.get("p"));
      try { await ensurePool(key); } catch {}
      usePool(key);
      const shared = decodeTeam(params);
      return shared ? renderShared(shared) : render();
    }
    if (params.has("room") && Net.available) {
      app.innerHTML = `<p class="loading">Connecting to room ${esc(params.get("room").toUpperCase())}…</p>`;
      return openRoom(params.get("room"));
    }
    if (params.has("join") && Net.available) { ui.home = "join"; return render(); }
    const raw = store.get("g151-draft");
    if (raw && poolKey(raw.pool) !== "gen1") { try { await ensurePool(poolKey(raw.pool)); } catch {} }
    const saved = loadSolo();
    if (saved && saved.mode === "solo" && saved.done) S = saved;
    else usePool("gen1");
    render();
  })();

  window.__g151 = { get state() { return S; }, get pool() { return POOL; }, SLOTS, encodeTeam, season: () => (S && S.done ? getSeason() : null) };
})();
