-- Gridiron 151: multiplayer draft rooms
-- Paste this whole file into Supabase > SQL Editor > New query, then click Run.
-- Safe to run again later: it updates functions and reloads ratings without touching existing rooms.

-- ---------- tables ----------
create table if not exists public.g151_rooms (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,
  host          uuid not null,
  num_teams     int  not null check (num_teams between 2 and 6),
  pick_seconds  int  not null default 60 check (pick_seconds in (0, 30, 60, 90)),
  status        text not null default 'lobby' check (status in ('lobby', 'drafting', 'done')),
  pick          int  not null default 0,
  draft_order   int[] not null default '{}',
  last_pick_at  timestamptz,
  deadline      timestamptz,
  created_at    timestamptz not null default now()
);

alter table public.g151_rooms add column if not exists draft_type text not null default 'snake';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'g151_rooms_draft_type_check') then
    alter table public.g151_rooms add constraint g151_rooms_draft_type_check check (draft_type in ('snake', 'linear'));
  end if;
end $$;

create table if not exists public.g151_seats (
  room_id    uuid not null references public.g151_rooms(id) on delete cascade,
  seat       int  not null,
  user_id    uuid,
  team_name  text,
  is_ai      boolean not null default false,
  primary key (room_id, seat),
  unique (room_id, user_id)
);

create table if not exists public.g151_picks (
  room_id    uuid not null references public.g151_rooms(id) on delete cascade,
  pick_no    int  not null,
  seat       int  not null,
  pid        int  not null,
  slot       text not null,
  auto       boolean not null default false,
  created_at timestamptz not null default now(),
  primary key (room_id, pick_no),
  unique (room_id, pid),
  unique (room_id, seat, slot)
);

alter table public.g151_seats add column if not exists style text;
alter table public.g151_seats add column if not exists fav_type text;

create table if not exists public.g151_slots (
  slot text primary key,
  pos  text not null
);

create table if not exists public.g151_ratings (
  pid int  not null,
  pos text not null,
  ovr int  not null,
  primary key (pid, pos)
);

create table if not exists public.g151_pokemon (
  pid   int primary key,
  types text[] not null
);

-- ---------- row level security: everyone can read, nobody writes directly ----------
alter table public.g151_rooms   enable row level security;
alter table public.g151_seats   enable row level security;
alter table public.g151_picks   enable row level security;
alter table public.g151_slots   enable row level security;
alter table public.g151_ratings enable row level security;
alter table public.g151_pokemon enable row level security;

drop policy if exists g151_read on public.g151_rooms;
drop policy if exists g151_read on public.g151_seats;
drop policy if exists g151_read on public.g151_picks;
drop policy if exists g151_read on public.g151_slots;
drop policy if exists g151_read on public.g151_ratings;
drop policy if exists g151_read on public.g151_pokemon;
create policy g151_read on public.g151_rooms   for select using (true);
create policy g151_read on public.g151_seats   for select using (true);
create policy g151_read on public.g151_picks   for select using (true);
create policy g151_read on public.g151_slots   for select using (true);
create policy g151_read on public.g151_ratings for select using (true);
create policy g151_read on public.g151_pokemon for select using (true);

-- ---------- helpers (not callable from the website) ----------
create or replace function public.g151_on_clock(p_pick int, p_order int[])
returns int language sql immutable as $$
  select case
    when (p_pick / array_length(p_order, 1)) % 2 = 0
      then p_order[(p_pick % array_length(p_order, 1)) + 1]
    else p_order[array_length(p_order, 1) - (p_pick % array_length(p_order, 1))]
  end
$$;

-- snake reverses the order every other round; linear keeps one order all draft
create or replace function public.g151_on_clock(p_pick int, p_order int[], p_type text)
returns int language sql immutable as $$
  select case
    when p_type = 'linear' then p_order[(p_pick % array_length(p_order, 1)) + 1]
    else public.g151_on_clock(p_pick, p_order)
  end
$$;

create or replace function public.g151_do_pick(p_room public.g151_rooms, p_seat int, p_pid int, p_slot text, p_auto boolean)
returns void language plpgsql security definer set search_path = public as $$
declare
  total int := p_room.num_teams * (select count(*) from g151_slots);
begin
  insert into g151_picks (room_id, pick_no, seat, pid, slot, auto)
  values (p_room.id, p_room.pick, p_seat, p_pid, p_slot, p_auto);

  update g151_rooms set
    pick = p_room.pick + 1,
    last_pick_at = now(),
    status = case when p_room.pick + 1 >= total then 'done' else 'drafting' end,
    deadline = case when p_room.pick_seconds > 0 and p_room.pick + 1 < total
                    then now() + make_interval(secs => p_room.pick_seconds) end
  where id = p_room.id;
end $$;

-- AI pick: value over replacement, shaped by the team's drafting style (mirrors aiChoose in js/engine.js)
create or replace function public.g151_style_mult(p_style text, p_pos text)
returns numeric language sql immutable as $$
  select (case p_pos when 'QB' then 1.93 when 'RB' then 1.17 when 'WR' then 1.09 when 'TE' then 1.0 when 'OL' then 0.94
                     when 'DL' then 1.03 when 'LB' then 0.94 when 'CB' then 1.06 else 0.94 end)
       * (case
            when p_style = 'qb' and p_pos = 'QB' then 1.7
            when p_style = 'air' and p_pos = 'QB' then 1.3
            when p_style = 'air' and p_pos = 'WR' then 1.35
            when p_style = 'air' and p_pos = 'TE' then 1.15
            when p_style = 'ground' and p_pos = 'RB' then 1.6
            when p_style = 'ground' and p_pos = 'OL' then 1.3
            when p_style = 'trenches' and p_pos in ('OL', 'DL') then 1.35
            when p_style = 'defense' and p_pos in ('DL', 'CB') then 1.25
            when p_style = 'defense' and p_pos in ('LB', 'S') then 1.3
            else 1 end)
$$;

create or replace function public.g151_star(p_ovr numeric, p_k numeric)
returns numeric language sql immutable as $$ select p_ovr + greatest(0, p_ovr - 85) * 0.6 * p_k $$;

drop function if exists public.g151_best_pick(uuid, int);
create or replace function public.g151_best_pick(p_room_id uuid, p_seat int, out pid int, out slot text)
language plpgsql security definer set search_path = public as $$
declare
  v_style text; v_fav text; k numeric;
begin
  select coalesce(style, 'balanced'), fav_type into v_style, v_fav from g151_seats where room_id = p_room_id and seat = p_seat;
  k := case when v_style = 'stars' then 2.4 else 1 end;
  with avail as (
    select r.pid, r.pos, r.ovr from g151_ratings r
    where not exists (select 1 from g151_picks p where p.room_id = p_room_id and p.pid = r.pid)
  ), demand as (
    select s.pos, count(*)::int as d
    from g151_seats se cross join g151_slots s
    where se.room_id = p_room_id
      and not exists (select 1 from g151_picks p where p.room_id = p_room_id and p.seat = se.seat and p.slot = s.slot)
    group by s.pos
  ), ranked as (
    select a.pos, a.ovr, (row_number() over (partition by a.pos order by a.ovr desc) - 1)::int as rk,
           count(*) over (partition by a.pos)::int as cnt
    from avail a
  ), repl as (
    select d.pos, coalesce((select r.ovr from ranked r where r.pos = d.pos and r.rk = least(d.d, r.cnt - 1)), 40) as rv
    from demand d
  ), open_slots as (
    select distinct on (s.pos) s.slot, s.pos from g151_slots s
    where not exists (select 1 from g151_picks p where p.room_id = p_room_id and p.seat = p_seat and p.slot = s.slot)
    order by s.pos, s.slot
  )
  select a.pid, o.slot into pid, slot
  from avail a
  join open_slots o on o.pos = a.pos
  join repl rp on rp.pos = a.pos
  left join g151_pokemon pk on pk.pid = a.pid
  order by (g151_star(a.ovr, k) - g151_star(rp.rv, k)) * g151_style_mult(v_style, a.pos)
         + (case when v_style = 'loyal' and v_fav is not null and v_fav = any(pk.types) then 7 else 0 end)
         + random() * 4 - 2 desc
  limit 1;
end $$;

-- ---------- functions the website calls ----------
drop function if exists public.g151_create_room(int, int, text);
create or replace function public.g151_create_room(p_num_teams int, p_pick_seconds int, p_team_name text, p_draft_type text default 'snake')
returns text language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  v_code text;
  v_id uuid;
  alphabet text := 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';
  name text := left(btrim(coalesce(p_team_name, '')), 28);
begin
  if uid is null then raise exception 'Not signed in'; end if;
  if name = '' then raise exception 'Enter a team name'; end if;
  if p_num_teams not between 2 and 6 then raise exception 'Pick 2 to 6 teams'; end if;
  if p_pick_seconds not in (0, 30, 60, 90) then raise exception 'Invalid pick timer'; end if;
  if coalesce(p_draft_type, 'snake') not in ('snake', 'linear') then raise exception 'Invalid draft order'; end if;

  loop
    v_code := '';
    for i in 1..4 loop
      v_code := v_code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    begin
      insert into g151_rooms (code, host, num_teams, pick_seconds, draft_type)
      values (v_code, uid, p_num_teams, p_pick_seconds, coalesce(p_draft_type, 'snake')) returning id into v_id;
      exit;
    exception when unique_violation then
      -- code collision, try another
    end;
  end loop;

  insert into g151_seats (room_id, seat, user_id, team_name)
  select v_id, s, case when s = 0 then uid end, case when s = 0 then name end
  from generate_series(0, p_num_teams - 1) s;

  return v_code;
end $$;

create or replace function public.g151_join_room(p_code text, p_team_name text)
returns int language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  r g151_rooms;
  v_seat int;
  name text := left(btrim(coalesce(p_team_name, '')), 28);
begin
  if uid is null then raise exception 'Not signed in'; end if;
  select * into r from g151_rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'No room with that code'; end if;

  select seat into v_seat from g151_seats where room_id = r.id and user_id = uid;
  if found then
    if name <> '' and r.status = 'lobby' then
      update g151_seats set team_name = name where room_id = r.id and seat = v_seat;
    end if;
    return v_seat;
  end if;

  if r.status <> 'lobby' then raise exception 'This draft has already started'; end if;
  if name = '' then raise exception 'Enter a team name'; end if;

  select min(seat) into v_seat from g151_seats where room_id = r.id and user_id is null and not is_ai;
  if v_seat is null then raise exception 'This room is full'; end if;

  update g151_seats set user_id = uid, team_name = name where room_id = r.id and seat = v_seat;
  return v_seat;
end $$;

create or replace function public.g151_start_room(p_code text)
returns void language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  r g151_rooms;
  ai_names text[] := array['Pewter Boulders','Cerulean Surge','Vermilion Voltage','Celadon Thorns','Saffron Minds','Cinnabar Blaze','Fuchsia Venom','Lavender Haunts','Viridian Rangers'];
begin
  select * into r from g151_rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'No room with that code'; end if;
  if r.host is distinct from uid then raise exception 'Only the host can start the draft'; end if;
  if r.status <> 'lobby' then raise exception 'The draft has already started'; end if;

  -- open seats become AI teams with distinct names
  with open_seats as (
    select seat, row_number() over (order by seat) as n
    from g151_seats where room_id = r.id and user_id is null
  ), names as (
    select nm, row_number() over (order by random()) as n
    from unnest(ai_names) nm
    where nm not in (select coalesce(team_name, '') from g151_seats where room_id = r.id)
  )
  update g151_seats s set is_ai = true, team_name = names.nm,
    style = (array['balanced','qb','air','ground','trenches','defense','stars','loyal'])[1 + floor(random() * 8)::int],
    fav_type = (array['water','fire','grass','psychic','rock','normal','poison','electric','ground','flying','bug','fighting'])[1 + floor(random() * 12)::int]
  from open_seats join names using (n)
  where s.room_id = r.id and s.seat = open_seats.seat;

  update g151_rooms set
    status = 'drafting',
    pick = 0,
    draft_order = (select array_agg(seat order by random()) from g151_seats where room_id = r.id),
    last_pick_at = now(),
    deadline = case when pick_seconds > 0 then now() + make_interval(secs => pick_seconds) end
  where id = r.id;
end $$;

create or replace function public.g151_make_pick(p_code text, p_pid int, p_slot text)
returns void language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  r g151_rooms;
  v_seat int;
  v_pos text;
begin
  select * into r from g151_rooms where code = upper(btrim(p_code)) for update;
  if not found then raise exception 'No room with that code'; end if;
  if r.status <> 'drafting' then raise exception 'The draft is not running'; end if;

  select seat into v_seat from g151_seats where room_id = r.id and user_id = uid;
  if v_seat is null then raise exception 'You do not have a team in this room'; end if;
  if g151_on_clock(r.pick, r.draft_order, r.draft_type) <> v_seat then raise exception 'It is not your pick'; end if;

  select pos into v_pos from g151_slots where slot = p_slot;
  if v_pos is null then raise exception 'Unknown roster spot'; end if;
  if not exists (select 1 from g151_ratings where pid = p_pid) then raise exception 'Unknown Pokémon'; end if;
  if exists (select 1 from g151_picks where room_id = r.id and pid = p_pid) then
    raise exception 'That Pokémon was already drafted';
  end if;
  if exists (select 1 from g151_picks where room_id = r.id and seat = v_seat and slot = p_slot) then
    raise exception 'That roster spot is already filled';
  end if;

  perform g151_do_pick(r, v_seat, p_pid, p_slot, false);
end $$;

-- Any client in the room calls this when an AI team is on the clock or a pick clock runs out.
-- The row lock means only one call wins; the rest return false.
create or replace function public.g151_tick(p_code text)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  r g151_rooms;
  v_seat int;
  v_ai boolean;
  bp record;
begin
  select * into r from g151_rooms where code = upper(btrim(p_code)) for update;
  if not found or r.status <> 'drafting' then return false; end if;

  v_seat := g151_on_clock(r.pick, r.draft_order, r.draft_type);
  select is_ai into v_ai from g151_seats where room_id = r.id and seat = v_seat;

  if v_ai and now() >= r.last_pick_at + interval '900 milliseconds' then
    select * into bp from g151_best_pick(r.id, v_seat);
    perform g151_do_pick(r, v_seat, bp.pid, bp.slot, true);
    return true;
  elsif not v_ai and r.deadline is not null and now() >= r.deadline then
    select * into bp from g151_best_pick(r.id, v_seat);
    perform g151_do_pick(r, v_seat, bp.pid, bp.slot, true);
    return true;
  end if;
  return false;
end $$;

-- Whole room state in one call, plus the server clock so pick timers line up.
create or replace function public.g151_get_room(p_code text)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'room', (select json_build_object(
        'id', id, 'code', code, 'num_teams', num_teams, 'pick_seconds', pick_seconds, 'draft_type', draft_type,
        'status', status, 'pick', pick, 'draft_order', draft_order, 'deadline', deadline,
        'is_host', host = auth.uid())
      from g151_rooms where code = upper(btrim(p_code))),
    'seats', (select coalesce(json_agg(json_build_object(
        'seat', s.seat, 'team_name', s.team_name, 'is_ai', s.is_ai, 'style', s.style,
        'claimed', s.user_id is not null, 'mine', s.user_id = auth.uid()) order by s.seat), '[]'::json)
      from g151_seats s join g151_rooms r on r.id = s.room_id where r.code = upper(btrim(p_code))),
    'picks', (select coalesce(json_agg(json_build_object(
        'pick_no', p.pick_no, 'seat', p.seat, 'pid', p.pid, 'slot', p.slot, 'auto', p.auto) order by p.pick_no), '[]'::json)
      from g151_picks p join g151_rooms r on r.id = p.room_id where r.code = upper(btrim(p_code))),
    'now', now()
  )
$$;

-- ---------- permissions ----------
revoke all on function public.g151_do_pick(public.g151_rooms, int, int, text, boolean) from public;
revoke all on function public.g151_best_pick(uuid, int) from public;
revoke all on function public.g151_style_mult(text, text) from public;
revoke all on function public.g151_star(numeric, numeric) from public;
revoke all on function public.g151_create_room(int, int, text, text) from public;
revoke all on function public.g151_join_room(text, text) from public;
revoke all on function public.g151_start_room(text) from public;
revoke all on function public.g151_make_pick(text, int, text) from public;
revoke all on function public.g151_tick(text) from public;
revoke all on function public.g151_get_room(text) from public;

do $$ begin
  if exists (select 1 from pg_roles where rolname = 'anon') then
    revoke all on function public.g151_do_pick(public.g151_rooms, int, int, text, boolean) from anon, authenticated;
    revoke all on function public.g151_best_pick(uuid, int) from anon, authenticated;
    revoke all on function public.g151_style_mult(text, text) from anon, authenticated;
    revoke all on function public.g151_star(numeric, numeric) from anon, authenticated;
    grant execute on function public.g151_create_room(int, int, text, text) to authenticated;
    grant execute on function public.g151_join_room(text, text) to authenticated;
    grant execute on function public.g151_start_room(text) to authenticated;
    grant execute on function public.g151_make_pick(text, int, text) to authenticated;
    grant execute on function public.g151_tick(text) to authenticated;
    grant execute on function public.g151_get_room(text) to anon, authenticated;
  end if;
end $$;

-- ---------- live updates ----------
do $$
declare t text;
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    foreach t in array array['g151_rooms', 'g151_seats', 'g151_picks'] loop
      if not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
        execute format('alter publication supabase_realtime add table public.%I', t);
      end if;
    end loop;
  end if;
end $$;
