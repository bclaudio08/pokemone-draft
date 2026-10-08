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

alter table public.g151_rooms add column if not exists pool text not null default 'gen1';
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'g151_rooms_pool_check') then
    alter table public.g151_rooms add constraint g151_rooms_pool_check check (pool in ('gen1', 'all'));
  end if;
end $$;

-- ratings are pure reference data (reloaded at the bottom of this script), one set per draft pool
drop table if exists public.g151_ratings;
create table public.g151_ratings (
  pool text not null,
  pid  int  not null,
  pos  text not null,
  ovr  int  not null,
  primary key (pool, pid, pos)
);

drop table if exists public.g151_pokemon;
create table public.g151_pokemon (
  pool  text not null,
  pid   int  not null,
  types text[] not null,
  primary key (pool, pid)
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
  v_style text; v_fav text; k numeric; v_pool text;
begin
  select coalesce(style, 'balanced'), fav_type into v_style, v_fav from g151_seats where room_id = p_room_id and seat = p_seat;
  select coalesce(pool, 'gen1') into v_pool from g151_rooms where id = p_room_id;
  k := case when v_style = 'stars' then 2.4 else 1 end;
  with avail as materialized (
    select r.pid, r.pos, r.ovr from g151_ratings r
    where r.pool = v_pool and not exists (select 1 from g151_picks p where p.room_id = p_room_id and p.pid = r.pid)
  ), demand as materialized (
    select s.pos, count(*)::int as d
    from g151_seats se cross join g151_slots s
    where se.room_id = p_room_id
      and not exists (select 1 from g151_picks p where p.room_id = p_room_id and p.seat = se.seat and p.slot = s.slot)
    group by s.pos
  ), ranked as materialized (
    select a.pos, a.ovr, (row_number() over (partition by a.pos order by a.ovr desc) - 1)::int as rk,
           count(*) over (partition by a.pos)::int as cnt
    from avail a
  ), repl as materialized (
    -- replacement level: the player who'd be left at each position once every open spot league-wide is filled
    select d.pos, coalesce(max(r.ovr) filter (where r.rk = least(d.d, r.cnt - 1)), 40) as rv
    from demand d left join ranked r on r.pos = d.pos
    group by d.pos
  ), open_slots as materialized (
    select distinct on (s.pos) s.slot, s.pos from g151_slots s
    where not exists (select 1 from g151_picks p where p.room_id = p_room_id and p.seat = p_seat and p.slot = s.slot)
    order by s.pos, s.slot
  )
  select a.pid, o.slot into pid, slot
  from avail a
  join open_slots o on o.pos = a.pos
  join repl rp on rp.pos = a.pos
  left join g151_pokemon pk on pk.pool = v_pool and pk.pid = a.pid
  order by (g151_star(a.ovr, k) - g151_star(rp.rv, k)) * g151_style_mult(v_style, a.pos)
         + (case when v_style = 'loyal' and v_fav is not null and v_fav = any(pk.types) then 7 else 0 end)
         + random() * 4 - 2 desc
  limit 1;
end $$;

-- ---------- functions the website calls ----------
drop function if exists public.g151_create_room(int, int, text);
drop function if exists public.g151_create_room(int, int, text, text);
create or replace function public.g151_create_room(p_num_teams int, p_pick_seconds int, p_team_name text, p_draft_type text default 'snake', p_pool text default 'gen1')
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
  if coalesce(p_pool, 'gen1') not in ('gen1', 'all') then raise exception 'Invalid Pokémon pool'; end if;

  loop
    v_code := '';
    for i in 1..4 loop
      v_code := v_code || substr(alphabet, 1 + floor(random() * length(alphabet))::int, 1);
    end loop;
    begin
      insert into g151_rooms (code, host, num_teams, pick_seconds, draft_type, pool)
      values (v_code, uid, p_num_teams, p_pick_seconds, coalesce(p_draft_type, 'snake'), coalesce(p_pool, 'gen1')) returning id into v_id;
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
  if not exists (select 1 from g151_ratings where pool = r.pool and pid = p_pid) then raise exception 'That Pokémon isn''t in this draft''s pool'; end if;
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
        'id', id, 'code', code, 'num_teams', num_teams, 'pick_seconds', pick_seconds, 'draft_type', draft_type, 'pool', pool,
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
revoke all on function public.g151_create_room(int, int, text, text, text) from public;
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
    grant execute on function public.g151_create_room(int, int, text, text, text) to authenticated;
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

-- ---------- ratings and roster spots (generated by scripts/build_sql.py) ----------
delete from public.g151_slots;
insert into public.g151_slots (slot, pos) values
  ('QB', 'QB'),
  ('RB', 'RB'),
  ('WR1', 'WR'),
  ('WR2', 'WR'),
  ('WR3', 'WR'),
  ('TE', 'TE'),
  ('LT', 'OL'),
  ('LG', 'OL'),
  ('C', 'OL'),
  ('RG', 'OL'),
  ('RT', 'OL'),
  ('LDE', 'DL'),
  ('LDT', 'DL'),
  ('RDT', 'DL'),
  ('RDE', 'DL'),
  ('WLB', 'LB'),
  ('MLB', 'LB'),
  ('SLB', 'LB'),
  ('CB1', 'CB'),
  ('CB2', 'CB'),
  ('FS', 'S'),
  ('SS', 'S');

insert into public.g151_ratings (pool, pid, pos, ovr) values
('gen1',1,'QB',64),('gen1',1,'RB',59),('gen1',1,'WR',60),('gen1',1,'TE',58),('gen1',1,'OL',59),('gen1',1,'DL',58),('gen1',1,'LB',58),('gen1',1,'CB',60),('gen1',1,'S',59),
('gen1',2,'QB',74),('gen1',2,'RB',68),('gen1',2,'WR',68),('gen1',2,'TE',68),('gen1',2,'OL',68),('gen1',2,'DL',67),('gen1',2,'LB',68),('gen1',2,'CB',69),('gen1',2,'S',69),
('gen1',3,'QB',85),('gen1',3,'RB',80),('gen1',3,'WR',79),('gen1',3,'TE',83),('gen1',3,'OL',83),('gen1',3,'DL',81),('gen1',3,'LB',81),('gen1',3,'CB',80),('gen1',3,'S',82),
('gen1',4,'QB',62),('gen1',4,'RB',62),('gen1',4,'WR',64),('gen1',4,'TE',59),('gen1',4,'OL',58),('gen1',4,'DL',58),('gen1',4,'LB',58),('gen1',4,'CB',63),('gen1',4,'S',60),
('gen1',5,'QB',73),('gen1',5,'RB',72),('gen1',5,'WR',73),('gen1',5,'TE',70),('gen1',5,'OL',68),('gen1',5,'DL',68),('gen1',5,'LB',69),('gen1',5,'CB',73),('gen1',5,'S',70),
('gen1',6,'QB',86),('gen1',6,'RB',85),('gen1',6,'WR',85),('gen1',6,'TE',84),('gen1',6,'OL',82),('gen1',6,'DL',81),('gen1',6,'LB',82),('gen1',6,'CB',85),('gen1',6,'S',84),
('gen1',7,'QB',61),('gen1',7,'RB',58),('gen1',7,'WR',59),('gen1',7,'TE',58),('gen1',7,'OL',60),('gen1',7,'DL',59),('gen1',7,'LB',59),('gen1',7,'CB',59),('gen1',7,'S',60),
('gen1',8,'QB',71),('gen1',8,'RB',67),('gen1',8,'WR',68),('gen1',8,'TE',69),('gen1',8,'OL',71),('gen1',8,'DL',69),('gen1',8,'LB',69),('gen1',8,'CB',69),('gen1',8,'S',70),
('gen1',9,'QB',83),('gen1',9,'RB',80),('gen1',9,'WR',79),('gen1',9,'TE',83),('gen1',9,'OL',84),('gen1',9,'DL',82),('gen1',9,'LB',83),('gen1',9,'CB',81),('gen1',9,'S',84),
('gen1',10,'QB',47),('gen1',10,'RB',51),('gen1',10,'WR',53),('gen1',10,'TE',47),('gen1',10,'OL',46),('gen1',10,'DL',47),('gen1',10,'LB',47),('gen1',10,'CB',51),('gen1',10,'S',47),
('gen1',11,'QB',49),('gen1',11,'RB',47),('gen1',11,'WR',48),('gen1',11,'TE',49),('gen1',11,'OL',53),('gen1',11,'DL',49),('gen1',11,'LB',48),('gen1',11,'CB',48),('gen1',11,'S',48),
('gen1',12,'QB',76),('gen1',12,'RB',69),('gen1',12,'WR',71),('gen1',12,'TE',69),('gen1',12,'OL',68),('gen1',12,'DL',64),('gen1',12,'LB',66),('gen1',12,'CB',70),('gen1',12,'S',69),
('gen1',13,'QB',47),('gen1',13,'RB',52),('gen1',13,'WR',54),('gen1',13,'TE',47),('gen1',13,'OL',47),('gen1',13,'DL',48),('gen1',13,'LB',47),('gen1',13,'CB',53),('gen1',13,'S',48),
('gen1',14,'QB',49),('gen1',14,'RB',48),('gen1',14,'WR',50),('gen1',14,'TE',49),('gen1',14,'OL',53),('gen1',14,'DL',50),('gen1',14,'LB',49),('gen1',14,'CB',49),('gen1',14,'S',48),
('gen1',15,'QB',68),('gen1',15,'RB',73),('gen1',15,'WR',72),('gen1',15,'TE',71),('gen1',15,'OL',70),('gen1',15,'DL',71),('gen1',15,'LB',72),('gen1',15,'CB',71),('gen1',15,'S',72),
('gen1',16,'QB',54),('gen1',16,'RB',58),('gen1',16,'WR',60),('gen1',16,'TE',51),('gen1',16,'OL',50),('gen1',16,'DL',52),('gen1',16,'LB',53),('gen1',16,'CB',59),('gen1',16,'S',54),
('gen1',17,'QB',63),('gen1',17,'RB',67),('gen1',17,'WR',68),('gen1',17,'TE',66),('gen1',17,'OL',66),('gen1',17,'DL',65),('gen1',17,'LB',64),('gen1',17,'CB',67),('gen1',17,'S',65),
('gen1',18,'QB',75),('gen1',18,'RB',82),('gen1',18,'WR',83),('gen1',18,'TE',80),('gen1',18,'OL',76),('gen1',18,'DL',77),('gen1',18,'LB',78),('gen1',18,'CB',82),('gen1',18,'S',80),
('gen1',19,'QB',52),('gen1',19,'RB',62),('gen1',19,'WR',64),('gen1',19,'TE',55),('gen1',19,'OL',52),('gen1',19,'DL',55),('gen1',19,'LB',56),('gen1',19,'CB',62),('gen1',19,'S',57),
('gen1',20,'QB',69),('gen1',20,'RB',78),('gen1',20,'WR',79),('gen1',20,'TE',73),('gen1',20,'OL',70),('gen1',20,'DL',71),('gen1',20,'LB',74),('gen1',20,'CB',79),('gen1',20,'S',75),
('gen1',21,'QB',54),('gen1',21,'RB',62),('gen1',21,'WR',64),('gen1',21,'TE',54),('gen1',21,'OL',51),('gen1',21,'DL',55),('gen1',21,'LB',56),('gen1',21,'CB',62),('gen1',21,'S',56),
('gen1',22,'QB',72),('gen1',22,'RB',80),('gen1',22,'WR',80),('gen1',22,'TE',77),('gen1',22,'OL',74),('gen1',22,'DL',76),('gen1',22,'LB',77),('gen1',22,'CB',80),('gen1',22,'S',77),
('gen1',23,'QB',58),('gen1',23,'RB',60),('gen1',23,'WR',61),('gen1',23,'TE',59),('gen1',23,'OL',60),('gen1',23,'DL',59),('gen1',23,'LB',58),('gen1',23,'CB',60),('gen1',23,'S',59),
('gen1',24,'QB',74),('gen1',24,'RB',77),('gen1',24,'WR',75),('gen1',24,'TE',78),('gen1',24,'OL',79),('gen1',24,'DL',78),('gen1',24,'LB',78),('gen1',24,'CB',75),('gen1',24,'S',77),
('gen1',25,'QB',62),('gen1',25,'RB',70),('gen1',25,'WR',72),('gen1',25,'TE',62),('gen1',25,'OL',57),('gen1',25,'DL',59),('gen1',25,'LB',61),('gen1',25,'CB',71),('gen1',25,'S',64),
('gen1',26,'QB',81),('gen1',26,'RB',85),('gen1',26,'WR',86),('gen1',26,'TE',79),('gen1',26,'OL',74),('gen1',26,'DL',77),('gen1',26,'LB',79),('gen1',26,'CB',85),('gen1',26,'S',81),
('gen1',27,'QB',52),('gen1',27,'RB',56),('gen1',27,'WR',55),('gen1',27,'TE',60),('gen1',27,'OL',64),('gen1',27,'DL',66),('gen1',27,'LB',62),('gen1',27,'CB',56),('gen1',27,'S',58),
('gen1',28,'QB',67),('gen1',28,'RB',72),('gen1',28,'WR',70),('gen1',28,'TE',75),('gen1',28,'OL',78),('gen1',28,'DL',80),('gen1',28,'LB',79),('gen1',28,'CB',72),('gen1',28,'S',75),
('gen1',29,'QB',55),('gen1',29,'RB',55),('gen1',29,'WR',56),('gen1',29,'TE',54),('gen1',29,'OL',55),('gen1',29,'DL',56),('gen1',29,'LB',55),('gen1',29,'CB',55),('gen1',29,'S',54),
('gen1',30,'QB',65),('gen1',30,'RB',64),('gen1',30,'WR',64),('gen1',30,'TE',65),('gen1',30,'OL',66),('gen1',30,'DL',65),('gen1',30,'LB',65),('gen1',30,'CB',64),('gen1',30,'S',64),
('gen1',31,'QB',78),('gen1',31,'RB',78),('gen1',31,'WR',77),('gen1',31,'TE',81),('gen1',31,'OL',81),('gen1',31,'DL',81),('gen1',31,'LB',81),('gen1',31,'CB',78),('gen1',31,'S',80),
('gen1',32,'QB',56),('gen1',32,'RB',57),('gen1',32,'WR',58),('gen1',32,'TE',56),('gen1',32,'OL',56),('gen1',32,'DL',57),('gen1',32,'LB',56),('gen1',32,'CB',57),('gen1',32,'S',55),
('gen1',33,'QB',65),('gen1',33,'RB',66),('gen1',33,'WR',67),('gen1',33,'TE',66),('gen1',33,'OL',66),('gen1',33,'DL',67),('gen1',33,'LB',66),('gen1',33,'CB',66),('gen1',33,'S',65),
('gen1',34,'QB',79),('gen1',34,'RB',80),('gen1',34,'WR',79),('gen1',34,'TE',81),('gen1',34,'OL',81),('gen1',34,'DL',82),('gen1',34,'LB',82),('gen1',34,'CB',79),('gen1',34,'S',81),
('gen1',35,'QB',64),('gen1',35,'RB',56),('gen1',35,'WR',58),('gen1',35,'TE',57),('gen1',35,'OL',59),('gen1',35,'DL',57),('gen1',35,'LB',57),('gen1',35,'CB',57),('gen1',35,'S',58),
('gen1',36,'QB',81),('gen1',36,'RB',72),('gen1',36,'WR',72),('gen1',36,'TE',75),('gen1',36,'OL',76),('gen1',36,'DL',74),('gen1',36,'LB',75),('gen1',36,'CB',72),('gen1',36,'S',75),
('gen1',37,'QB',62),('gen1',37,'RB',62),('gen1',37,'WR',64),('gen1',37,'TE',59),('gen1',37,'OL',58),('gen1',37,'DL',57),('gen1',37,'LB',57),('gen1',37,'CB',64),('gen1',37,'S',60),
('gen1',38,'QB',82),('gen1',38,'RB',84),('gen1',38,'WR',85),('gen1',38,'TE',80),('gen1',38,'OL',76),('gen1',38,'DL',76),('gen1',38,'LB',79),('gen1',38,'CB',86),('gen1',38,'S',84),
('gen1',39,'QB',54),('gen1',39,'RB',49),('gen1',39,'WR',51),('gen1',39,'TE',50),('gen1',39,'OL',52),('gen1',39,'DL',52),('gen1',39,'LB',50),('gen1',39,'CB',47),('gen1',39,'S',47),
('gen1',40,'QB',73),('gen1',40,'RB',66),('gen1',40,'WR',66),('gen1',40,'TE',67),('gen1',40,'OL',67),('gen1',40,'DL',67),('gen1',40,'LB',67),('gen1',40,'CB',62),('gen1',40,'S',64),
('gen1',41,'QB',53),('gen1',41,'RB',57),('gen1',41,'WR',58),('gen1',41,'TE',54),('gen1',41,'OL',54),('gen1',41,'DL',54),('gen1',41,'LB',53),('gen1',41,'CB',57),('gen1',41,'S',54),
('gen1',42,'QB',74),('gen1',42,'RB',79),('gen1',42,'WR',79),('gen1',42,'TE',78),('gen1',42,'OL',76),('gen1',42,'DL',76),('gen1',42,'LB',76),('gen1',42,'CB',78),('gen1',42,'S',77),
('gen1',43,'QB',66),('gen1',43,'RB',55),('gen1',43,'WR',55),('gen1',43,'TE',56),('gen1',43,'OL',58),('gen1',43,'DL',58),('gen1',43,'LB',58),('gen1',43,'CB',56),('gen1',43,'S',57),
('gen1',44,'QB',73),('gen1',44,'RB',63),('gen1',44,'WR',62),('gen1',44,'TE',64),('gen1',44,'OL',66),('gen1',44,'DL',66),('gen1',44,'LB',66),('gen1',44,'CB',63),('gen1',44,'S',66),
('gen1',45,'QB',84),('gen1',45,'RB',71),('gen1',45,'WR',69),('gen1',45,'TE',74),('gen1',45,'OL',76),('gen1',45,'DL',76),('gen1',45,'LB',77),('gen1',45,'CB',70),('gen1',45,'S',76),
('gen1',46,'QB',58),('gen1',46,'RB',53),('gen1',46,'WR',52),('gen1',46,'TE',54),('gen1',46,'OL',57),('gen1',46,'DL',59),('gen1',46,'LB',58),('gen1',46,'CB',52),('gen1',46,'S',55),
('gen1',47,'QB',70),('gen1',47,'RB',62),('gen1',47,'WR',59),('gen1',47,'TE',68),('gen1',47,'OL',75),('gen1',47,'DL',74),('gen1',47,'LB',73),('gen1',47,'CB',60),('gen1',47,'S',68),
('gen1',48,'QB',59),('gen1',48,'RB',58),('gen1',48,'WR',58),('gen1',48,'TE',61),('gen1',48,'OL',63),('gen1',48,'DL',61),('gen1',48,'LB',59),('gen1',48,'CB',58),('gen1',48,'S',58),
('gen1',49,'QB',78),('gen1',49,'RB',78),('gen1',49,'WR',79),('gen1',49,'TE',74),('gen1',49,'OL',70),('gen1',49,'DL',70),('gen1',49,'LB',72),('gen1',49,'CB',79),('gen1',49,'S',76),
('gen1',50,'QB',57),('gen1',50,'RB',69),('gen1',50,'WR',72),('gen1',50,'TE',54),('gen1',50,'OL',47),('gen1',50,'DL',53),('gen1',50,'LB',57),('gen1',50,'CB',71),('gen1',50,'S',61),
('gen1',51,'QB',70),('gen1',51,'RB',85),('gen1',51,'WR',85),('gen1',51,'TE',77),('gen1',51,'OL',72),('gen1',51,'DL',76),('gen1',51,'LB',78),('gen1',51,'CB',85),('gen1',51,'S',80),
('gen1',52,'QB',58),('gen1',52,'RB',68),('gen1',52,'WR',71),('gen1',52,'TE',59),('gen1',52,'OL',53),('gen1',52,'DL',56),('gen1',52,'LB',57),('gen1',52,'CB',69),('gen1',52,'S',61),
('gen1',53,'QB',73),('gen1',53,'RB',83),('gen1',53,'WR',85),('gen1',53,'TE',77),('gen1',53,'OL',71),('gen1',53,'DL',72),('gen1',53,'LB',75),('gen1',53,'CB',84),('gen1',53,'S',78),
('gen1',54,'QB',63),('gen1',54,'RB',60),('gen1',54,'WR',61),('gen1',54,'TE',61),('gen1',54,'OL',61),('gen1',54,'DL',60),('gen1',54,'LB',59),('gen1',54,'CB',61),('gen1',54,'S',59),
('gen1',55,'QB',82),('gen1',55,'RB',79),('gen1',55,'WR',79),('gen1',55,'TE',81),('gen1',55,'OL',80),('gen1',55,'DL',79),('gen1',55,'LB',79),('gen1',55,'CB',79),('gen1',55,'S',80),
('gen1',56,'QB',57),('gen1',56,'RB',65),('gen1',56,'WR',65),('gen1',56,'TE',63),('gen1',56,'OL',62),('gen1',56,'DL',65),('gen1',56,'LB',63),('gen1',56,'CB',64),('gen1',56,'S',61),
('gen1',57,'QB',73),('gen1',57,'RB',81),('gen1',57,'WR',80),('gen1',57,'TE',78),('gen1',57,'OL',75),('gen1',57,'DL',78),('gen1',57,'LB',79),('gen1',57,'CB',80),('gen1',57,'S',79),
('gen1',58,'QB',66),('gen1',58,'RB',64),('gen1',58,'WR',64),('gen1',58,'TE',64),('gen1',58,'OL',64),('gen1',58,'DL',65),('gen1',58,'LB',63),('gen1',58,'CB',63),('gen1',58,'S',62),
('gen1',59,'QB',85),('gen1',59,'RB',86),('gen1',59,'WR',84),('gen1',59,'TE',88),('gen1',59,'OL',86),('gen1',59,'DL',87),('gen1',59,'LB',87),('gen1',59,'CB',84),('gen1',59,'S',85),
('gen1',60,'QB',58),('gen1',60,'RB',68),('gen1',60,'WR',71),('gen1',60,'TE',62),('gen1',60,'OL',58),('gen1',60,'DL',59),('gen1',60,'LB',59),('gen1',60,'CB',69),('gen1',60,'S',62),
('gen1',61,'QB',65),('gen1',61,'RB',73),('gen1',61,'WR',75),('gen1',61,'TE',70),('gen1',61,'OL',68),('gen1',61,'DL',68),('gen1',61,'LB',68),('gen1',61,'CB',74),('gen1',61,'S',70),
('gen1',62,'QB',78),('gen1',62,'RB',78),('gen1',62,'WR',76),('gen1',62,'TE',81),('gen1',62,'OL',82),('gen1',62,'DL',82),('gen1',62,'LB',82),('gen1',62,'CB',77),('gen1',62,'S',81),
('gen1',63,'QB',72),('gen1',63,'RB',67),('gen1',63,'WR',71),('gen1',63,'TE',60),('gen1',63,'OL',55),('gen1',63,'DL',53),('gen1',63,'LB',55),('gen1',63,'CB',69),('gen1',63,'S',60),
('gen1',64,'QB',81),('gen1',64,'RB',76),('gen1',64,'WR',79),('gen1',64,'TE',71),('gen1',64,'OL',66),('gen1',64,'DL',62),('gen1',64,'LB',65),('gen1',64,'CB',78),('gen1',64,'S',70),
('gen1',65,'QB',92),('gen1',65,'RB',87),('gen1',65,'WR',90),('gen1',65,'TE',80),('gen1',65,'OL',73),('gen1',65,'DL',71),('gen1',65,'LB',75),('gen1',65,'CB',89),('gen1',65,'S',82),
('gen1',66,'QB',55),('gen1',66,'RB',56),('gen1',66,'WR',55),('gen1',66,'TE',59),('gen1',66,'OL',63),('gen1',66,'DL',64),('gen1',66,'LB',61),('gen1',66,'CB',54),('gen1',66,'S',56),
('gen1',67,'QB',65),('gen1',67,'RB',65),('gen1',67,'WR',62),('gen1',67,'TE',71),('gen1',67,'OL',76),('gen1',67,'DL',76),('gen1',67,'LB',73),('gen1',67,'CB',62),('gen1',67,'S',67),
('gen1',68,'QB',76),('gen1',68,'RB',75),('gen1',68,'WR',70),('gen1',68,'TE',81),('gen1',68,'OL',85),('gen1',68,'DL',87),('gen1',68,'LB',85),('gen1',68,'CB',71),('gen1',68,'S',79),
('gen1',69,'QB',61),('gen1',69,'RB',57),('gen1',69,'WR',56),('gen1',69,'TE',55),('gen1',69,'OL',57),('gen1',69,'DL',60),('gen1',69,'LB',58),('gen1',69,'CB',55),('gen1',69,'S',54),
('gen1',70,'QB',70),('gen1',70,'RB',66),('gen1',70,'WR',65),('gen1',70,'TE',65),('gen1',70,'OL',66),('gen1',70,'DL',68),('gen1',70,'LB',68),('gen1',70,'CB',64),('gen1',70,'S',64),
('gen1',71,'QB',81),('gen1',71,'RB',77),('gen1',71,'WR',75),('gen1',71,'TE',76),('gen1',71,'OL',76),('gen1',71,'DL',79),('gen1',71,'LB',79),('gen1',71,'CB',74),('gen1',71,'S',76),
('gen1',72,'QB',67),('gen1',72,'RB',66),('gen1',72,'WR',68),('gen1',72,'TE',65),('gen1',72,'OL',63),('gen1',72,'DL',60),('gen1',72,'LB',61),('gen1',72,'CB',68),('gen1',72,'S',66),
('gen1',73,'QB',84),('gen1',73,'RB',85),('gen1',73,'WR',87),('gen1',73,'TE',83),('gen1',73,'OL',78),('gen1',73,'DL',76),('gen1',73,'LB',80),('gen1',73,'CB',86),('gen1',73,'S',85),
('gen1',74,'QB',53),('gen1',74,'RB',52),('gen1',74,'WR',49),('gen1',74,'TE',59),('gen1',74,'OL',67),('gen1',74,'DL',68),('gen1',74,'LB',63),('gen1',74,'CB',51),('gen1',74,'S',56),
('gen1',75,'QB',62),('gen1',75,'RB',61),('gen1',75,'WR',57),('gen1',75,'TE',71),('gen1',75,'OL',79),('gen1',75,'DL',78),('gen1',75,'LB',73),('gen1',75,'CB',59),('gen1',75,'S',67),
('gen1',76,'QB',71),('gen1',76,'RB',70),('gen1',76,'WR',65),('gen1',76,'TE',82),('gen1',76,'OL',91),('gen1',76,'DL',90),('gen1',76,'LB',85),('gen1',76,'CB',68),('gen1',76,'S',78),
('gen1',77,'QB',69),('gen1',77,'RB',75),('gen1',77,'WR',76),('gen1',77,'TE',73),('gen1',77,'OL',70),('gen1',77,'DL',72),('gen1',77,'LB',71),('gen1',77,'CB',76),('gen1',77,'S',72),
('gen1',78,'QB',80),('gen1',78,'RB',85),('gen1',78,'WR',85),('gen1',78,'TE',84),('gen1',78,'OL',81),('gen1',78,'DL',82),('gen1',78,'LB',83),('gen1',78,'CB',85),('gen1',78,'S',83),
('gen1',79,'QB',56),('gen1',79,'RB',51),('gen1',79,'WR',49),('gen1',79,'TE',60),('gen1',79,'OL',66),('gen1',79,'DL',64),('gen1',79,'LB',59),('gen1',79,'CB',49),('gen1',79,'S',54),
('gen1',80,'QB',80),('gen1',80,'RB',65),('gen1',80,'WR',63),('gen1',80,'TE',75),('gen1',80,'OL',82),('gen1',80,'DL',78),('gen1',80,'LB',77),('gen1',80,'CB',64),('gen1',80,'S',73),
('gen1',81,'QB',69),('gen1',81,'RB',58),('gen1',81,'WR',59),('gen1',81,'TE',57),('gen1',81,'OL',58),('gen1',81,'DL',57),('gen1',81,'LB',57),('gen1',81,'CB',60),('gen1',81,'S',59),
('gen1',82,'QB',83),('gen1',82,'RB',72),('gen1',82,'WR',72),('gen1',82,'TE',75),('gen1',82,'OL',77),('gen1',82,'DL',74),('gen1',82,'LB',74),('gen1',82,'CB',74),('gen1',82,'S',75),
('gen1',83,'QB',68),('gen1',83,'RB',68),('gen1',83,'WR',66),('gen1',83,'TE',67),('gen1',83,'OL',68),('gen1',83,'DL',70),('gen1',83,'LB',70),('gen1',83,'CB',66),('gen1',83,'S',68),
('gen1',84,'QB',57),('gen1',84,'RB',66),('gen1',84,'WR',65),('gen1',84,'TE',65),('gen1',84,'OL',66),('gen1',84,'DL',67),('gen1',84,'LB',64),('gen1',84,'CB',65),('gen1',84,'S',62),
('gen1',85,'QB',72),('gen1',85,'RB',85),('gen1',85,'WR',83),('gen1',85,'TE',83),('gen1',85,'OL',80),('gen1',85,'DL',83),('gen1',85,'LB',82),('gen1',85,'CB',83),('gen1',85,'S',81),
('gen1',86,'QB',62),('gen1',86,'RB',58),('gen1',86,'WR',59),('gen1',86,'TE',64),('gen1',86,'OL',66),('gen1',86,'DL',62),('gen1',86,'LB',60),('gen1',86,'CB',59),('gen1',86,'S',60),
('gen1',87,'QB',77),('gen1',87,'RB',75),('gen1',87,'WR',75),('gen1',87,'TE',79),('gen1',87,'OL',80),('gen1',87,'DL',76),('gen1',87,'LB',77),('gen1',87,'CB',75),('gen1',87,'S',78),
('gen1',88,'QB',58),('gen1',88,'RB',55),('gen1',88,'WR',53),('gen1',88,'TE',61),('gen1',88,'OL',65),('gen1',88,'DL',65),('gen1',88,'LB',62),('gen1',88,'CB',52),('gen1',88,'S',56),
('gen1',89,'QB',77),('gen1',89,'RB',73),('gen1',89,'WR',71),('gen1',89,'TE',77),('gen1',89,'OL',79),('gen1',89,'DL',80),('gen1',89,'LB',80),('gen1',89,'CB',71),('gen1',89,'S',78),
('gen1',90,'QB',56),('gen1',90,'RB',56),('gen1',90,'WR',56),('gen1',90,'TE',57),('gen1',90,'OL',61),('gen1',90,'DL',64),('gen1',90,'LB',61),('gen1',90,'CB',57),('gen1',90,'S',58),
('gen1',91,'QB',76),('gen1',91,'RB',75),('gen1',91,'WR',72),('gen1',91,'TE',83),('gen1',91,'OL',90),('gen1',91,'DL',90),('gen1',91,'LB',86),('gen1',91,'CB',77),('gen1',91,'S',83),
('gen1',92,'QB',69),('gen1',92,'RB',67),('gen1',92,'WR',71),('gen1',92,'TE',52),('gen1',92,'OL',46),('gen1',92,'DL',49),('gen1',92,'LB',53),('gen1',92,'CB',69),('gen1',92,'S',59),
('gen1',93,'QB',79),('gen1',93,'RB',76),('gen1',93,'WR',80),('gen1',93,'TE',61),('gen1',93,'OL',53),('gen1',93,'DL',57),('gen1',93,'LB',63),('gen1',93,'CB',79),('gen1',93,'S',70),
('gen1',94,'QB',88),('gen1',94,'RB',85),('gen1',94,'WR',86),('gen1',94,'TE',80),('gen1',94,'OL',75),('gen1',94,'DL',74),('gen1',94,'LB',77),('gen1',94,'CB',86),('gen1',94,'S',81),
('gen1',95,'QB',61),('gen1',95,'RB',66),('gen1',95,'WR',66),('gen1',95,'TE',75),('gen1',95,'OL',81),('gen1',95,'DL',76),('gen1',95,'LB',73),('gen1',95,'CB',71),('gen1',95,'S',74),
('gen1',96,'QB',64),('gen1',96,'RB',59),('gen1',96,'WR',60),('gen1',96,'TE',62),('gen1',96,'OL',64),('gen1',96,'DL',60),('gen1',96,'LB',60),('gen1',96,'CB',60),('gen1',96,'S',61),
('gen1',97,'QB',80),('gen1',97,'RB',75),('gen1',97,'WR',75),('gen1',97,'TE',79),('gen1',97,'OL',79),('gen1',97,'DL',75),('gen1',97,'LB',77),('gen1',97,'CB',75),('gen1',97,'S',79),
('gen1',98,'QB',53),('gen1',98,'RB',62),('gen1',98,'WR',59),('gen1',98,'TE',62),('gen1',98,'OL',66),('gen1',98,'DL',71),('gen1',98,'LB',68),('gen1',98,'CB',60),('gen1',98,'S',62),
('gen1',99,'QB',69),('gen1',99,'RB',77),('gen1',99,'WR',73),('gen1',99,'TE',81),('gen1',99,'OL',85),('gen1',99,'DL',89),('gen1',99,'LB',85),('gen1',99,'CB',75),('gen1',99,'S',79),
('gen1',100,'QB',64),('gen1',100,'RB',71),('gen1',100,'WR',76),('gen1',100,'TE',64),('gen1',100,'OL',58),('gen1',100,'DL',57),('gen1',100,'LB',60),('gen1',100,'CB',75),('gen1',100,'S',66),
('gen1',101,'QB',80),('gen1',101,'RB',92),('gen1',101,'WR',96),('gen1',101,'TE',84),('gen1',101,'OL',75),('gen1',101,'DL',74),('gen1',101,'LB',77),('gen1',101,'CB',96),('gen1',101,'S',86),
('gen1',102,'QB',62),('gen1',102,'RB',57),('gen1',102,'WR',59),('gen1',102,'TE',56),('gen1',102,'OL',58),('gen1',102,'DL',58),('gen1',102,'LB',58),('gen1',102,'CB',59),('gen1',102,'S',58),
('gen1',103,'QB',87),('gen1',103,'RB',73),('gen1',103,'WR',71),('gen1',103,'TE',80),('gen1',103,'OL',84),('gen1',103,'DL',83),('gen1',103,'LB',81),('gen1',103,'CB',71),('gen1',103,'S',77),
('gen1',104,'QB',58),('gen1',104,'RB',56),('gen1',104,'WR',56),('gen1',104,'TE',58),('gen1',104,'OL',62),('gen1',104,'DL',62),('gen1',104,'LB',60),('gen1',104,'CB',58),('gen1',104,'S',59),
('gen1',105,'QB',69),('gen1',105,'RB',66),('gen1',105,'WR',64),('gen1',105,'TE',72),('gen1',105,'OL',78),('gen1',105,'DL',76),('gen1',105,'LB',75),('gen1',105,'CB',66),('gen1',105,'S',73),
('gen1',106,'QB',72),('gen1',106,'RB',82),('gen1',106,'WR',79),('gen1',106,'TE',80),('gen1',106,'OL',78),('gen1',106,'DL',81),('gen1',106,'LB',82),('gen1',106,'CB',79),('gen1',106,'S',82),
('gen1',107,'QB',72),('gen1',107,'RB',78),('gen1',107,'WR',76),('gen1',107,'TE',79),('gen1',107,'OL',80),('gen1',107,'DL',80),('gen1',107,'LB',81),('gen1',107,'CB',77),('gen1',107,'S',81),
('gen1',108,'QB',68),('gen1',108,'RB',59),('gen1',108,'WR',58),('gen1',108,'TE',67),('gen1',108,'OL',72),('gen1',108,'DL',67),('gen1',108,'LB',66),('gen1',108,'CB',58),('gen1',108,'S',65),
('gen1',109,'QB',62),('gen1',109,'RB',58),('gen1',109,'WR',58),('gen1',109,'TE',57),('gen1',109,'OL',60),('gen1',109,'DL',63),('gen1',109,'LB',62),('gen1',109,'CB',59),('gen1',109,'S',61),
('gen1',110,'QB',78),('gen1',110,'RB',73),('gen1',110,'WR',72),('gen1',110,'TE',76),('gen1',110,'OL',79),('gen1',110,'DL',79),('gen1',110,'LB',80),('gen1',110,'CB',74),('gen1',110,'S',78),
('gen1',111,'QB',55),('gen1',111,'RB',54),('gen1',111,'WR',52),('gen1',111,'TE',66),('gen1',111,'OL',74),('gen1',111,'DL',73),('gen1',111,'LB',66),('gen1',111,'CB',53),('gen1',111,'S',59),
('gen1',112,'QB',67),('gen1',112,'RB',69),('gen1',112,'WR',63),('gen1',112,'TE',80),('gen1',112,'OL',88),('gen1',112,'DL',89),('gen1',112,'LB',84),('gen1',112,'CB',65),('gen1',112,'S',74),
('gen1',113,'QB',70),('gen1',113,'RB',67),('gen1',113,'WR',74),('gen1',113,'TE',69),('gen1',113,'OL',63),('gen1',113,'DL',55),('gen1',113,'LB',60),('gen1',113,'CB',66),('gen1',113,'S',65),
('gen1',114,'QB',75),('gen1',114,'RB',67),('gen1',114,'WR',67),('gen1',114,'TE',71),('gen1',114,'OL',75),('gen1',114,'DL',72),('gen1',114,'LB',71),('gen1',114,'CB',68),('gen1',114,'S',70),
('gen1',115,'QB',71),('gen1',115,'RB',81),('gen1',115,'WR',81),('gen1',115,'TE',83),('gen1',115,'OL',82),('gen1',115,'DL',81),('gen1',115,'LB',81),('gen1',115,'CB',80),('gen1',115,'S',81),
('gen1',116,'QB',61),('gen1',116,'RB',59),('gen1',116,'WR',60),('gen1',116,'TE',57),('gen1',116,'OL',58),('gen1',116,'DL',58),('gen1',116,'LB',57),('gen1',116,'CB',61),('gen1',116,'S',57),
('gen1',117,'QB',76),('gen1',117,'RB',75),('gen1',117,'WR',75),('gen1',117,'TE',74),('gen1',117,'OL',74),('gen1',117,'DL',73),('gen1',117,'LB',73),('gen1',117,'CB',76),('gen1',117,'S',74),
('gen1',118,'QB',58),('gen1',118,'RB',63),('gen1',118,'WR',64),('gen1',118,'TE',62),('gen1',118,'OL',63),('gen1',118,'DL',64),('gen1',118,'LB',63),('gen1',118,'CB',64),('gen1',118,'S',62),
('gen1',119,'QB',73),('gen1',119,'RB',74),('gen1',119,'WR',72),('gen1',119,'TE',75),('gen1',119,'OL',75),('gen1',119,'DL',76),('gen1',119,'LB',76),('gen1',119,'CB',72),('gen1',119,'S',74),
('gen1',120,'QB',67),('gen1',120,'RB',68),('gen1',120,'WR',71),('gen1',120,'TE',66),('gen1',120,'OL',64),('gen1',120,'DL',63),('gen1',120,'LB',63),('gen1',120,'CB',71),('gen1',120,'S',65),
('gen1',121,'QB',85),('gen1',121,'RB',87),('gen1',121,'WR',88),('gen1',121,'TE',84),('gen1',121,'OL',80),('gen1',121,'DL',80),('gen1',121,'LB',82),('gen1',121,'CB',89),('gen1',121,'S',86),
('gen1',122,'QB',85),('gen1',122,'RB',78),('gen1',122,'WR',80),('gen1',122,'TE',77),('gen1',122,'OL',74),('gen1',122,'DL',69),('gen1',122,'LB',73),('gen1',122,'CB',81),('gen1',122,'S',80),
('gen1',123,'QB',75),('gen1',123,'RB',86),('gen1',123,'WR',85),('gen1',123,'TE',84),('gen1',123,'OL',82),('gen1',123,'DL',84),('gen1',123,'LB',84),('gen1',123,'CB',85),('gen1',123,'S',84),
('gen1',124,'QB',85),('gen1',124,'RB',79),('gen1',124,'WR',81),('gen1',124,'TE',75),('gen1',124,'OL',70),('gen1',124,'DL',67),('gen1',124,'LB',71),('gen1',124,'CB',80),('gen1',124,'S',76),
('gen1',125,'QB',83),('gen1',125,'RB',85),('gen1',125,'WR',85),('gen1',125,'TE',80),('gen1',125,'OL',75),('gen1',125,'DL',76),('gen1',125,'LB',79),('gen1',125,'CB',85),('gen1',125,'S',81),
('gen1',126,'QB',83),('gen1',126,'RB',82),('gen1',126,'WR',82),('gen1',126,'TE',80),('gen1',126,'OL',77),('gen1',126,'DL',78),('gen1',126,'LB',80),('gen1',126,'CB',81),('gen1',126,'S',81),
('gen1',127,'QB',73),('gen1',127,'RB',82),('gen1',127,'WR',78),('gen1',127,'TE',83),('gen1',127,'OL',84),('gen1',127,'DL',88),('gen1',127,'LB',86),('gen1',127,'CB',80),('gen1',127,'S',83),
('gen1',128,'QB',71),('gen1',128,'RB',86),('gen1',128,'WR',86),('gen1',128,'TE',85),('gen1',128,'OL',82),('gen1',128,'DL',84),('gen1',128,'LB',84),('gen1',128,'CB',86),('gen1',128,'S',84),
('gen1',129,'QB',47),('gen1',129,'RB',58),('gen1',129,'WR',62),('gen1',129,'TE',54),('gen1',129,'OL',52),('gen1',129,'DL',49),('gen1',129,'LB',49),('gen1',129,'CB',62),('gen1',129,'S',53),
('gen1',130,'QB',78),('gen1',130,'RB',83),('gen1',130,'WR',80),('gen1',130,'TE',89),('gen1',130,'OL',91),('gen1',130,'DL',90),('gen1',130,'LB',88),('gen1',130,'CB',80),('gen1',130,'S',85),
('gen1',131,'QB',82),('gen1',131,'RB',76),('gen1',131,'WR',74),('gen1',131,'TE',84),('gen1',131,'OL',85),('gen1',131,'DL',82),('gen1',131,'LB',81),('gen1',131,'CB',74),('gen1',131,'S',79),
('gen1',132,'QB',60),('gen1',132,'RB',59),('gen1',132,'WR',59),('gen1',132,'TE',55),('gen1',132,'OL',55),('gen1',132,'DL',56),('gen1',132,'LB',58),('gen1',132,'CB',58),('gen1',132,'S',58),
('gen1',133,'QB',62),('gen1',133,'RB',62),('gen1',133,'WR',63),('gen1',133,'TE',59),('gen1',133,'OL',58),('gen1',133,'DL',59),('gen1',133,'LB',60),('gen1',133,'CB',63),('gen1',133,'S',61),
('gen1',134,'QB',86),('gen1',134,'RB',76),('gen1',134,'WR',77),('gen1',134,'TE',77),('gen1',134,'OL',74),('gen1',134,'DL',72),('gen1',134,'LB',75),('gen1',134,'CB',75),('gen1',134,'S',77),
('gen1',135,'QB',88),('gen1',135,'RB',91),('gen1',135,'WR',94),('gen1',135,'TE',83),('gen1',135,'OL',74),('gen1',135,'DL',74),('gen1',135,'LB',79),('gen1',135,'CB',94),('gen1',135,'S',87),
('gen1',136,'QB',85),('gen1',136,'RB',79),('gen1',136,'WR',76),('gen1',136,'TE',79),('gen1',136,'OL',80),('gen1',136,'DL',84),('gen1',136,'LB',85),('gen1',136,'CB',76),('gen1',136,'S',82),
('gen1',137,'QB',74),('gen1',137,'RB',63),('gen1',137,'WR',61),('gen1',137,'TE',66),('gen1',137,'OL',70),('gen1',137,'DL',67),('gen1',137,'LB',67),('gen1',137,'CB',62),('gen1',137,'S',66),
('gen1',138,'QB',69),('gen1',138,'RB',56),('gen1',138,'WR',57),('gen1',138,'TE',59),('gen1',138,'OL',63),('gen1',138,'DL',62),('gen1',138,'LB',61),('gen1',138,'CB',59),('gen1',138,'S',61),
('gen1',139,'QB',83),('gen1',139,'RB',70),('gen1',139,'WR',70),('gen1',139,'TE',75),('gen1',139,'OL',79),('gen1',139,'DL',77),('gen1',139,'LB',76),('gen1',139,'CB',72),('gen1',139,'S',76),
('gen1',140,'QB',62),('gen1',140,'RB',63),('gen1',140,'WR',62),('gen1',140,'TE',64),('gen1',140,'OL',67),('gen1',140,'DL',69),('gen1',140,'LB',67),('gen1',140,'CB',64),('gen1',140,'S',65),
('gen1',141,'QB',74),('gen1',141,'RB',80),('gen1',141,'WR',77),('gen1',141,'TE',81),('gen1',141,'OL',83),('gen1',141,'DL',85),('gen1',141,'LB',84),('gen1',141,'CB',78),('gen1',141,'S',81),
('gen1',142,'QB',76),('gen1',142,'RB',92),('gen1',142,'WR',93),('gen1',142,'TE',87),('gen1',142,'OL',80),('gen1',142,'DL',83),('gen1',142,'LB',85),('gen1',142,'CB',92),('gen1',142,'S',87),
('gen1',143,'QB',79),('gen1',143,'RB',70),('gen1',143,'WR',66),('gen1',143,'TE',83),('gen1',143,'OL',88),('gen1',143,'DL',85),('gen1',143,'LB',82),('gen1',143,'CB',65),('gen1',143,'S',76),
('gen1',144,'QB',90),('gen1',144,'RB',85),('gen1',144,'WR',85),('gen1',144,'TE',87),('gen1',144,'OL',86),('gen1',144,'DL',84),('gen1',144,'LB',87),('gen1',144,'CB',87),('gen1',144,'S',90),
('gen1',145,'QB',92),('gen1',145,'RB',88),('gen1',145,'WR',88),('gen1',145,'TE',87),('gen1',145,'OL',84),('gen1',145,'DL',84),('gen1',145,'LB',86),('gen1',145,'CB',88),('gen1',145,'S',88),
('gen1',146,'QB',91),('gen1',146,'RB',86),('gen1',146,'WR',84),('gen1',146,'TE',86),('gen1',146,'OL',85),('gen1',146,'DL',86),('gen1',146,'LB',87),('gen1',146,'CB',85),('gen1',146,'S',87),
('gen1',147,'QB',60),('gen1',147,'RB',59),('gen1',147,'WR',60),('gen1',147,'TE',58),('gen1',147,'OL',59),('gen1',147,'DL',59),('gen1',147,'LB',58),('gen1',147,'CB',59),('gen1',147,'S',58),
('gen1',148,'QB',72),('gen1',148,'RB',72),('gen1',148,'WR',72),('gen1',148,'TE',73),('gen1',148,'OL',73),('gen1',148,'DL',72),('gen1',148,'LB',72),('gen1',148,'CB',72),('gen1',148,'S',72),
('gen1',149,'QB',88),('gen1',149,'RB',86),('gen1',149,'WR',82),('gen1',149,'TE',91),('gen1',149,'OL',93),('gen1',149,'DL',95),('gen1',149,'LB',93),('gen1',149,'CB',83),('gen1',149,'S',89),
('gen1',151,'QB',89),('gen1',151,'RB',91),('gen1',151,'WR',91),('gen1',151,'TE',84),('gen1',151,'OL',78),('gen1',151,'DL',83),('gen1',151,'LB',88),('gen1',151,'CB',91),('gen1',151,'S',91),
('all',1,'QB',63),('all',1,'RB',59),('all',1,'WR',60),('all',1,'TE',58),('all',1,'OL',59),('all',1,'DL',58),('all',1,'LB',58),('all',1,'CB',60),('all',1,'S',59),
('all',2,'QB',71),('all',2,'RB',67),('all',2,'WR',68),('all',2,'TE',67),('all',2,'OL',67),('all',2,'DL',65),('all',2,'LB',66),('all',2,'CB',68),('all',2,'S',67),
('all',3,'QB',82),('all',3,'RB',78),('all',3,'WR',78),('all',3,'TE',80),('all',3,'OL',79),('all',3,'DL',77),('all',3,'LB',78),('all',3,'CB',78),('all',3,'S',80),
('all',4,'QB',61),('all',4,'RB',62),('all',4,'WR',64),('all',4,'TE',59),('all',4,'OL',58),('all',4,'DL',58),('all',4,'LB',58),('all',4,'CB',63),('all',4,'S',59),
('all',5,'QB',71),('all',5,'RB',71),('all',5,'WR',72),('all',5,'TE',69),('all',5,'OL',67),('all',5,'DL',66),('all',5,'LB',67),('all',5,'CB',72),('all',5,'S',69),
('all',6,'QB',83),('all',6,'RB',82),('all',6,'WR',83),('all',6,'TE',81),('all',6,'OL',78),('all',6,'DL',78),('all',6,'LB',79),('all',6,'CB',83),('all',6,'S',81),
('all',7,'QB',61),('all',7,'RB',58),('all',7,'WR',59),('all',7,'TE',59),('all',7,'OL',60),('all',7,'DL',59),('all',7,'LB',59),('all',7,'CB',60),('all',7,'S',60),
('all',8,'QB',69),('all',8,'RB',67),('all',8,'WR',67),('all',8,'TE',68),('all',8,'OL',69),('all',8,'DL',67),('all',8,'LB',67),('all',8,'CB',68),('all',8,'S',68),
('all',9,'QB',80),('all',9,'RB',78),('all',9,'WR',78),('all',9,'TE',80),('all',9,'OL',80),('all',9,'DL',78),('all',9,'LB',80),('all',9,'CB',79),('all',9,'S',81),
('all',10,'QB',47),('all',10,'RB',52),('all',10,'WR',54),('all',10,'TE',49),('all',10,'OL',49),('all',10,'DL',49),('all',10,'LB',48),('all',10,'CB',53),('all',10,'S',48),
('all',11,'QB',49),('all',11,'RB',49),('all',11,'WR',50),('all',11,'TE',50),('all',11,'OL',54),('all',11,'DL',50),('all',11,'LB',49),('all',11,'CB',50),('all',11,'S',49),
('all',12,'QB',74),('all',12,'RB',68),('all',12,'WR',70),('all',12,'TE',67),('all',12,'OL',66),('all',12,'DL',63),('all',12,'LB',65),('all',12,'CB',69),('all',12,'S',68),
('all',13,'QB',47),('all',13,'RB',53),('all',13,'WR',55),('all',13,'TE',49),('all',13,'OL',49),('all',13,'DL',49),('all',13,'LB',49),('all',13,'CB',54),('all',13,'S',49),
('all',14,'QB',49),('all',14,'RB',50),('all',14,'WR',51),('all',14,'TE',51),('all',14,'OL',54),('all',14,'DL',51),('all',14,'LB',50),('all',14,'CB',51),('all',14,'S',49),
('all',15,'QB',66),('all',15,'RB',72),('all',15,'WR',71),('all',15,'TE',69),('all',15,'OL',68),('all',15,'DL',69),('all',15,'LB',70),('all',15,'CB',70),('all',15,'S',70),
('all',16,'QB',53),('all',16,'RB',58),('all',16,'WR',60),('all',16,'TE',53),('all',16,'OL',51),('all',16,'DL',53),('all',16,'LB',53),('all',16,'CB',59),('all',16,'S',54),
('all',17,'QB',62),('all',17,'RB',66),('all',17,'WR',67),('all',17,'TE',65),('all',17,'OL',65),('all',17,'DL',64),('all',17,'LB',63),('all',17,'CB',66),('all',17,'S',64),
('all',18,'QB',73),('all',18,'RB',80),('all',18,'WR',81),('all',18,'TE',77),('all',18,'OL',74),('all',18,'DL',74),('all',18,'LB',75),('all',18,'CB',80),('all',18,'S',77),
('all',19,'QB',52),('all',19,'RB',62),('all',19,'WR',64),('all',19,'TE',56),('all',19,'OL',53),('all',19,'DL',56),('all',19,'LB',56),('all',19,'CB',63),('all',19,'S',57),
('all',20,'QB',68),('all',20,'RB',77),('all',20,'WR',77),('all',20,'TE',72),('all',20,'OL',68),('all',20,'DL',70),('all',20,'LB',71),('all',20,'CB',77),('all',20,'S',74),
('all',21,'QB',53),('all',21,'RB',62),('all',21,'WR',64),('all',21,'TE',55),('all',21,'OL',52),('all',21,'DL',55),('all',21,'LB',56),('all',21,'CB',62),('all',21,'S',56),
('all',22,'QB',70),('all',22,'RB',78),('all',22,'WR',79),('all',22,'TE',75),('all',22,'OL',72),('all',22,'DL',73),('all',22,'LB',74),('all',22,'CB',78),('all',22,'S',74),
('all',23,'QB',57),('all',23,'RB',60),('all',23,'WR',61),('all',23,'TE',59),('all',23,'OL',60),('all',23,'DL',59),('all',23,'LB',58),('all',23,'CB',60),('all',23,'S',58),
('all',24,'QB',71),('all',24,'RB',75),('all',24,'WR',74),('all',24,'TE',76),('all',24,'OL',76),('all',24,'DL',75),('all',24,'LB',75),('all',24,'CB',74),('all',24,'S',74),
('all',25,'QB',61),('all',25,'RB',69),('all',25,'WR',71),('all',25,'TE',62),('all',25,'OL',58),('all',25,'DL',59),('all',25,'LB',61),('all',25,'CB',70),('all',25,'S',64),
('all',26,'QB',78),('all',26,'RB',83),('all',26,'WR',84),('all',26,'TE',77),('all',26,'OL',72),('all',26,'DL',74),('all',26,'LB',76),('all',26,'CB',83),('all',26,'S',79),
('all',27,'QB',52),('all',27,'RB',57),('all',27,'WR',57),('all',27,'TE',60),('all',27,'OL',64),('all',27,'DL',65),('all',27,'LB',62),('all',27,'CB',57),('all',27,'S',58),
('all',28,'QB',66),('all',28,'RB',71),('all',28,'WR',69),('all',28,'TE',74),('all',28,'OL',76),('all',28,'DL',77),('all',28,'LB',76),('all',28,'CB',70),('all',28,'S',73),
('all',29,'QB',55),('all',29,'RB',56),('all',29,'WR',56),('all',29,'TE',55),('all',29,'OL',57),('all',29,'DL',56),('all',29,'LB',55),('all',29,'CB',56),('all',29,'S',55),
('all',30,'QB',63),('all',30,'RB',64),('all',30,'WR',64),('all',30,'TE',64),('all',30,'OL',65),('all',30,'DL',64),('all',30,'LB',64),('all',30,'CB',64),('all',30,'S',64),
('all',31,'QB',76),('all',31,'RB',76),('all',31,'WR',76),('all',31,'TE',78),('all',31,'OL',78),('all',31,'DL',77),('all',31,'LB',78),('all',31,'CB',76),('all',31,'S',78),
('all',32,'QB',55),('all',32,'RB',58),('all',32,'WR',58),('all',32,'TE',57),('all',32,'OL',57),('all',32,'DL',58),('all',32,'LB',56),('all',32,'CB',58),('all',32,'S',55),
('all',33,'QB',63),('all',33,'RB',66),('all',33,'WR',66),('all',33,'TE',65),('all',33,'OL',65),('all',33,'DL',66),('all',33,'LB',65),('all',33,'CB',66),('all',33,'S',65),
('all',34,'QB',77),('all',34,'RB',79),('all',34,'WR',78),('all',34,'TE',78),('all',34,'OL',78),('all',34,'DL',79),('all',34,'LB',79),('all',34,'CB',78),('all',34,'S',78),
('all',35,'QB',63),('all',35,'RB',57),('all',35,'WR',58),('all',35,'TE',58),('all',35,'OL',59),('all',35,'DL',57),('all',35,'LB',58),('all',35,'CB',57),('all',35,'S',58),
('all',36,'QB',78),('all',36,'RB',71),('all',36,'WR',71),('all',36,'TE',73),('all',36,'OL',73),('all',36,'DL',71),('all',36,'LB',72),('all',36,'CB',71),('all',36,'S',73),
('all',37,'QB',61),('all',37,'RB',62),('all',37,'WR',64),('all',37,'TE',59),('all',37,'OL',58),('all',37,'DL',56),('all',37,'LB',57),('all',37,'CB',64),('all',37,'S',60),
('all',38,'QB',79),('all',38,'RB',82),('all',38,'WR',84),('all',38,'TE',78),('all',38,'OL',74),('all',38,'DL',74),('all',38,'LB',77),('all',38,'CB',84),('all',38,'S',81),
('all',39,'QB',55),('all',39,'RB',51),('all',39,'WR',52),('all',39,'TE',52),('all',39,'OL',53),('all',39,'DL',52),('all',39,'LB',51),('all',39,'CB',48),('all',39,'S',49),
('all',40,'QB',71),('all',40,'RB',66),('all',40,'WR',66),('all',40,'TE',67),('all',40,'OL',66),('all',40,'DL',66),('all',40,'LB',66),('all',40,'CB',63),('all',40,'S',64),
('all',41,'QB',53),('all',41,'RB',57),('all',41,'WR',59),('all',41,'TE',55),('all',41,'OL',55),('all',41,'DL',54),('all',41,'LB',53),('all',41,'CB',58),('all',41,'S',54),
('all',42,'QB',71),('all',42,'RB',76),('all',42,'WR',77),('all',42,'TE',76),('all',42,'OL',74),('all',42,'DL',73),('all',42,'LB',73),('all',42,'CB',77),('all',42,'S',74),
('all',43,'QB',64),('all',43,'RB',56),('all',43,'WR',56),('all',43,'TE',56),('all',43,'OL',58),('all',43,'DL',58),('all',43,'LB',57),('all',43,'CB',56),('all',43,'S',57),
('all',44,'QB',71),('all',44,'RB',63),('all',44,'WR',62),('all',44,'TE',64),('all',44,'OL',66),('all',44,'DL',65),('all',44,'LB',65),('all',44,'CB',63),('all',44,'S',65),
('all',45,'QB',81),('all',45,'RB',70),('all',45,'WR',68),('all',45,'TE',72),('all',45,'OL',74),('all',45,'DL',73),('all',45,'LB',73),('all',45,'CB',69),('all',45,'S',73),
('all',46,'QB',57),('all',46,'RB',54),('all',46,'WR',53),('all',46,'TE',54),('all',46,'OL',58),('all',46,'DL',59),('all',46,'LB',58),('all',46,'CB',53),('all',46,'S',55),
('all',47,'QB',68),('all',47,'RB',62),('all',47,'WR',59),('all',47,'TE',67),('all',47,'OL',72),('all',47,'DL',72),('all',47,'LB',71),('all',47,'CB',60),('all',47,'S',67),
('all',48,'QB',57),('all',48,'RB',58),('all',48,'WR',59),('all',48,'TE',61),('all',48,'OL',63),('all',48,'DL',61),('all',48,'LB',58),('all',48,'CB',58),('all',48,'S',58),
('all',49,'QB',76),('all',49,'RB',76),('all',49,'WR',78),('all',49,'TE',72),('all',49,'OL',68),('all',49,'DL',68),('all',49,'LB',71),('all',49,'CB',77),('all',49,'S',74),
('all',50,'QB',56),('all',50,'RB',68),('all',50,'WR',71),('all',50,'TE',56),('all',50,'OL',49),('all',50,'DL',54),('all',50,'LB',57),('all',50,'CB',70),('all',50,'S',61),
('all',51,'QB',69),('all',51,'RB',83),('all',51,'WR',83),('all',51,'TE',75),('all',51,'OL',71),('all',51,'DL',74),('all',51,'LB',75),('all',51,'CB',83),('all',51,'S',77),
('all',52,'QB',57),('all',52,'RB',67),('all',52,'WR',70),('all',52,'TE',59),('all',52,'OL',55),('all',52,'DL',56),('all',52,'LB',57),('all',52,'CB',69),('all',52,'S',61),
('all',53,'QB',71),('all',53,'RB',81),('all',53,'WR',83),('all',53,'TE',75),('all',53,'OL',70),('all',53,'DL',70),('all',53,'LB',72),('all',53,'CB',82),('all',53,'S',76),
('all',54,'QB',62),('all',54,'RB',60),('all',54,'WR',61),('all',54,'TE',60),('all',54,'OL',61),('all',54,'DL',60),('all',54,'LB',58),('all',54,'CB',61),('all',54,'S',59),
('all',55,'QB',79),('all',55,'RB',77),('all',55,'WR',78),('all',55,'TE',78),('all',55,'OL',77),('all',55,'DL',76),('all',55,'LB',76),('all',55,'CB',77),('all',55,'S',77),
('all',56,'QB',57),('all',56,'RB',64),('all',56,'WR',64),('all',56,'TE',62),('all',56,'OL',61),('all',56,'DL',63),('all',56,'LB',62),('all',56,'CB',63),('all',56,'S',60),
('all',57,'QB',70),('all',57,'RB',78),('all',57,'WR',78),('all',57,'TE',76),('all',57,'OL',73),('all',57,'DL',75),('all',57,'LB',75),('all',57,'CB',78),('all',57,'S',75),
('all',58,'QB',64),('all',58,'RB',63),('all',58,'WR',64),('all',58,'TE',63),('all',58,'OL',63),('all',58,'DL',63),('all',58,'LB',62),('all',58,'CB',63),('all',58,'S',61),
('all',59,'QB',82),('all',59,'RB',83),('all',59,'WR',82),('all',59,'TE',83),('all',59,'OL',82),('all',59,'DL',83),('all',59,'LB',82),('all',59,'CB',82),('all',59,'S',82),
('all',60,'QB',58),('all',60,'RB',67),('all',60,'WR',70),('all',60,'TE',62),('all',60,'OL',58),('all',60,'DL',59),('all',60,'LB',59),('all',60,'CB',69),('all',60,'S',61),
('all',61,'QB',64),('all',61,'RB',72),('all',61,'WR',74),('all',61,'TE',69),('all',61,'OL',66),('all',61,'DL',67),('all',61,'LB',67),('all',61,'CB',73),('all',61,'S',69),
('all',62,'QB',75),('all',62,'RB',76),('all',62,'WR',75),('all',62,'TE',78),('all',62,'OL',79),('all',62,'DL',78),('all',62,'LB',79),('all',62,'CB',75),('all',62,'S',78),
('all',63,'QB',71),('all',63,'RB',67),('all',63,'WR',70),('all',63,'TE',60),('all',63,'OL',56),('all',63,'DL',54),('all',63,'LB',55),('all',63,'CB',69),('all',63,'S',60),
('all',64,'QB',79),('all',64,'RB',75),('all',64,'WR',78),('all',64,'TE',69),('all',64,'OL',64),('all',64,'DL',62),('all',64,'LB',64),('all',64,'CB',77),('all',64,'S',69),
('all',65,'QB',88),('all',65,'RB',84),('all',65,'WR',87),('all',65,'TE',78),('all',65,'OL',71),('all',65,'DL',69),('all',65,'LB',73),('all',65,'CB',87),('all',65,'S',79),
('all',66,'QB',54),('all',66,'RB',57),('all',66,'WR',56),('all',66,'TE',59),('all',66,'OL',63),('all',66,'DL',63),('all',66,'LB',60),('all',66,'CB',55),('all',66,'S',56),
('all',67,'QB',64),('all',67,'RB',65),('all',67,'WR',63),('all',67,'TE',70),('all',67,'OL',73),('all',67,'DL',73),('all',67,'LB',70),('all',67,'CB',62),('all',67,'S',66),
('all',68,'QB',74),('all',68,'RB',73),('all',68,'WR',70),('all',68,'TE',79),('all',68,'OL',82),('all',68,'DL',83),('all',68,'LB',81),('all',68,'CB',70),('all',68,'S',76),
('all',69,'QB',60),('all',69,'RB',58),('all',69,'WR',57),('all',69,'TE',56),('all',69,'OL',58),('all',69,'DL',60),('all',69,'LB',58),('all',69,'CB',56),('all',69,'S',55),
('all',70,'QB',68),('all',70,'RB',65),('all',70,'WR',65),('all',70,'TE',64),('all',70,'OL',65),('all',70,'DL',67),('all',70,'LB',66),('all',70,'CB',63),('all',70,'S',63),
('all',71,'QB',78),('all',71,'RB',75),('all',71,'WR',73),('all',71,'TE',74),('all',71,'OL',74),('all',71,'DL',75),('all',71,'LB',76),('all',71,'CB',73),('all',71,'S',74),
('all',72,'QB',66),('all',72,'RB',66),('all',72,'WR',68),('all',72,'TE',64),('all',72,'OL',62),('all',72,'DL',59),('all',72,'LB',61),('all',72,'CB',68),('all',72,'S',65),
('all',73,'QB',81),('all',73,'RB',83),('all',73,'WR',84),('all',73,'TE',80),('all',73,'OL',76),('all',73,'DL',74),('all',73,'LB',77),('all',73,'CB',84),('all',73,'S',82),
('all',74,'QB',53),('all',74,'RB',53),('all',74,'WR',50),('all',74,'TE',58),('all',74,'OL',66),('all',74,'DL',66),('all',74,'LB',62),('all',74,'CB',52),('all',74,'S',57),
('all',75,'QB',61),('all',75,'RB',60),('all',75,'WR',57),('all',75,'TE',68),('all',75,'OL',76),('all',75,'DL',76),('all',75,'LB',71),('all',75,'CB',59),('all',75,'S',65),
('all',76,'QB',69),('all',76,'RB',69),('all',76,'WR',65),('all',76,'TE',79),('all',76,'OL',86),('all',76,'DL',86),('all',76,'LB',81),('all',76,'CB',67),('all',76,'S',75),
('all',77,'QB',68),('all',77,'RB',74),('all',77,'WR',75),('all',77,'TE',71),('all',77,'OL',69),('all',77,'DL',70),('all',77,'LB',69),('all',77,'CB',74),('all',77,'S',70),
('all',78,'QB',77),('all',78,'RB',83),('all',78,'WR',82),('all',78,'TE',81),('all',78,'OL',78),('all',78,'DL',79),('all',78,'LB',79),('all',78,'CB',83),('all',78,'S',80),
('all',79,'QB',56),('all',79,'RB',52),('all',79,'WR',51),('all',79,'TE',59),('all',79,'OL',65),('all',79,'DL',63),('all',79,'LB',59),('all',79,'CB',50),('all',79,'S',54),
('all',80,'QB',78),('all',80,'RB',64),('all',80,'WR',63),('all',80,'TE',73),('all',80,'OL',79),('all',80,'DL',75),('all',80,'LB',74),('all',80,'CB',64),('all',80,'S',71),
('all',81,'QB',68),('all',81,'RB',58),('all',81,'WR',59),('all',81,'TE',57),('all',81,'OL',58),('all',81,'DL',57),('all',81,'LB',57),('all',81,'CB',60),('all',81,'S',59),
('all',82,'QB',80),('all',82,'RB',71),('all',82,'WR',71),('all',82,'TE',73),('all',82,'OL',74),('all',82,'DL',72),('all',82,'LB',71),('all',82,'CB',72),('all',82,'S',72),
('all',83,'QB',64),('all',83,'RB',66),('all',83,'WR',66),('all',83,'TE',66),('all',83,'OL',66),('all',83,'DL',68),('all',83,'LB',67),('all',83,'CB',65),('all',83,'S',65),
('all',84,'QB',56),('all',84,'RB',65),('all',84,'WR',65),('all',84,'TE',64),('all',84,'OL',65),('all',84,'DL',66),('all',84,'LB',63),('all',84,'CB',65),('all',84,'S',61),
('all',85,'QB',70),('all',85,'RB',82),('all',85,'WR',81),('all',85,'TE',79),('all',85,'OL',77),('all',85,'DL',79),('all',85,'LB',79),('all',85,'CB',81),('all',85,'S',78),
('all',86,'QB',61),('all',86,'RB',59),('all',86,'WR',60),('all',86,'TE',63),('all',86,'OL',65),('all',86,'DL',61),('all',86,'LB',60),('all',86,'CB',60),('all',86,'S',60),
('all',87,'QB',75),('all',87,'RB',73),('all',87,'WR',73),('all',87,'TE',76),('all',87,'OL',76),('all',87,'DL',73),('all',87,'LB',74),('all',87,'CB',74),('all',87,'S',75),
('all',88,'QB',57),('all',88,'RB',55),('all',88,'WR',54),('all',88,'TE',60),('all',88,'OL',64),('all',88,'DL',64),('all',88,'LB',61),('all',88,'CB',53),('all',88,'S',56),
('all',89,'QB',74),('all',89,'RB',72),('all',89,'WR',70),('all',89,'TE',75),('all',89,'OL',76),('all',89,'DL',77),('all',89,'LB',77),('all',89,'CB',70),('all',89,'S',75),
('all',90,'QB',56),('all',90,'RB',57),('all',90,'WR',56),('all',90,'TE',57),('all',90,'OL',61),('all',90,'DL',63),('all',90,'LB',60),('all',90,'CB',58),('all',90,'S',58),
('all',91,'QB',74),('all',91,'RB',74),('all',91,'WR',71),('all',91,'TE',81),('all',91,'OL',87),('all',91,'DL',86),('all',91,'LB',83),('all',91,'CB',76),('all',91,'S',80),
('all',92,'QB',67),('all',92,'RB',66),('all',92,'WR',70),('all',92,'TE',54),('all',92,'OL',48),('all',92,'DL',51),('all',92,'LB',54),('all',92,'CB',68),('all',92,'S',59),
('all',93,'QB',76),('all',93,'RB',75),('all',93,'WR',79),('all',93,'TE',62),('all',93,'OL',55),('all',93,'DL',58),('all',93,'LB',63),('all',93,'CB',77),('all',93,'S',68),
('all',94,'QB',85),('all',94,'RB',82),('all',94,'WR',84),('all',94,'TE',77),('all',94,'OL',73),('all',94,'DL',72),('all',94,'LB',74),('all',94,'CB',83),('all',94,'S',78),
('all',95,'QB',58),('all',95,'RB',65),('all',95,'WR',65),('all',95,'TE',73),('all',95,'OL',79),('all',95,'DL',74),('all',95,'LB',69),('all',95,'CB',70),('all',95,'S',70),
('all',96,'QB',62),('all',96,'RB',59),('all',96,'WR',60),('all',96,'TE',62),('all',96,'OL',63),('all',96,'DL',60),('all',96,'LB',59),('all',96,'CB',60),('all',96,'S',61),
('all',97,'QB',77),('all',97,'RB',73),('all',97,'WR',73),('all',97,'TE',76),('all',97,'OL',76),('all',97,'DL',72),('all',97,'LB',74),('all',97,'CB',74),('all',97,'S',76),
('all',98,'QB',53),('all',98,'RB',61),('all',98,'WR',59),('all',98,'TE',62),('all',98,'OL',65),('all',98,'DL',70),('all',98,'LB',66),('all',98,'CB',60),('all',98,'S',61),
('all',99,'QB',67),('all',99,'RB',75),('all',99,'WR',72),('all',99,'TE',78),('all',99,'OL',81),('all',99,'DL',84),('all',99,'LB',82),('all',99,'CB',74),('all',99,'S',77),
('all',100,'QB',62),('all',100,'RB',70),('all',100,'WR',75),('all',100,'TE',64),('all',100,'OL',58),('all',100,'DL',57),('all',100,'LB',59),('all',100,'CB',74),('all',100,'S',65),
('all',101,'QB',77),('all',101,'RB',89),('all',101,'WR',94),('all',101,'TE',81),('all',101,'OL',72),('all',101,'DL',71),('all',101,'LB',75),('all',101,'CB',93),('all',101,'S',83),
('all',102,'QB',61),('all',102,'RB',58),('all',102,'WR',59),('all',102,'TE',57),('all',102,'OL',58),('all',102,'DL',58),('all',102,'LB',58),('all',102,'CB',59),('all',102,'S',58),
('all',103,'QB',83),('all',103,'RB',72),('all',103,'WR',70),('all',103,'TE',77),('all',103,'OL',80),('all',103,'DL',79),('all',103,'LB',77),('all',103,'CB',70),('all',103,'S',75),
('all',104,'QB',57),('all',104,'RB',56),('all',104,'WR',57),('all',104,'TE',58),('all',104,'OL',62),('all',104,'DL',61),('all',104,'LB',60),('all',104,'CB',58),('all',104,'S',59),
('all',105,'QB',68),('all',105,'RB',66),('all',105,'WR',64),('all',105,'TE',71),('all',105,'OL',75),('all',105,'DL',73),('all',105,'LB',73),('all',105,'CB',66),('all',105,'S',71),
('all',106,'QB',70),('all',106,'RB',79),('all',106,'WR',77),('all',106,'TE',77),('all',106,'OL',76),('all',106,'DL',78),('all',106,'LB',79),('all',106,'CB',78),('all',106,'S',79),
('all',107,'QB',70),('all',107,'RB',76),('all',107,'WR',74),('all',107,'TE',76),('all',107,'OL',77),('all',107,'DL',77),('all',107,'LB',78),('all',107,'CB',76),('all',107,'S',78),
('all',108,'QB',65),('all',108,'RB',59),('all',108,'WR',59),('all',108,'TE',66),('all',108,'OL',69),('all',108,'DL',66),('all',108,'LB',63),('all',108,'CB',59),('all',108,'S',62),
('all',109,'QB',61),('all',109,'RB',58),('all',109,'WR',58),('all',109,'TE',57),('all',109,'OL',60),('all',109,'DL',62),('all',109,'LB',61),('all',109,'CB',59),('all',109,'S',60),
('all',110,'QB',75),('all',110,'RB',72),('all',110,'WR',70),('all',110,'TE',73),('all',110,'OL',76),('all',110,'DL',76),('all',110,'LB',76),('all',110,'CB',72),('all',110,'S',75),
('all',111,'QB',54),('all',111,'RB',55),('all',111,'WR',53),('all',111,'TE',64),('all',111,'OL',71),('all',111,'DL',71),('all',111,'LB',65),('all',111,'CB',54),('all',111,'S',59),
('all',112,'QB',64),('all',112,'RB',68),('all',112,'WR',64),('all',112,'TE',77),('all',112,'OL',84),('all',112,'DL',85),('all',112,'LB',80),('all',112,'CB',64),('all',112,'S',72),
('all',113,'QB',67),('all',113,'RB',66),('all',113,'WR',73),('all',113,'TE',68),('all',113,'OL',61),('all',113,'DL',54),('all',113,'LB',58),('all',113,'CB',65),('all',113,'S',63),
('all',114,'QB',71),('all',114,'RB',66),('all',114,'WR',66),('all',114,'TE',69),('all',114,'OL',72),('all',114,'DL',71),('all',114,'LB',68),('all',114,'CB',68),('all',114,'S',67),
('all',115,'QB',69),('all',115,'RB',79),('all',115,'WR',79),('all',115,'TE',80),('all',115,'OL',78),('all',115,'DL',78),('all',115,'LB',78),('all',115,'CB',79),('all',115,'S',78),
('all',116,'QB',60),('all',116,'RB',59),('all',116,'WR',61),('all',116,'TE',57),('all',116,'OL',58),('all',116,'DL',58),('all',116,'LB',57),('all',116,'CB',61),('all',116,'S',57),
('all',117,'QB',73),('all',117,'RB',73),('all',117,'WR',74),('all',117,'TE',72),('all',117,'OL',71),('all',117,'DL',71),('all',117,'LB',70),('all',117,'CB',74),('all',117,'S',71),
('all',118,'QB',57),('all',118,'RB',63),('all',118,'WR',64),('all',118,'TE',62),('all',118,'OL',62),('all',118,'DL',63),('all',118,'LB',61),('all',118,'CB',64),('all',118,'S',61),
('all',119,'QB',71),('all',119,'RB',72),('all',119,'WR',71),('all',119,'TE',73),('all',119,'OL',73),('all',119,'DL',73),('all',119,'LB',73),('all',119,'CB',71),('all',119,'S',72),
('all',120,'QB',65),('all',120,'RB',67),('all',120,'WR',70),('all',120,'TE',65),('all',120,'OL',63),('all',120,'DL',62),('all',120,'LB',61),('all',120,'CB',70),('all',120,'S',64),
('all',121,'QB',82),('all',121,'RB',84),('all',121,'WR',86),('all',121,'TE',81),('all',121,'OL',77),('all',121,'DL',77),('all',121,'LB',79),('all',121,'CB',86),('all',121,'S',82),
('all',122,'QB',81),('all',122,'RB',76),('all',122,'WR',78),('all',122,'TE',74),('all',122,'OL',71),('all',122,'DL',67),('all',122,'LB',70),('all',122,'CB',80),('all',122,'S',77),
('all',123,'QB',71),('all',123,'RB',83),('all',123,'WR',83),('all',123,'TE',81),('all',123,'OL',78),('all',123,'DL',80),('all',123,'LB',79),('all',123,'CB',83),('all',123,'S',80),
('all',124,'QB',83),('all',124,'RB',77),('all',124,'WR',80),('all',124,'TE',73),('all',124,'OL',68),('all',124,'DL',66),('all',124,'LB',69),('all',124,'CB',78),('all',124,'S',74),
('all',125,'QB',79),('all',125,'RB',81),('all',125,'WR',83),('all',125,'TE',77),('all',125,'OL',72),('all',125,'DL',73),('all',125,'LB',75),('all',125,'CB',82),('all',125,'S',78),
('all',126,'QB',80),('all',126,'RB',80),('all',126,'WR',80),('all',126,'TE',77),('all',126,'OL',74),('all',126,'DL',75),('all',126,'LB',76),('all',126,'CB',79),('all',126,'S',77),
('all',127,'QB',71),('all',127,'RB',79),('all',127,'WR',77),('all',127,'TE',80),('all',127,'OL',81),('all',127,'DL',84),('all',127,'LB',82),('all',127,'CB',78),('all',127,'S',80),
('all',128,'QB',69),('all',128,'RB',83),('all',128,'WR',83),('all',128,'TE',82),('all',128,'OL',79),('all',128,'DL',80),('all',128,'LB',80),('all',128,'CB',84),('all',128,'S',81),
('all',129,'QB',48),('all',129,'RB',58),('all',129,'WR',62),('all',129,'TE',54),('all',129,'OL',53),('all',129,'DL',50),('all',129,'LB',50),('all',129,'CB',62),('all',129,'S',54),
('all',130,'QB',76),('all',130,'RB',80),('all',130,'WR',78),('all',130,'TE',85),('all',130,'OL',86),('all',130,'DL',85),('all',130,'LB',84),('all',130,'CB',78),('all',130,'S',82),
('all',131,'QB',79),('all',131,'RB',74),('all',131,'WR',74),('all',131,'TE',80),('all',131,'OL',81),('all',131,'DL',78),('all',131,'LB',77),('all',131,'CB',73),('all',131,'S',76),
('all',132,'QB',59),('all',132,'RB',59),('all',132,'WR',59),('all',132,'TE',55),('all',132,'OL',56),('all',132,'DL',56),('all',132,'LB',57),('all',132,'CB',59),('all',132,'S',58),
('all',133,'QB',61),('all',133,'RB',62),('all',133,'WR',63),('all',133,'TE',59),('all',133,'OL',58),('all',133,'DL',59),('all',133,'LB',59),('all',133,'CB',62),('all',133,'S',60),
('all',134,'QB',83),('all',134,'RB',75),('all',134,'WR',76),('all',134,'TE',75),('all',134,'OL',72),('all',134,'DL',71),('all',134,'LB',73),('all',134,'CB',74),('all',134,'S',74),
('all',135,'QB',85),('all',135,'RB',88),('all',135,'WR',91),('all',135,'TE',80),('all',135,'OL',72),('all',135,'DL',73),('all',135,'LB',77),('all',135,'CB',91),('all',135,'S',84),
('all',136,'QB',82),('all',136,'RB',78),('all',136,'WR',75),('all',136,'TE',77),('all',136,'OL',77),('all',136,'DL',80),('all',136,'LB',81),('all',136,'CB',75),('all',136,'S',79),
('all',137,'QB',70),('all',137,'RB',61),('all',137,'WR',61),('all',137,'TE',65),('all',137,'OL',68),('all',137,'DL',66),('all',137,'LB',64),('all',137,'CB',62),('all',137,'S',64),
('all',138,'QB',67),('all',138,'RB',57),('all',138,'WR',58),('all',138,'TE',59),('all',138,'OL',63),('all',138,'DL',62),('all',138,'LB',61),('all',138,'CB',60),('all',138,'S',61),
('all',139,'QB',81),('all',139,'RB',69),('all',139,'WR',69),('all',139,'TE',73),('all',139,'OL',77),('all',139,'DL',74),('all',139,'LB',74),('all',139,'CB',71),('all',139,'S',74),
('all',140,'QB',61),('all',140,'RB',63),('all',140,'WR',62),('all',140,'TE',64),('all',140,'OL',66),('all',140,'DL',68),('all',140,'LB',66),('all',140,'CB',64),('all',140,'S',64),
('all',141,'QB',73),('all',141,'RB',77),('all',141,'WR',75),('all',141,'TE',78),('all',141,'OL',80),('all',141,'DL',82),('all',141,'LB',81),('all',141,'CB',77),('all',141,'S',79),
('all',142,'QB',74),('all',142,'RB',89),('all',142,'WR',90),('all',142,'TE',84),('all',142,'OL',78),('all',142,'DL',80),('all',142,'LB',81),('all',142,'CB',89),('all',142,'S',84),
('all',143,'QB',76),('all',143,'RB',69),('all',143,'WR',67),('all',143,'TE',80),('all',143,'OL',84),('all',143,'DL',81),('all',143,'LB',79),('all',143,'CB',65),('all',143,'S',74),
('all',144,'QB',86),('all',144,'RB',83),('all',144,'WR',83),('all',144,'TE',83),('all',144,'OL',82),('all',144,'DL',80),('all',144,'LB',83),('all',144,'CB',84),('all',144,'S',86),
('all',145,'QB',88),('all',145,'RB',85),('all',145,'WR',85),('all',145,'TE',83),('all',145,'OL',81),('all',145,'DL',80),('all',145,'LB',82),('all',145,'CB',85),('all',145,'S',84),
('all',146,'QB',88),('all',146,'RB',83),('all',146,'WR',82),('all',146,'TE',83),('all',146,'OL',82),('all',146,'DL',82),('all',146,'LB',83),('all',146,'CB',83),('all',146,'S',83),
('all',147,'QB',59),('all',147,'RB',60),('all',147,'WR',60),('all',147,'TE',58),('all',147,'OL',59),('all',147,'DL',59),('all',147,'LB',58),('all',147,'CB',60),('all',147,'S',58),
('all',148,'QB',70),('all',148,'RB',71),('all',148,'WR',70),('all',148,'TE',71),('all',148,'OL',71),('all',148,'DL',70),('all',148,'LB',70),('all',148,'CB',70),('all',148,'S',70),
('all',149,'QB',85),('all',149,'RB',83),('all',149,'WR',80),('all',149,'TE',87),('all',149,'OL',88),('all',149,'DL',89),('all',149,'LB',88),('all',149,'CB',81),('all',149,'S',85),
('all',151,'QB',86),('all',151,'RB',88),('all',151,'WR',88),('all',151,'TE',82),('all',151,'OL',76),('all',151,'DL',80),('all',151,'LB',84),('all',151,'CB',88),('all',151,'S',87),
('all',152,'QB',61),('all',152,'RB',59),('all',152,'WR',60),('all',152,'TE',59),('all',152,'OL',61),('all',152,'DL',59),('all',152,'LB',59),('all',152,'CB',60),('all',152,'S',60),
('all',153,'QB',68),('all',153,'RB',67),('all',153,'WR',68),('all',153,'TE',68),('all',153,'OL',68),('all',153,'DL',67),('all',153,'LB',67),('all',153,'CB',69),('all',153,'S',69),
('all',154,'QB',80),('all',154,'RB',78),('all',154,'WR',78),('all',154,'TE',81),('all',154,'OL',81),('all',154,'DL',78),('all',154,'LB',79),('all',154,'CB',79),('all',154,'S',81),
('all',155,'QB',61),('all',155,'RB',62),('all',155,'WR',64),('all',155,'TE',59),('all',155,'OL',58),('all',155,'DL',58),('all',155,'LB',58),('all',155,'CB',63),('all',155,'S',59),
('all',156,'QB',71),('all',156,'RB',71),('all',156,'WR',72),('all',156,'TE',68),('all',156,'OL',66),('all',156,'DL',66),('all',156,'LB',67),('all',156,'CB',72),('all',156,'S',69),
('all',157,'QB',83),('all',157,'RB',82),('all',157,'WR',83),('all',157,'TE',81),('all',157,'OL',78),('all',157,'DL',78),('all',157,'LB',79),('all',157,'CB',83),('all',157,'S',81),
('all',158,'QB',58),('all',158,'RB',58),('all',158,'WR',58),('all',158,'TE',59),('all',158,'OL',61),('all',158,'DL',62),('all',158,'LB',60),('all',158,'CB',59),('all',158,'S',59),
('all',159,'QB',66),('all',159,'RB',67),('all',159,'WR',66),('all',159,'TE',69),('all',159,'OL',70),('all',159,'DL',70),('all',159,'LB',69),('all',159,'CB',66),('all',159,'S',68),
('all',160,'QB',77),('all',160,'RB',78),('all',160,'WR',77),('all',160,'TE',81),('all',160,'OL',82),('all',160,'DL',82),('all',160,'LB',81),('all',160,'CB',77),('all',160,'S',80),
('all',161,'QB',52),('all',161,'RB',48),('all',161,'WR',48),('all',161,'TE',50),('all',161,'OL',54),('all',161,'DL',52),('all',161,'LB',50),('all',161,'CB',48),('all',161,'S',49),
('all',162,'QB',65),('all',162,'RB',75),('all',162,'WR',76),('all',162,'TE',72),('all',162,'OL',71),('all',162,'DL',70),('all',162,'LB',70),('all',162,'CB',75),('all',162,'S',72),
('all',163,'QB',56),('all',163,'RB',57),('all',163,'WR',59),('all',163,'TE',56),('all',163,'OL',56),('all',163,'DL',53),('all',163,'LB',53),('all',163,'CB',57),('all',163,'S',54),
('all',164,'QB',77),('all',164,'RB',71),('all',164,'WR',73),('all',164,'TE',72),('all',164,'OL',69),('all',164,'DL',66),('all',164,'LB',68),('all',164,'CB',72),('all',164,'S',71),
('all',165,'QB',59),('all',165,'RB',58),('all',165,'WR',61),('all',165,'TE',56),('all',165,'OL',55),('all',165,'DL',51),('all',165,'LB',53),('all',165,'CB',61),('all',165,'S',57),
('all',166,'QB',71),('all',166,'RB',72),('all',166,'WR',75),('all',166,'TE',69),('all',166,'OL',66),('all',166,'DL',62),('all',166,'LB',66),('all',166,'CB',75),('all',166,'S',72),
('all',167,'QB',54),('all',167,'RB',53),('all',167,'WR',52),('all',167,'TE',54),('all',167,'OL',57),('all',167,'DL',57),('all',167,'LB',54),('all',167,'CB',52),('all',167,'S',52),
('all',168,'QB',67),('all',168,'RB',64),('all',168,'WR',62),('all',168,'TE',67),('all',168,'OL',71),('all',168,'DL',70),('all',168,'LB',69),('all',168,'CB',62),('all',168,'S',66),
('all',169,'QB',77),('all',169,'RB',89),('all',169,'WR',91),('all',169,'TE',85),('all',169,'OL',79),('all',169,'DL',80),('all',169,'LB',81),('all',169,'CB',91),('all',169,'S',85),
('all',170,'QB',62),('all',170,'RB',64),('all',170,'WR',66),('all',170,'TE',61),('all',170,'OL',58),('all',170,'DL',57),('all',170,'LB',58),('all',170,'CB',65),('all',170,'S',60),
('all',171,'QB',73),('all',171,'RB',71),('all',171,'WR',73),('all',171,'TE',71),('all',171,'OL',69),('all',171,'DL',67),('all',171,'LB',69),('all',171,'CB',71),('all',171,'S',70),
('all',172,'QB',52),('all',172,'RB',56),('all',172,'WR',58),('all',172,'TE',50),('all',172,'OL',47),('all',172,'DL',49),('all',172,'LB',50),('all',172,'CB',57),('all',172,'S',51),
('all',173,'QB',55),('all',173,'RB',47),('all',173,'WR',49),('all',173,'TE',47),('all',173,'OL',49),('all',173,'DL',47),('all',173,'LB',48),('all',173,'CB',48),('all',173,'S',48),
('all',174,'QB',50),('all',174,'RB',47),('all',174,'WR',49),('all',174,'TE',45),('all',174,'OL',46),('all',174,'DL',46),('all',174,'LB',45),('all',174,'CB',45),('all',174,'S',43),
('all',175,'QB',56),('all',175,'RB',50),('all',175,'WR',51),('all',175,'TE',49),('all',175,'OL',52),('all',175,'DL',50),('all',175,'LB',51),('all',175,'CB',52),('all',175,'S',53),
('all',176,'QB',73),('all',176,'RB',63),('all',176,'WR',64),('all',176,'TE',63),('all',176,'OL',63),('all',176,'DL',61),('all',176,'LB',64),('all',176,'CB',66),('all',176,'S',68),
('all',177,'QB',63),('all',177,'RB',64),('all',177,'WR',66),('all',177,'TE',57),('all',177,'OL',54),('all',177,'DL',57),('all',177,'LB',58),('all',177,'CB',65),('all',177,'S',60),
('all',178,'QB',77),('all',178,'RB',78),('all',178,'WR',79),('all',178,'TE',74),('all',178,'OL',71),('all',178,'DL',71),('all',178,'LB',73),('all',178,'CB',79),('all',178,'S',76),
('all',179,'QB',60),('all',179,'RB',54),('all',179,'WR',55),('all',179,'TE',55),('all',179,'OL',56),('all',179,'DL',55),('all',179,'LB',54),('all',179,'CB',55),('all',179,'S',54),
('all',180,'QB',68),('all',180,'RB',61),('all',180,'WR',62),('all',180,'TE',62),('all',180,'OL',63),('all',180,'DL',62),('all',180,'LB',62),('all',180,'CB',61),('all',180,'S',61),
('all',181,'QB',83),('all',181,'RB',71),('all',181,'WR',70),('all',181,'TE',75),('all',181,'OL',77),('all',181,'DL',74),('all',181,'LB',74),('all',181,'CB',71),('all',181,'S',74),
('all',182,'QB',78),('all',182,'RB',71),('all',182,'WR',70),('all',182,'TE',70),('all',182,'OL',71),('all',182,'DL',72),('all',182,'LB',74),('all',182,'CB',71),('all',182,'S',75),
('all',183,'QB',52),('all',183,'RB',54),('all',183,'WR',56),('all',183,'TE',54),('all',183,'OL',55),('all',183,'DL',52),('all',183,'LB',52),('all',183,'CB',56),('all',183,'S',54),
('all',184,'QB',69),('all',184,'RB',65),('all',184,'WR',66),('all',184,'TE',68),('all',184,'OL',69),('all',184,'DL',66),('all',184,'LB',67),('all',184,'CB',66),('all',184,'S',68),
('all',185,'QB',61),('all',185,'RB',62),('all',185,'WR',59),('all',185,'TE',69),('all',185,'OL',76),('all',185,'DL',76),('all',185,'LB',73),('all',185,'CB',61),('all',185,'S',68),
('all',186,'QB',79),('all',186,'RB',75),('all',186,'WR',75),('all',186,'TE',75),('all',186,'OL',74),('all',186,'DL',73),('all',186,'LB',75),('all',186,'CB',75),('all',186,'S',76),
('all',187,'QB',55),('all',187,'RB',57),('all',187,'WR',60),('all',187,'TE',51),('all',187,'OL',49),('all',187,'DL',50),('all',187,'LB',52),('all',187,'CB',59),('all',187,'S',55),
('all',188,'QB',62),('all',188,'RB',68),('all',188,'WR',72),('all',188,'TE',61),('all',188,'OL',56),('all',188,'DL',57),('all',188,'LB',60),('all',188,'CB',71),('all',188,'S',65),
('all',189,'QB',72),('all',189,'RB',81),('all',189,'WR',85),('all',189,'TE',73),('all',189,'OL',66),('all',189,'DL',66),('all',189,'LB',71),('all',189,'CB',85),('all',189,'S',79),
('all',190,'QB',60),('all',190,'RB',70),('all',190,'WR',72),('all',190,'TE',66),('all',190,'OL',63),('all',190,'DL',65),('all',190,'LB',65),('all',190,'CB',71),('all',190,'S',66),
('all',191,'QB',49),('all',191,'RB',49),('all',191,'WR',50),('all',191,'TE',46),('all',191,'OL',47),('all',191,'DL',47),('all',191,'LB',46),('all',191,'CB',49),('all',191,'S',46),
('all',192,'QB',77),('all',192,'RB',63),('all',192,'WR',61),('all',192,'TE',64),('all',192,'OL',67),('all',192,'DL',66),('all',192,'LB',67),('all',192,'CB',61),('all',192,'S',66),
('all',193,'QB',67),('all',193,'RB',72),('all',193,'WR',75),('all',193,'TE',69),('all',193,'OL',66),('all',193,'DL',66),('all',193,'LB',65),('all',193,'CB',73),('all',193,'S',67),
('all',194,'QB',48),('all',194,'RB',47),('all',194,'WR',47),('all',194,'TE',49),('all',194,'OL',54),('all',194,'DL',53),('all',194,'LB',50),('all',194,'CB',46),('all',194,'S',47),
('all',195,'QB',68),('all',195,'RB',63),('all',195,'WR',61),('all',195,'TE',70),('all',195,'OL',75),('all',195,'DL',73),('all',195,'LB',70),('all',195,'CB',61),('all',195,'S',67),
('all',196,'QB',88),('all',196,'RB',84),('all',196,'WR',86),('all',196,'TE',78),('all',196,'OL',72),('all',196,'DL',72),('all',196,'LB',76),('all',196,'CB',86),('all',196,'S',81),
('all',197,'QB',78),('all',197,'RB',76),('all',197,'WR',77),('all',197,'TE',78),('all',197,'OL',77),('all',197,'DL',74),('all',197,'LB',78),('all',197,'CB',78),('all',197,'S',81),
('all',198,'QB',69),('all',198,'RB',74),('all',198,'WR',75),('all',198,'TE',66),('all',198,'OL',61),('all',198,'DL',66),('all',198,'LB',66),('all',198,'CB',74),('all',198,'S',67),
('all',199,'QB',80),('all',199,'RB',66),('all',199,'WR',64),('all',199,'TE',73),('all',199,'OL',77),('all',199,'DL',73),('all',199,'LB',73),('all',199,'CB',65),('all',199,'S',72),
('all',200,'QB',74),('all',200,'RB',75),('all',200,'WR',78),('all',200,'TE',67),('all',200,'OL',62),('all',200,'DL',63),('all',200,'LB',67),('all',200,'CB',77),('all',200,'S',71),
('all',201,'QB',65),('all',201,'RB',62),('all',201,'WR',61),('all',201,'TE',59),('all',201,'OL',61),('all',201,'DL',62),('all',201,'LB',62),('all',201,'CB',60),('all',201,'S',61),
('all',202,'QB',61),('all',202,'RB',61),('all',202,'WR',63),('all',202,'TE',66),('all',202,'OL',66),('all',202,'DL',61),('all',202,'LB',61),('all',202,'CB',59),('all',202,'S',61),
('all',203,'QB',73),('all',203,'RB',74),('all',203,'WR',75),('all',203,'TE',74),('all',203,'OL',72),('all',203,'DL',72),('all',203,'LB',71),('all',203,'CB',75),('all',203,'S',72),
('all',204,'QB',53),('all',204,'RB',51),('all',204,'WR',50),('all',204,'TE',56),('all',204,'OL',62),('all',204,'DL',62),('all',204,'LB',58),('all',204,'CB',51),('all',204,'S',55),
('all',205,'QB',68),('all',205,'RB',66),('all',205,'WR',63),('all',205,'TE',75),('all',205,'OL',82),('all',205,'DL',80),('all',205,'LB',77),('all',205,'CB',65),('all',205,'S',73),
('all',206,'QB',67),('all',206,'RB',64),('all',206,'WR',65),('all',206,'TE',67),('all',206,'OL',68),('all',206,'DL',68),('all',206,'LB',66),('all',206,'CB',64),('all',206,'S',65),
('all',207,'QB',63),('all',207,'RB',73),('all',207,'WR',74),('all',207,'TE',74),('all',207,'OL',74),('all',207,'DL',74),('all',207,'LB',72),('all',207,'CB',75),('all',207,'S',73),
('all',208,'QB',69),('all',208,'RB',65),('all',208,'WR',61),('all',208,'TE',78),('all',208,'OL',88),('all',208,'DL',86),('all',208,'LB',81),('all',208,'CB',66),('all',208,'S',77),
('all',209,'QB',56),('all',209,'RB',56),('all',209,'WR',55),('all',209,'TE',57),('all',209,'OL',60),('all',209,'DL',62),('all',209,'LB',59),('all',209,'CB',54),('all',209,'S',55),
('all',210,'QB',68),('all',210,'RB',68),('all',210,'WR',65),('all',210,'TE',72),('all',210,'OL',76),('all',210,'DL',78),('all',210,'LB',75),('all',210,'CB',64),('all',210,'S',70),
('all',211,'QB',66),('all',211,'RB',75),('all',211,'WR',76),('all',211,'TE',70),('all',211,'OL',67),('all',211,'DL',72),('all',211,'LB',72),('all',211,'CB',76),('all',211,'S',72),
('all',212,'QB',71),('all',212,'RB',75),('all',212,'WR',71),('all',212,'TE',80),('all',212,'OL',83),('all',212,'DL',85),('all',212,'LB',82),('all',212,'CB',73),('all',212,'S',78),
('all',213,'QB',73),('all',213,'RB',60),('all',213,'WR',62),('all',213,'TE',74),('all',213,'OL',82),('all',213,'DL',72),('all',213,'LB',75),('all',213,'CB',72),('all',213,'S',84),
('all',214,'QB',71),('all',214,'RB',80),('all',214,'WR',78),('all',214,'TE',80),('all',214,'OL',79),('all',214,'DL',82),('all',214,'LB',82),('all',214,'CB',78),('all',214,'S',80),
('all',215,'QB',65),('all',215,'RB',81),('all',215,'WR',83),('all',215,'TE',75),('all',215,'OL',70),('all',215,'DL',73),('all',215,'LB',73),('all',215,'CB',82),('all',215,'S',76),
('all',216,'QB',60),('all',216,'RB',59),('all',216,'WR',59),('all',216,'TE',60),('all',216,'OL',61),('all',216,'DL',63),('all',216,'LB',61),('all',216,'CB',58),('all',216,'S',59),
('all',217,'QB',73),('all',217,'RB',72),('all',217,'WR',69),('all',217,'TE',78),('all',217,'OL',81),('all',217,'DL',82),('all',217,'LB',79),('all',217,'CB',69),('all',217,'S',74),
('all',218,'QB',59),('all',218,'RB',49),('all',218,'WR',49),('all',218,'TE',53),('all',218,'OL',58),('all',218,'DL',55),('all',218,'LB',52),('all',218,'CB',49),('all',218,'S',50),
('all',219,'QB',74),('all',219,'RB',61),('all',219,'WR',60),('all',219,'TE',68),('all',219,'OL',74),('all',219,'DL',70),('all',219,'LB',69),('all',219,'CB',62),('all',219,'S',68),
('all',220,'QB',52),('all',220,'RB',56),('all',220,'WR',57),('all',220,'TE',54),('all',220,'OL',55),('all',220,'DL',55),('all',220,'LB',54),('all',220,'CB',56),('all',220,'S',53),
('all',221,'QB',67),('all',221,'RB',67),('all',221,'WR',66),('all',221,'TE',72),('all',221,'OL',75),('all',221,'DL',75),('all',221,'LB',73),('all',221,'CB',65),('all',221,'S',69),
('all',222,'QB',69),('all',222,'RB',62),('all',222,'WR',63),('all',222,'TE',64),('all',222,'OL',66),('all',222,'DL',65),('all',222,'LB',65),('all',222,'CB',64),('all',222,'S',67),
('all',223,'QB',61),('all',223,'RB',62),('all',223,'WR',63),('all',223,'TE',59),('all',223,'OL',59),('all',223,'DL',60),('all',223,'LB',59),('all',223,'CB',62),('all',223,'S',58),
('all',224,'QB',78),('all',224,'RB',69),('all',224,'WR',66),('all',224,'TE',72),('all',224,'OL',75),('all',224,'DL',76),('all',224,'LB',75),('all',224,'CB',66),('all',224,'S',71),
('all',225,'QB',64),('all',225,'RB',66),('all',225,'WR',67),('all',225,'TE',62),('all',225,'OL',62),('all',225,'DL',61),('all',225,'LB',62),('all',225,'CB',66),('all',225,'S',63),
('all',226,'QB',81),('all',226,'RB',74),('all',226,'WR',75),('all',226,'TE',77),('all',226,'OL',77),('all',226,'DL',69),('all',226,'LB',72),('all',226,'CB',76),('all',226,'S',78),
('all',227,'QB',67),('all',227,'RB',72),('all',227,'WR',72),('all',227,'TE',77),('all',227,'OL',80),('all',227,'DL',78),('all',227,'LB',77),('all',227,'CB',74),('all',227,'S',77),
('all',228,'QB',65),('all',228,'RB',64),('all',228,'WR',65),('all',228,'TE',60),('all',228,'OL',59),('all',228,'DL',59),('all',228,'LB',59),('all',228,'CB',63),('all',228,'S',59),
('all',229,'QB',82),('all',229,'RB',80),('all',229,'WR',81),('all',229,'TE',77),('all',229,'OL',73),('all',229,'DL',74),('all',229,'LB',76),('all',229,'CB',79),('all',229,'S',77),
('all',230,'QB',81),('all',230,'RB',80),('all',230,'WR',79),('all',230,'TE',82),('all',230,'OL',82),('all',230,'DL',81),('all',230,'LB',81),('all',230,'CB',80),('all',230,'S',82),
('all',231,'QB',57),('all',231,'RB',58),('all',231,'WR',58),('all',231,'TE',61),('all',231,'OL',63),('all',231,'DL',62),('all',231,'LB',59),('all',231,'CB',57),('all',231,'S',57),
('all',232,'QB',69),('all',232,'RB',70),('all',232,'WR',67),('all',232,'TE',78),('all',232,'OL',83),('all',232,'DL',84),('all',232,'LB',80),('all',232,'CB',68),('all',232,'S',75),
('all',233,'QB',81),('all',233,'RB',73),('all',233,'WR',72),('all',233,'TE',75),('all',233,'OL',75),('all',233,'DL',75),('all',233,'LB',75),('all',233,'CB',73),('all',233,'S',75),
('all',234,'QB',73),('all',234,'RB',75),('all',234,'WR',75),('all',234,'TE',76),('all',234,'OL',74),('all',234,'DL',75),('all',234,'LB',73),('all',234,'CB',75),('all',234,'S',72),
('all',235,'QB',54),('all',235,'RB',61),('all',235,'WR',64),('all',235,'TE',60),('all',235,'OL',59),('all',235,'DL',54),('all',235,'LB',55),('all',235,'CB',63),('all',235,'S',58),
('all',236,'QB',51),('all',236,'RB',50),('all',236,'WR',51),('all',236,'TE',52),('all',236,'OL',55),('all',236,'DL',52),('all',236,'LB',50),('all',236,'CB',51),('all',236,'S',49),
('all',237,'QB',70),('all',237,'RB',74),('all',237,'WR',73),('all',237,'TE',76),('all',237,'OL',77),('all',237,'DL',77),('all',237,'LB',78),('all',237,'CB',75),('all',237,'S',78),
('all',238,'QB',67),('all',238,'RB',62),('all',238,'WR',65),('all',238,'TE',57),('all',238,'OL',53),('all',238,'DL',52),('all',238,'LB',54),('all',238,'CB',63),('all',238,'S',58),
('all',239,'QB',65),('all',239,'RB',71),('all',239,'WR',74),('all',239,'TE',66),('all',239,'OL',62),('all',239,'DL',63),('all',239,'LB',64),('all',239,'CB',73),('all',239,'S',66),
('all',240,'QB',66),('all',240,'RB',70),('all',240,'WR',71),('all',240,'TE',66),('all',240,'OL',63),('all',240,'DL',65),('all',240,'LB',64),('all',240,'CB',70),('all',240,'S',65),
('all',241,'QB',68),('all',241,'RB',80),('all',241,'WR',81),('all',241,'TE',80),('all',241,'OL',78),('all',241,'DL',78),('all',241,'LB',78),('all',241,'CB',81),('all',241,'S',80),
('all',242,'QB',81),('all',242,'RB',73),('all',242,'WR',79),('all',242,'TE',75),('all',242,'OL',67),('all',242,'DL',59),('all',242,'LB',65),('all',242,'CB',72),('all',242,'S',71),
('all',243,'QB',88),('all',243,'RB',88),('all',243,'WR',89),('all',243,'TE',86),('all',243,'OL',82),('all',243,'DL',81),('all',243,'LB',83),('all',243,'CB',89),('all',243,'S',86),
('all',244,'QB',81),('all',244,'RB',86),('all',244,'WR',85),('all',244,'TE',87),('all',244,'OL',85),('all',244,'DL',86),('all',244,'LB',85),('all',244,'CB',84),('all',244,'S',84),
('all',245,'QB',84),('all',245,'RB',81),('all',245,'WR',82),('all',245,'TE',85),('all',245,'OL',85),('all',245,'DL',81),('all',245,'LB',83),('all',245,'CB',83),('all',245,'S',86),
('all',246,'QB',58),('all',246,'RB',57),('all',246,'WR',56),('all',246,'TE',60),('all',246,'OL',64),('all',246,'DL',62),('all',246,'LB',59),('all',246,'CB',56),('all',246,'S',57),
('all',247,'QB',68),('all',247,'RB',65),('all',247,'WR',64),('all',247,'TE',70),('all',247,'OL',74),('all',247,'DL',72),('all',247,'LB',70),('all',247,'CB',64),('all',247,'S',67),
('all',248,'QB',83),('all',248,'RB',79),('all',248,'WR',75),('all',248,'TE',86),('all',248,'OL',89),('all',248,'DL',90),('all',248,'LB',88),('all',248,'CB',77),('all',248,'S',84),
('all',249,'QB',92),('all',249,'RB',93),('all',249,'WR',94),('all',249,'TE',96),('all',249,'OL',93),('all',249,'DL',89),('all',249,'LB',92),('all',249,'CB',95),('all',249,'S',97),
('all',250,'QB',95),('all',250,'RB',91),('all',250,'WR',89),('all',250,'TE',94),('all',250,'OL',92),('all',250,'DL',92),('all',250,'LB',94),('all',250,'CB',90),('all',250,'S',94),
('all',251,'QB',86),('all',251,'RB',88),('all',251,'WR',88),('all',251,'TE',82),('all',251,'OL',77),('all',251,'DL',80),('all',251,'LB',84),('all',251,'CB',88),('all',251,'S',87),
('all',252,'QB',63),('all',252,'RB',64),('all',252,'WR',66),('all',252,'TE',59),('all',252,'OL',56),('all',252,'DL',56),('all',252,'LB',57),('all',252,'CB',65),('all',252,'S',60),
('all',253,'QB',72),('all',253,'RB',74),('all',253,'WR',76),('all',253,'TE',69),('all',253,'OL',65),('all',253,'DL',66),('all',253,'LB',67),('all',253,'CB',76),('all',253,'S',70),
('all',254,'QB',83),('all',254,'RB',87),('all',254,'WR',88),('all',254,'TE',82),('all',254,'OL',76),('all',254,'DL',77),('all',254,'LB',79),('all',254,'CB',88),('all',254,'S',82),
('all',255,'QB',63),('all',255,'RB',59),('all',255,'WR',60),('all',255,'TE',56),('all',255,'OL',56),('all',255,'DL',57),('all',255,'LB',57),('all',255,'CB',59),('all',255,'S',57),
('all',256,'QB',71),('all',256,'RB',66),('all',256,'WR',65),('all',256,'TE',67),('all',256,'OL',68),('all',256,'DL',69),('all',256,'LB',68),('all',256,'CB',65),('all',256,'S',66),
('all',257,'QB',81),('all',257,'RB',79),('all',257,'WR',77),('all',257,'TE',79),('all',257,'OL',79),('all',257,'DL',81),('all',257,'LB',81),('all',257,'CB',76),('all',257,'S',78),
('all',258,'QB',59),('all',258,'RB',58),('all',258,'WR',58),('all',258,'TE',58),('all',258,'OL',59),('all',258,'DL',61),('all',258,'LB',60),('all',258,'CB',58),('all',258,'S',58),
('all',259,'QB',67),('all',259,'RB',66),('all',259,'WR',64),('all',259,'TE',68),('all',259,'OL',70),('all',259,'DL',70),('all',259,'LB',69),('all',259,'CB',64),('all',259,'S',67),
('all',260,'QB',79),('all',260,'RB',75),('all',260,'WR',73),('all',260,'TE',79),('all',260,'OL',81),('all',260,'DL',81),('all',260,'LB',81),('all',260,'CB',73),('all',260,'S',78),
('all',261,'QB',50),('all',261,'RB',52),('all',261,'WR',52),('all',261,'TE',52),('all',261,'OL',55),('all',261,'DL',55),('all',261,'LB',52),('all',261,'CB',51),('all',261,'S',50),
('all',262,'QB',67),('all',262,'RB',71),('all',262,'WR',70),('all',262,'TE',71),('all',262,'OL',72),('all',262,'DL',72),('all',262,'LB',71),('all',262,'CB',70),('all',262,'S',70),
('all',263,'QB',53),('all',263,'RB',57),('all',263,'WR',59),('all',263,'TE',55),('all',263,'OL',55),('all',263,'DL',53),('all',263,'LB',53),('all',263,'CB',59),('all',263,'S',55),
('all',264,'QB',66),('all',264,'RB',76),('all',264,'WR',78),('all',264,'TE',72),('all',264,'OL',68),('all',264,'DL',69),('all',264,'LB',70),('all',264,'CB',77),('all',264,'S',72),
('all',265,'QB',47),('all',265,'RB',47),('all',265,'WR',48),('all',265,'TE',47),('all',265,'OL',50),('all',265,'DL',50),('all',265,'LB',49),('all',265,'CB',47),('all',265,'S',47),
('all',266,'QB',49),('all',266,'RB',46),('all',266,'WR',46),('all',266,'TE',49),('all',266,'OL',55),('all',266,'DL',52),('all',266,'LB',50),('all',266,'CB',45),('all',266,'S',47),
('all',267,'QB',73),('all',267,'RB',68),('all',267,'WR',67),('all',267,'TE',66),('all',267,'OL',67),('all',267,'DL',66),('all',267,'LB',66),('all',267,'CB',66),('all',267,'S',66),
('all',268,'QB',49),('all',268,'RB',46),('all',268,'WR',46),('all',268,'TE',50),('all',268,'OL',56),('all',268,'DL',52),('all',268,'LB',50),('all',268,'CB',45),('all',268,'S',47),
('all',269,'QB',68),('all',269,'RB',67),('all',269,'WR',68),('all',269,'TE',68),('all',269,'OL',68),('all',269,'DL',65),('all',269,'LB',66),('all',269,'CB',69),('all',269,'S',69),
('all',270,'QB',54),('all',270,'RB',51),('all',270,'WR',52),('all',270,'TE',49),('all',270,'OL',50),('all',270,'DL',49),('all',270,'LB',49),('all',270,'CB',52),('all',270,'S',50),
('all',271,'QB',64),('all',271,'RB',61),('all',271,'WR',62),('all',271,'TE',62),('all',271,'OL',64),('all',271,'DL',61),('all',271,'LB',61),('all',271,'CB',61),('all',271,'S',61),
('all',272,'QB',79),('all',272,'RB',74),('all',272,'WR',74),('all',272,'TE',75),('all',272,'OL',74),('all',272,'DL',72),('all',272,'LB',73),('all',272,'CB',74),('all',272,'S',75),
('all',273,'QB',50),('all',273,'RB',50),('all',273,'WR',51),('all',273,'TE',50),('all',273,'OL',53),('all',273,'DL',52),('all',273,'LB',51),('all',273,'CB',51),('all',273,'S',50),
('all',274,'QB',62),('all',274,'RB',63),('all',274,'WR',63),('all',274,'TE',63),('all',274,'OL',63),('all',274,'DL',63),('all',274,'LB',62),('all',274,'CB',62),('all',274,'S',60),
('all',275,'QB',75),('all',275,'RB',76),('all',275,'WR',75),('all',275,'TE',75),('all',275,'OL',75),('all',275,'DL',76),('all',275,'LB',75),('all',275,'CB',73),('all',275,'S',73),
('all',276,'QB',54),('all',276,'RB',66),('all',276,'WR',68),('all',276,'TE',57),('all',276,'OL',52),('all',276,'DL',56),('all',276,'LB',56),('all',276,'CB',67),('all',276,'S',58),
('all',277,'QB',72),('all',277,'RB',84),('all',277,'WR',86),('all',277,'TE',76),('all',277,'OL',70),('all',277,'DL',73),('all',277,'LB',74),('all',277,'CB',85),('all',277,'S',77),
('all',278,'QB',58),('all',278,'RB',64),('all',278,'WR',67),('all',278,'TE',58),('all',278,'OL',54),('all',278,'DL',54),('all',278,'LB',54),('all',278,'CB',66),('all',278,'S',57),
('all',279,'QB',75),('all',279,'RB',69),('all',279,'WR',69),('all',279,'TE',70),('all',279,'OL',72),('all',279,'DL',69),('all',279,'LB',69),('all',279,'CB',71),('all',279,'S',71),
('all',280,'QB',53),('all',280,'RB',51),('all',280,'WR',53),('all',280,'TE',49),('all',280,'OL',50),('all',280,'DL',48),('all',280,'LB',48),('all',280,'CB',52),('all',280,'S',49),
('all',281,'QB',62),('all',281,'RB',57),('all',281,'WR',58),('all',281,'TE',57),('all',281,'OL',58),('all',281,'DL',55),('all',281,'LB',55),('all',281,'CB',58),('all',281,'S',56),
('all',282,'QB',88),('all',282,'RB',78),('all',282,'WR',78),('all',282,'TE',77),('all',282,'OL',75),('all',282,'DL',72),('all',282,'LB',75),('all',282,'CB',79),('all',282,'S',79),
('all',283,'QB',59),('all',283,'RB',61),('all',283,'WR',64),('all',283,'TE',54),('all',283,'OL',51),('all',283,'DL',51),('all',283,'LB',53),('all',283,'CB',63),('all',283,'S',57),
('all',284,'QB',78),('all',284,'RB',74),('all',284,'WR',76),('all',284,'TE',69),('all',284,'OL',65),('all',284,'DL',66),('all',284,'LB',69),('all',284,'CB',75),('all',284,'S',73),
('all',285,'QB',57),('all',285,'RB',56),('all',285,'WR',57),('all',285,'TE',56),('all',285,'OL',57),('all',285,'DL',56),('all',285,'LB',56),('all',285,'CB',57),('all',285,'S',57),
('all',286,'QB',69),('all',286,'RB',74),('all',286,'WR',71),('all',286,'TE',75),('all',286,'OL',77),('all',286,'DL',80),('all',286,'LB',79),('all',286,'CB',71),('all',286,'S',74),
('all',287,'QB',54),('all',287,'RB',53),('all',287,'WR',53),('all',287,'TE',57),('all',287,'OL',61),('all',287,'DL',60),('all',287,'LB',57),('all',287,'CB',53),('all',287,'S',54),
('all',288,'QB',67),('all',288,'RB',75),('all',288,'WR',76),('all',288,'TE',75),('all',288,'OL',73),('all',288,'DL',73),('all',288,'LB',72),('all',288,'CB',75),('all',288,'S',72),
('all',289,'QB',83),('all',289,'RB',91),('all',289,'WR',89),('all',289,'TE',93),('all',289,'OL',91),('all',289,'DL',96),('all',289,'LB',94),('all',289,'CB',87),('all',289,'S',89),
('all',290,'QB',52),('all',290,'RB',54),('all',290,'WR',55),('all',290,'TE',55),('all',290,'OL',59),('all',290,'DL',58),('all',290,'LB',56),('all',290,'CB',56),('all',290,'S',56),
('all',291,'QB',69),('all',291,'RB',89),('all',291,'WR',92),('all',291,'TE',78),('all',291,'OL',68),('all',291,'DL',72),('all',291,'LB',75),('all',291,'CB',91),('all',291,'S',80),
('all',292,'QB',53),('all',292,'RB',56),('all',292,'WR',54),('all',292,'TE',52),('all',292,'OL',56),('all',292,'DL',59),('all',292,'LB',59),('all',292,'CB',54),('all',292,'S',55),
('all',293,'QB',54),('all',293,'RB',51),('all',293,'WR',51),('all',293,'TE',53),('all',293,'OL',55),('all',293,'DL',54),('all',293,'LB',51),('all',293,'CB',49),('all',293,'S',48),
('all',294,'QB',64),('all',294,'RB',62),('all',294,'WR',61),('all',294,'TE',64),('all',294,'OL',65),('all',294,'DL',65),('all',294,'LB',63),('all',294,'CB',60),('all',294,'S',60),
('all',295,'QB',77),('all',295,'RB',73),('all',295,'WR',73),('all',295,'TE',76),('all',295,'OL',75),('all',295,'DL',75),('all',295,'LB',74),('all',295,'CB',71),('all',295,'S',73),
('all',296,'QB',49),('all',296,'RB',50),('all',296,'WR',49),('all',296,'TE',56),('all',296,'OL',60),('all',296,'DL',58),('all',296,'LB',53),('all',296,'CB',48),('all',296,'S',49),
('all',297,'QB',65),('all',297,'RB',70),('all',297,'WR',67),('all',297,'TE',77),('all',297,'OL',80),('all',297,'DL',80),('all',297,'LB',76),('all',297,'CB',65),('all',297,'S',70),
('all',298,'QB',48),('all',298,'RB',47),('all',298,'WR',49),('all',298,'TE',46),('all',298,'OL',47),('all',298,'DL',46),('all',298,'LB',46),('all',298,'CB',48),('all',298,'S',47),
('all',299,'QB',64),('all',299,'RB',58),('all',299,'WR',57),('all',299,'TE',67),('all',299,'OL',74),('all',299,'DL',69),('all',299,'LB',67),('all',299,'CB',61),('all',299,'S',67),
('all',300,'QB',54),('all',300,'RB',56),('all',300,'WR',58),('all',300,'TE',56),('all',300,'OL',57),('all',300,'DL',56),('all',300,'LB',54),('all',300,'CB',57),('all',300,'S',54),
('all',301,'QB',66),('all',301,'RB',73),('all',301,'WR',74),('all',301,'TE',70),('all',301,'OL',68),('all',301,'DL',68),('all',301,'LB',69),('all',301,'CB',74),('all',301,'S',70),
('all',302,'QB',67),('all',302,'RB',64),('all',302,'WR',63),('all',302,'TE',64),('all',302,'OL',66),('all',302,'DL',66),('all',302,'LB',67),('all',302,'CB',64),('all',302,'S',66),
('all',303,'QB',64),('all',303,'RB',64),('all',303,'WR',63),('all',303,'TE',65),('all',303,'OL',68),('all',303,'DL',69),('all',303,'LB',68),('all',303,'CB',64),('all',303,'S',66),
('all',304,'QB',57),('all',304,'RB',55),('all',304,'WR',54),('all',304,'TE',62),('all',304,'OL',68),('all',304,'DL',68),('all',304,'LB',63),('all',304,'CB',56),('all',304,'S',59),
('all',305,'QB',64),('all',305,'RB',63),('all',305,'WR',60),('all',305,'TE',72),('all',305,'OL',79),('all',305,'DL',78),('all',305,'LB',74),('all',305,'CB',63),('all',305,'S',69),
('all',306,'QB',71),('all',306,'RB',70),('all',306,'WR',66),('all',306,'TE',82),('all',306,'OL',90),('all',306,'DL',89),('all',306,'LB',85),('all',306,'CB',71),('all',306,'S',80),
('all',307,'QB',57),('all',307,'RB',60),('all',307,'WR',62),('all',307,'TE',58),('all',307,'OL',58),('all',307,'DL',57),('all',307,'LB',57),('all',307,'CB',62),('all',307,'S',59),
('all',308,'QB',69),('all',308,'RB',72),('all',308,'WR',73),('all',308,'TE',71),('all',308,'OL',70),('all',308,'DL',68),('all',308,'LB',69),('all',308,'CB',73),('all',308,'S',72),
('all',309,'QB',61),('all',309,'RB',61),('all',309,'WR',63),('all',309,'TE',59),('all',309,'OL',58),('all',309,'DL',57),('all',309,'LB',56),('all',309,'CB',62),('all',309,'S',58),
('all',310,'QB',79),('all',310,'RB',80),('all',310,'WR',81),('all',310,'TE',76),('all',310,'OL',72),('all',310,'DL',72),('all',310,'LB',74),('all',310,'CB',81),('all',310,'S',76),
('all',311,'QB',74),('all',311,'RB',75),('all',311,'WR',78),('all',311,'TE',66),('all',311,'OL',61),('all',311,'DL',61),('all',311,'LB',66),('all',311,'CB',77),('all',311,'S',71),
('all',312,'QB',73),('all',312,'RB',75),('all',312,'WR',79),('all',312,'TE',67),('all',312,'OL',61),('all',312,'DL',60),('all',312,'LB',66),('all',312,'CB',78),('all',312,'S',72),
('all',313,'QB',69),('all',313,'RB',75),('all',313,'WR',76),('all',313,'TE',72),('all',313,'OL',70),('all',313,'DL',70),('all',313,'LB',72),('all',313,'CB',76),('all',313,'S',74),
('all',314,'QB',73),('all',314,'RB',74),('all',314,'WR',76),('all',314,'TE',70),('all',314,'OL',67),('all',314,'DL',66),('all',314,'LB',69),('all',314,'CB',76),('all',314,'S',73),
('all',315,'QB',75),('all',315,'RB',69),('all',315,'WR',70),('all',315,'TE',62),('all',315,'OL',59),('all',315,'DL',61),('all',315,'LB',64),('all',315,'CB',69),('all',315,'S',66),
('all',316,'QB',58),('all',316,'RB',57),('all',316,'WR',58),('all',316,'TE',57),('all',316,'OL',58),('all',316,'DL',57),('all',316,'LB',56),('all',316,'CB',57),('all',316,'S',57),
('all',317,'QB',73),('all',317,'RB',69),('all',317,'WR',69),('all',317,'TE',74),('all',317,'OL',76),('all',317,'DL',73),('all',317,'LB',72),('all',317,'CB',69),('all',317,'S',72),
('all',318,'QB',59),('all',318,'RB',63),('all',318,'WR',62),('all',318,'TE',61),('all',318,'OL',61),('all',318,'DL',64),('all',318,'LB',60),('all',318,'CB',60),('all',318,'S',57),
('all',319,'QB',74),('all',319,'RB',78),('all',319,'WR',76),('all',319,'TE',76),('all',319,'OL',75),('all',319,'DL',78),('all',319,'LB',76),('all',319,'CB',75),('all',319,'S',73),
('all',320,'QB',64),('all',320,'RB',65),('all',320,'WR',66),('all',320,'TE',69),('all',320,'OL',69),('all',320,'DL',67),('all',320,'LB',63),('all',320,'CB',63),('all',320,'S',61),
('all',321,'QB',74),('all',321,'RB',71),('all',321,'WR',71),('all',321,'TE',79),('all',321,'OL',80),('all',321,'DL',76),('all',321,'LB',73),('all',321,'CB',67),('all',321,'S',69),
('all',322,'QB',61),('all',322,'RB',56),('all',322,'WR',56),('all',322,'TE',58),('all',322,'OL',61),('all',322,'DL',60),('all',322,'LB',57),('all',322,'CB',55),('all',322,'S',55),
('all',323,'QB',77),('all',323,'RB',66),('all',323,'WR',63),('all',323,'TE',73),('all',323,'OL',78),('all',323,'DL',76),('all',323,'LB',74),('all',323,'CB',63),('all',323,'S',69),
('all',324,'QB',73),('all',324,'RB',61),('all',324,'WR',58),('all',324,'TE',71),('all',324,'OL',79),('all',324,'DL',77),('all',324,'LB',75),('all',324,'CB',61),('all',324,'S',70),
('all',325,'QB',66),('all',325,'RB',62),('all',325,'WR',65),('all',325,'TE',61),('all',325,'OL',59),('all',325,'DL',56),('all',325,'LB',57),('all',325,'CB',64),('all',325,'S',60),
('all',326,'QB',80),('all',326,'RB',74),('all',326,'WR',76),('all',326,'TE',74),('all',326,'OL',72),('all',326,'DL',68),('all',326,'LB',71),('all',326,'CB',77),('all',326,'S',76),
('all',327,'QB',65),('all',327,'RB',65),('all',327,'WR',66),('all',327,'TE',63),('all',327,'OL',63),('all',327,'DL',62),('all',327,'LB',63),('all',327,'CB',65),('all',327,'S',64),
('all',328,'QB',56),('all',328,'RB',52),('all',328,'WR',48),('all',328,'TE',56),('all',328,'OL',63),('all',328,'DL',65),('all',328,'LB',60),('all',328,'CB',48),('all',328,'S',53),
('all',329,'QB',62),('all',329,'RB',66),('all',329,'WR',66),('all',329,'TE',64),('all',329,'OL',64),('all',329,'DL',64),('all',329,'LB',63),('all',329,'CB',66),('all',329,'S',63),
('all',330,'QB',77),('all',330,'RB',82),('all',330,'WR',83),('all',330,'TE',82),('all',330,'OL',79),('all',330,'DL',80),('all',330,'LB',80),('all',330,'CB',82),('all',330,'S',81),
('all',331,'QB',65),('all',331,'RB',58),('all',331,'WR',56),('all',331,'TE',61),('all',331,'OL',64),('all',331,'DL',65),('all',331,'LB',61),('all',331,'CB',55),('all',331,'S',57),
('all',332,'QB',79),('all',332,'RB',70),('all',332,'WR',67),('all',332,'TE',73),('all',332,'OL',76),('all',332,'DL',77),('all',332,'LB',75),('all',332,'CB',67),('all',332,'S',71),
('all',333,'QB',60),('all',333,'RB',60),('all',333,'WR',62),('all',333,'TE',56),('all',333,'OL',55),('all',333,'DL',55),('all',333,'LB',57),('all',333,'CB',63),('all',333,'S',61),
('all',334,'QB',76),('all',334,'RB',77),('all',334,'WR',78),('all',334,'TE',76),('all',334,'OL',74),('all',334,'DL',73),('all',334,'LB',75),('all',334,'CB',78),('all',334,'S',78),
('all',335,'QB',69),('all',335,'RB',78),('all',335,'WR',77),('all',335,'TE',76),('all',335,'OL',74),('all',335,'DL',77),('all',335,'LB',77),('all',335,'CB',76),('all',335,'S',75),
('all',336,'QB',76),('all',336,'RB',71),('all',336,'WR',70),('all',336,'TE',73),('all',336,'OL',75),('all',336,'DL',75),('all',336,'LB',73),('all',336,'CB',69),('all',336,'S',71),
('all',337,'QB',77),('all',337,'RB',71),('all',337,'WR',72),('all',337,'TE',73),('all',337,'OL',73),('all',337,'DL',69),('all',337,'LB',70),('all',337,'CB',72),('all',337,'S',72),
('all',338,'QB',68),('all',338,'RB',72),('all',338,'WR',71),('all',338,'TE',76),('all',338,'OL',78),('all',338,'DL',77),('all',338,'LB',76),('all',338,'CB',71),('all',338,'S',73),
('all',339,'QB',57),('all',339,'RB',61),('all',339,'WR',63),('all',339,'TE',55),('all',339,'OL',53),('all',339,'DL',55),('all',339,'LB',55),('all',339,'CB',62),('all',339,'S',57),
('all',340,'QB',73),('all',340,'RB',71),('all',340,'WR',71),('all',340,'TE',72),('all',340,'OL',72),('all',340,'DL',71),('all',340,'LB',72),('all',340,'CB',69),('all',340,'S',71),
('all',341,'QB',57),('all',341,'RB',56),('all',341,'WR',55),('all',341,'TE',58),('all',341,'OL',62),('all',341,'DL',64),('all',341,'LB',61),('all',341,'CB',55),('all',341,'S',57),
('all',342,'QB',73),('all',342,'RB',70),('all',342,'WR',67),('all',342,'TE',73),('all',342,'OL',76),('all',342,'DL',79),('all',342,'LB',77),('all',342,'CB',67),('all',342,'S',72),
('all',343,'QB',59),('all',343,'RB',60),('all',343,'WR',61),('all',343,'TE',60),('all',343,'OL',60),('all',343,'DL',58),('all',343,'LB',58),('all',343,'CB',62),('all',343,'S',60),
('all',344,'QB',78),('all',344,'RB',76),('all',344,'WR',76),('all',344,'TE',79),('all',344,'OL',80),('all',344,'DL',76),('all',344,'LB',78),('all',344,'CB',78),('all',344,'S',81),
('all',345,'QB',65),('all',345,'RB',56),('all',345,'WR',56),('all',345,'TE',61),('all',345,'OL',65),('all',345,'DL',61),('all',345,'LB',60),('all',345,'CB',57),('all',345,'S',60),
('all',346,'QB',78),('all',346,'RB',69),('all',346,'WR',68),('all',346,'TE',75),('all',346,'OL',78),('all',346,'DL',76),('all',346,'LB',76),('all',346,'CB',69),('all',346,'S',75),
('all',347,'QB',60),('all',347,'RB',69),('all',347,'WR',68),('all',347,'TE',66),('all',347,'OL',65),('all',347,'DL',68),('all',347,'LB',67),('all',347,'CB',68),('all',347,'S',65),
('all',348,'QB',73),('all',348,'RB',70),('all',348,'WR',66),('all',348,'TE',76),('all',348,'OL',81),('all',348,'DL',83),('all',348,'LB',80),('all',348,'CB',68),('all',348,'S',75),
('all',349,'QB',50),('all',349,'RB',60),('all',349,'WR',64),('all',349,'TE',54),('all',349,'OL',50),('all',349,'DL',48),('all',349,'LB',50),('all',349,'CB',63),('all',349,'S',55),
('all',350,'QB',85),('all',350,'RB',78),('all',350,'WR',80),('all',350,'TE',82),('all',350,'OL',81),('all',350,'DL',75),('all',350,'LB',77),('all',350,'CB',80),('all',350,'S',81),
('all',351,'QB',70),('all',351,'RB',71),('all',351,'WR',72),('all',351,'TE',64),('all',351,'OL',61),('all',351,'DL',64),('all',351,'LB',68),('all',351,'CB',72),('all',351,'S',70),
('all',352,'QB',73),('all',352,'RB',67),('all',352,'WR',65),('all',352,'TE',70),('all',352,'OL',72),('all',352,'DL',71),('all',352,'LB',73),('all',352,'CB',66),('all',352,'S',72),
('all',353,'QB',59),('all',353,'RB',59),('all',353,'WR',59),('all',353,'TE',55),('all',353,'OL',56),('all',353,'DL',59),('all',353,'LB',57),('all',353,'CB',57),('all',353,'S',55),
('all',354,'QB',73),('all',354,'RB',73),('all',354,'WR',70),('all',354,'TE',71),('all',354,'OL',72),('all',354,'DL',75),('all',354,'LB',75),('all',354,'CB',70),('all',354,'S',72),
('all',355,'QB',58),('all',355,'RB',54),('all',355,'WR',54),('all',355,'TE',58),('all',355,'OL',63),('all',355,'DL',60),('all',355,'LB',59),('all',355,'CB',57),('all',355,'S',60),
('all',356,'QB',74),('all',356,'RB',63),('all',356,'WR',61),('all',356,'TE',71),('all',356,'OL',78),('all',356,'DL',74),('all',356,'LB',74),('all',356,'CB',66),('all',356,'S',74),
('all',357,'QB',73),('all',357,'RB',68),('all',357,'WR',68),('all',357,'TE',73),('all',357,'OL',76),('all',357,'DL',72),('all',357,'LB',72),('all',357,'CB',68),('all',357,'S',71),
('all',358,'QB',78),('all',358,'RB',72),('all',358,'WR',73),('all',358,'TE',66),('all',358,'OL',64),('all',358,'DL',63),('all',358,'LB',68),('all',358,'CB',74),('all',358,'S',72),
('all',359,'QB',72),('all',359,'RB',76),('all',359,'WR',73),('all',359,'TE',75),('all',359,'OL',76),('all',359,'DL',79),('all',359,'LB',78),('all',359,'CB',72),('all',359,'S',74),
('all',360,'QB',52),('all',360,'RB',50),('all',360,'WR',52),('all',360,'TE',54),('all',360,'OL',56),('all',360,'DL',52),('all',360,'LB',51),('all',360,'CB',51),('all',360,'S',51),
('all',361,'QB',59),('all',361,'RB',59),('all',361,'WR',60),('all',361,'TE',59),('all',361,'OL',60),('all',361,'DL',59),('all',361,'LB',58),('all',361,'CB',59),('all',361,'S',57),
('all',362,'QB',75),('all',362,'RB',75),('all',362,'WR',75),('all',362,'TE',78),('all',362,'OL',78),('all',362,'DL',76),('all',362,'LB',75),('all',362,'CB',75),('all',362,'S',76),
('all',363,'QB',59),('all',363,'RB',52),('all',363,'WR',53),('all',363,'TE',57),('all',363,'OL',61),('all',363,'DL',58),('all',363,'LB',55),('all',363,'CB',52),('all',363,'S',54),
('all',364,'QB',69),('all',364,'RB',63),('all',364,'WR',63),('all',364,'TE',68),('all',364,'OL',71),('all',364,'DL',67),('all',364,'LB',66),('all',364,'CB',63),('all',364,'S',65),
('all',365,'QB',80),('all',365,'RB',74),('all',365,'WR',74),('all',365,'TE',79),('all',365,'OL',80),('all',365,'DL',77),('all',365,'LB',77),('all',365,'CB',74),('all',365,'S',77),
('all',366,'QB',64),('all',366,'RB',57),('all',366,'WR',55),('all',366,'TE',62),('all',366,'OL',67),('all',366,'DL',66),('all',366,'LB',63),('all',366,'CB',57),('all',366,'S',60),
('all',367,'QB',77),('all',367,'RB',71),('all',367,'WR',68),('all',367,'TE',74),('all',367,'OL',78),('all',367,'DL',79),('all',367,'LB',78),('all',367,'CB',69),('all',367,'S',75),
('all',368,'QB',80),('all',368,'RB',69),('all',368,'WR',68),('all',368,'TE',73),('all',368,'OL',77),('all',368,'DL',75),('all',368,'LB',75),('all',368,'CB',69),('all',368,'S',74),
('all',369,'QB',68),('all',369,'RB',70),('all',369,'WR',69),('all',369,'TE',75),('all',369,'OL',78),('all',369,'DL',78),('all',369,'LB',77),('all',369,'CB',71),('all',369,'S',75),
('all',370,'QB',62),('all',370,'RB',71),('all',370,'WR',74),('all',370,'TE',64),('all',370,'OL',59),('all',370,'DL',57),('all',370,'LB',61),('all',370,'CB',74),('all',370,'S',67),
('all',371,'QB',56),('all',371,'RB',59),('all',371,'WR',58),('all',371,'TE',61),('all',371,'OL',64),('all',371,'DL',65),('all',371,'LB',61),('all',371,'CB',58),('all',371,'S',58),
('all',372,'QB',65),('all',372,'RB',65),('all',372,'WR',63),('all',372,'TE',71),('all',372,'OL',76),('all',372,'DL',76),('all',372,'LB',72),('all',372,'CB',64),('all',372,'S',68),
('all',373,'QB',85),('all',373,'RB',87),('all',373,'WR',85),('all',373,'TE',87),('all',373,'OL',85),('all',373,'DL',88),('all',373,'LB',87),('all',373,'CB',85),('all',373,'S',85),
('all',374,'QB',57),('all',374,'RB',54),('all',374,'WR',53),('all',374,'TE',61),('all',374,'OL',66),('all',374,'DL',64),('all',374,'LB',60),('all',374,'CB',55),('all',374,'S',58),
('all',375,'QB',67),('all',375,'RB',65),('all',375,'WR',64),('all',375,'TE',72),('all',375,'OL',77),('all',375,'DL',74),('all',375,'LB',71),('all',375,'CB',66),('all',375,'S',70),
('all',376,'QB',83),('all',376,'RB',80),('all',376,'WR',76),('all',376,'TE',88),('all',376,'OL',92),('all',376,'DL',93),('all',376,'LB',90),('all',376,'CB',78),('all',376,'S',85),
('all',377,'QB',75),('all',377,'RB',74),('all',377,'WR',71),('all',377,'TE',85),('all',377,'OL',92),('all',377,'DL',90),('all',377,'LB',88),('all',377,'CB',76),('all',377,'S',86),
('all',378,'QB',90),('all',378,'RB',75),('all',378,'WR',76),('all',378,'TE',82),('all',378,'OL',83),('all',378,'DL',75),('all',378,'LB',78),('all',378,'CB',79),('all',378,'S',84),
('all',379,'QB',84),('all',379,'RB',75),('all',379,'WR',73),('all',379,'TE',84),('all',379,'OL',89),('all',379,'DL',83),('all',379,'LB',85),('all',379,'CB',77),('all',379,'S',86),
('all',380,'QB',91),('all',380,'RB',89),('all',380,'WR',90),('all',380,'TE',86),('all',380,'OL',81),('all',380,'DL',80),('all',380,'LB',84),('all',380,'CB',91),('all',380,'S',90),
('all',381,'QB',92),('all',381,'RB',88),('all',381,'WR',89),('all',381,'TE',86),('all',381,'OL',82),('all',381,'DL',81),('all',381,'LB',84),('all',381,'CB',89),('all',381,'S',87),
('all',382,'QB',99),('all',382,'RB',88),('all',382,'WR',87),('all',382,'TE',92),('all',382,'OL',91),('all',382,'DL',87),('all',382,'LB',89),('all',382,'CB',88),('all',382,'S',91),
('all',383,'QB',87),('all',383,'RB',88),('all',383,'WR',84),('all',383,'TE',96),('all',383,'OL',99),('all',383,'DL',99),('all',383,'LB',96),('all',383,'CB',86),('all',383,'S',92),
('all',384,'QB',96),('all',384,'RB',91),('all',384,'WR',87),('all',384,'TE',93),('all',384,'OL',94),('all',384,'DL',95),('all',384,'LB',94),('all',384,'CB',87),('all',384,'S',90),
('all',385,'QB',86),('all',385,'RB',88),('all',385,'WR',89),('all',385,'TE',80),('all',385,'OL',73),('all',385,'DL',78),('all',385,'LB',84),('all',385,'CB',89),('all',385,'S',87),
('all',386,'QB',91),('all',386,'RB',97),('all',386,'WR',95),('all',386,'TE',88),('all',386,'OL',82),('all',386,'DL',89),('all',386,'LB',89),('all',386,'CB',94),('all',386,'S',88),
('all',387,'QB',58),('all',387,'RB',56),('all',387,'WR',56),('all',387,'TE',58),('all',387,'OL',61),('all',387,'DL',62),('all',387,'LB',60),('all',387,'CB',56),('all',387,'S',58),
('all',388,'QB',65),('all',388,'RB',62),('all',388,'WR',60),('all',388,'TE',69),('all',388,'OL',74),('all',388,'DL',73),('all',388,'LB',70),('all',388,'CB',61),('all',388,'S',66),
('all',389,'QB',76),('all',389,'RB',73),('all',389,'WR',70),('all',389,'TE',81),('all',389,'OL',86),('all',389,'DL',84),('all',389,'LB',81),('all',389,'CB',71),('all',389,'S',78),
('all',390,'QB',60),('all',390,'RB',62),('all',390,'WR',63),('all',390,'TE',59),('all',390,'OL',57),('all',390,'DL',59),('all',390,'LB',58),('all',390,'CB',62),('all',390,'S',59),
('all',391,'QB',69),('all',391,'RB',71),('all',391,'WR',72),('all',391,'TE',69),('all',391,'OL',67),('all',391,'DL',68),('all',391,'LB',68),('all',391,'CB',71),('all',391,'S',68),
('all',392,'QB',81),('all',392,'RB',85),('all',392,'WR',85),('all',392,'TE',81),('all',392,'OL',77),('all',392,'DL',79),('all',392,'LB',80),('all',392,'CB',84),('all',392,'S',81),
('all',393,'QB',62),('all',393,'RB',58),('all',393,'WR',58),('all',393,'TE',57),('all',393,'OL',58),('all',393,'DL',58),('all',393,'LB',58),('all',393,'CB',58),('all',393,'S',58),
('all',394,'QB',71),('all',394,'RB',65),('all',394,'WR',65),('all',394,'TE',67),('all',394,'OL',68),('all',394,'DL',67),('all',394,'LB',66),('all',394,'CB',65),('all',394,'S',66),
('all',395,'QB',84),('all',395,'RB',74),('all',395,'WR',72),('all',395,'TE',78),('all',395,'OL',80),('all',395,'DL',77),('all',395,'LB',78),('all',395,'CB',73),('all',395,'S',77),
('all',396,'QB',52),('all',396,'RB',59),('all',396,'WR',60),('all',396,'TE',53),('all',396,'OL',51),('all',396,'DL',53),('all',396,'LB',54),('all',396,'CB',59),('all',396,'S',54),
('all',397,'QB',59),('all',397,'RB',68),('all',397,'WR',69),('all',397,'TE',65),('all',397,'OL',63),('all',397,'DL',65),('all',397,'LB',64),('all',397,'CB',68),('all',397,'S',64),
('all',398,'QB',69),('all',398,'RB',82),('all',398,'WR',81),('all',398,'TE',79),('all',398,'OL',76),('all',398,'DL',80),('all',398,'LB',80),('all',398,'CB',80),('all',398,'S',78),
('all',399,'QB',53),('all',399,'RB',52),('all',399,'WR',52),('all',399,'TE',54),('all',399,'OL',57),('all',399,'DL',55),('all',399,'LB',53),('all',399,'CB',52),('all',399,'S',52),
('all',400,'QB',66),('all',400,'RB',70),('all',400,'WR',70),('all',400,'TE',70),('all',400,'OL',70),('all',400,'DL',70),('all',400,'LB',70),('all',400,'CB',69),('all',400,'S',69),
('all',401,'QB',49),('all',401,'RB',48),('all',401,'WR',49),('all',401,'TE',46),('all',401,'OL',48),('all',401,'DL',47),('all',401,'LB',47),('all',401,'CB',49),('all',401,'S',48),
('all',402,'QB',65),('all',402,'RB',68),('all',402,'WR',67),('all',402,'TE',67),('all',402,'OL',67),('all',402,'DL',68),('all',402,'LB',68),('all',402,'CB',66),('all',402,'S',66),
('all',403,'QB',54),('all',403,'RB',56),('all',403,'WR',56),('all',403,'TE',55),('all',403,'OL',57),('all',403,'DL',58),('all',403,'LB',56),('all',403,'CB',56),('all',403,'S',54),
('all',404,'QB',64),('all',404,'RB',65),('all',404,'WR',64),('all',404,'TE',65),('all',404,'OL',67),('all',404,'DL',67),('all',404,'LB',66),('all',404,'CB',64),('all',404,'S',63),
('all',405,'QB',79),('all',405,'RB',77),('all',405,'WR',74),('all',405,'TE',78),('all',405,'OL',79),('all',405,'DL',81),('all',405,'LB',80),('all',405,'CB',74),('all',405,'S',77),
('all',406,'QB',61),('all',406,'RB',60),('all',406,'WR',62),('all',406,'TE',53),('all',406,'OL',50),('all',406,'DL',51),('all',406,'LB',53),('all',406,'CB',62),('all',406,'S',58),
('all',407,'QB',87),('all',407,'RB',80),('all',407,'WR',81),('all',407,'TE',76),('all',407,'OL',72),('all',407,'DL',72),('all',407,'LB',75),('all',407,'CB',81),('all',407,'S',79),
('all',408,'QB',55),('all',408,'RB',65),('all',408,'WR',62),('all',408,'TE',66),('all',408,'OL',67),('all',408,'DL',72),('all',408,'LB',68),('all',408,'CB',61),('all',408,'S',61),
('all',409,'QB',70),('all',409,'RB',74),('all',409,'WR',69),('all',409,'TE',78),('all',409,'OL',81),('all',409,'DL',86),('all',409,'LB',82),('all',409,'CB',67),('all',409,'S',73),
('all',410,'QB',62),('all',410,'RB',56),('all',410,'WR',56),('all',410,'TE',64),('all',410,'OL',70),('all',410,'DL',65),('all',410,'LB',64),('all',410,'CB',60),('all',410,'S',64),
('all',411,'QB',74),('all',411,'RB',66),('all',411,'WR',64),('all',411,'TE',77),('all',411,'OL',85),('all',411,'DL',77),('all',411,'LB',78),('all',411,'CB',70),('all',411,'S',80),
('all',412,'QB',52),('all',412,'RB',52),('all',412,'WR',54),('all',412,'TE',50),('all',412,'OL',51),('all',412,'DL',50),('all',412,'LB',50),('all',412,'CB',53),('all',412,'S',51),
('all',413,'QB',74),('all',413,'RB',64),('all',413,'WR',64),('all',413,'TE',65),('all',413,'OL',68),('all',413,'DL',66),('all',413,'LB',68),('all',413,'CB',65),('all',413,'S',69),
('all',414,'QB',73),('all',414,'RB',70),('all',414,'WR',69),('all',414,'TE',69),('all',414,'OL',69),('all',414,'DL',70),('all',414,'LB',70),('all',414,'CB',68),('all',414,'S',68),
('all',415,'QB',53),('all',415,'RB',60),('all',415,'WR',63),('all',415,'TE',55),('all',415,'OL',52),('all',415,'DL',52),('all',415,'LB',53),('all',415,'CB',62),('all',415,'S',56),
('all',416,'QB',76),('all',416,'RB',67),('all',416,'WR',66),('all',416,'TE',72),('all',416,'OL',77),('all',416,'DL',74),('all',416,'LB',74),('all',416,'CB',67),('all',416,'S',74),
('all',417,'QB',68),('all',417,'RB',76),('all',417,'WR',79),('all',417,'TE',68),('all',417,'OL',63),('all',417,'DL',63),('all',417,'LB',68),('all',417,'CB',79),('all',417,'S',74),
('all',418,'QB',61),('all',418,'RB',67),('all',418,'WR',69),('all',418,'TE',64),('all',418,'OL',61),('all',418,'DL',63),('all',418,'LB',61),('all',418,'CB',67),('all',418,'S',61),
('all',419,'QB',75),('all',419,'RB',84),('all',419,'WR',85),('all',419,'TE',79),('all',419,'OL',73),('all',419,'DL',77),('all',419,'LB',77),('all',419,'CB',83),('all',419,'S',78),
('all',420,'QB',60),('all',420,'RB',54),('all',420,'WR',56),('all',420,'TE',53),('all',420,'OL',54),('all',420,'DL',53),('all',420,'LB',53),('all',420,'CB',55),('all',420,'S',54),
('all',421,'QB',75),('all',421,'RB',75),('all',421,'WR',76),('all',421,'TE',70),('all',421,'OL',67),('all',421,'DL',67),('all',421,'LB',70),('all',421,'CB',76),('all',421,'S',73),
('all',422,'QB',61),('all',422,'RB',57),('all',422,'WR',58),('all',422,'TE',57),('all',422,'OL',57),('all',422,'DL',57),('all',422,'LB',57),('all',422,'CB',57),('all',422,'S',57),
('all',423,'QB',76),('all',423,'RB',67),('all',423,'WR',66),('all',423,'TE',71),('all',423,'OL',73),('all',423,'DL',71),('all',423,'LB',71),('all',423,'CB',65),('all',423,'S',69),
('all',424,'QB',72),('all',424,'RB',84),('all',424,'WR',85),('all',424,'TE',78),('all',424,'OL',73),('all',424,'DL',76),('all',424,'LB',78),('all',424,'CB',84),('all',424,'S',79),
('all',425,'QB',62),('all',425,'RB',66),('all',425,'WR',69),('all',425,'TE',59),('all',425,'OL',54),('all',425,'DL',57),('all',425,'LB',58),('all',425,'CB',66),('all',425,'S',60),
('all',426,'QB',75),('all',426,'RB',76),('all',426,'WR',78),('all',426,'TE',74),('all',426,'OL',69),('all',426,'DL',70),('all',426,'LB',71),('all',426,'CB',74),('all',426,'S',71),
('all',427,'QB',61),('all',427,'RB',70),('all',427,'WR',72),('all',427,'TE',64),('all',427,'OL',59),('all',427,'DL',62),('all',427,'LB',63),('all',427,'CB',71),('all',427,'S',65),
('all',428,'QB',73),('all',428,'RB',82),('all',428,'WR',83),('all',428,'TE',78),('all',428,'OL',74),('all',428,'DL',74),('all',428,'LB',77),('all',428,'CB',84),('all',428,'S',81),
('all',429,'QB',84),('all',429,'RB',83),('all',429,'WR',85),('all',429,'TE',74),('all',429,'OL',68),('all',429,'DL',68),('all',429,'LB',73),('all',429,'CB',85),('all',429,'S',80),
('all',430,'QB',78),('all',430,'RB',76),('all',430,'WR',74),('all',430,'TE',75),('all',430,'OL',74),('all',430,'DL',78),('all',430,'LB',77),('all',430,'CB',72),('all',430,'S',73),
('all',431,'QB',58),('all',431,'RB',67),('all',431,'WR',70),('all',431,'TE',61),('all',431,'OL',57),('all',431,'DL',59),('all',431,'LB',59),('all',431,'CB',69),('all',431,'S',61),
('all',432,'QB',71),('all',432,'RB',81),('all',432,'WR',82),('all',432,'TE',76),('all',432,'OL',72),('all',432,'DL',73),('all',432,'LB',74),('all',432,'CB',81),('all',432,'S',76),
('all',433,'QB',61),('all',433,'RB',57),('all',433,'WR',60),('all',433,'TE',51),('all',433,'OL',50),('all',433,'DL',51),('all',433,'LB',53),('all',433,'CB',59),('all',433,'S',55),
('all',434,'QB',58),('all',434,'RB',65),('all',434,'WR',67),('all',434,'TE',63),('all',434,'OL',61),('all',434,'DL',62),('all',434,'LB',61),('all',434,'CB',66),('all',434,'S',61),
('all',435,'QB',72),('all',435,'RB',77),('all',435,'WR',77),('all',435,'TE',76),('all',435,'OL',74),('all',435,'DL',75),('all',435,'LB',75),('all',435,'CB',75),('all',435,'S',74),
('all',436,'QB',57),('all',436,'RB',53),('all',436,'WR',53),('all',436,'TE',59),('all',436,'OL',64),('all',436,'DL',58),('all',436,'LB',57),('all',436,'CB',55),('all',436,'S',59),
('all',437,'QB',78),('all',437,'RB',67),('all',437,'WR',64),('all',437,'TE',76),('all',437,'OL',83),('all',437,'DL',79),('all',437,'LB',78),('all',437,'CB',67),('all',437,'S',76),
('all',438,'QB',50),('all',438,'RB',51),('all',438,'WR',48),('all',438,'TE',57),('all',438,'OL',65),('all',438,'DL',65),('all',438,'LB',61),('all',438,'CB',50),('all',438,'S',56),
('all',439,'QB',67),('all',439,'RB',61),('all',439,'WR',64),('all',439,'TE',59),('all',439,'OL',58),('all',439,'DL',55),('all',439,'LB',57),('all',439,'CB',65),('all',439,'S',62),
('all',440,'QB',51),('all',440,'RB',50),('all',440,'WR',54),('all',440,'TE',52),('all',440,'OL',51),('all',440,'DL',46),('all',440,'LB',46),('all',440,'CB',50),('all',440,'S',48),
('all',441,'QB',72),('all',441,'RB',74),('all',441,'WR',76),('all',441,'TE',65),('all',441,'OL',60),('all',441,'DL',63),('all',441,'LB',66),('all',441,'CB',74),('all',441,'S',68),
('all',442,'QB',79),('all',442,'RB',67),('all',442,'WR',64),('all',442,'TE',74),('all',442,'OL',80),('all',442,'DL',78),('all',442,'LB',77),('all',442,'CB',67),('all',442,'S',75),
('all',443,'QB',57),('all',443,'RB',58),('all',443,'WR',57),('all',443,'TE',59),('all',443,'OL',61),('all',443,'DL',62),('all',443,'LB',59),('all',443,'CB',57),('all',443,'S',57),
('all',444,'QB',65),('all',444,'RB',72),('all',444,'WR',72),('all',444,'TE',72),('all',444,'OL',71),('all',444,'DL',72),('all',444,'LB',71),('all',444,'CB',72),('all',444,'S',70),
('all',445,'QB',81),('all',445,'RB',88),('all',445,'WR',86),('all',445,'TE',88),('all',445,'OL',86),('all',445,'DL',88),('all',445,'LB',88),('all',445,'CB',86),('all',445,'S',87),
('all',446,'QB',62),('all',446,'RB',55),('all',446,'WR',53),('all',446,'TE',64),('all',446,'OL',68),('all',446,'DL',67),('all',446,'LB',64),('all',446,'CB',51),('all',446,'S',58),
('all',447,'QB',55),('all',447,'RB',61),('all',447,'WR',61),('all',447,'TE',60),('all',447,'OL',60),('all',447,'DL',61),('all',447,'LB',59),('all',447,'CB',60),('all',447,'S',58),
('all',448,'QB',83),('all',448,'RB',81),('all',448,'WR',79),('all',448,'TE',79),('all',448,'OL',78),('all',448,'DL',80),('all',448,'LB',80),('all',448,'CB',79),('all',448,'S',79),
('all',449,'QB',56),('all',449,'RB',56),('all',449,'WR',55),('all',449,'TE',62),('all',449,'OL',67),('all',449,'DL',66),('all',449,'LB',62),('all',449,'CB',55),('all',449,'S',58),
('all',450,'QB',73),('all',450,'RB',71),('all',450,'WR',68),('all',450,'TE',80),('all',450,'OL',86),('all',450,'DL',85),('all',450,'LB',81),('all',450,'CB',69),('all',450,'S',76),
('all',451,'QB',57),('all',451,'RB',63),('all',451,'WR',64),('all',451,'TE',63),('all',451,'OL',64),('all',451,'DL',63),('all',451,'LB',62),('all',451,'CB',66),('all',451,'S',64),
('all',452,'QB',72),('all',452,'RB',80),('all',452,'WR',80),('all',452,'TE',80),('all',452,'OL',79),('all',452,'DL',79),('all',452,'LB',79),('all',452,'CB',81),('all',452,'S',80),
('all',453,'QB',60),('all',453,'RB',59),('all',453,'WR',59),('all',453,'TE',59),('all',453,'OL',61),('all',453,'DL',61),('all',453,'LB',58),('all',453,'CB',58),('all',453,'S',57),
('all',454,'QB',75),('all',454,'RB',78),('all',454,'WR',77),('all',454,'TE',77),('all',454,'OL',75),('all',454,'DL',77),('all',454,'LB',77),('all',454,'CB',76),('all',454,'S',75),
('all',455,'QB',74),('all',455,'RB',68),('all',455,'WR',65),('all',455,'TE',71),('all',455,'OL',74),('all',455,'DL',74),('all',455,'LB',73),('all',455,'CB',66),('all',455,'S',70),
('all',456,'QB',61),('all',456,'RB',64),('all',456,'WR',66),('all',456,'TE',61),('all',456,'OL',59),('all',456,'DL',59),('all',456,'LB',60),('all',456,'CB',66),('all',456,'S',62),
('all',457,'QB',74),('all',457,'RB',77),('all',457,'WR',78),('all',457,'TE',74),('all',457,'OL',72),('all',457,'DL',71),('all',457,'LB',73),('all',457,'CB',79),('all',457,'S',76),
('all',458,'QB',69),('all',458,'RB',61),('all',458,'WR',63),('all',458,'TE',64),('all',458,'OL',64),('all',458,'DL',58),('all',458,'LB',59),('all',458,'CB',65),('all',458,'S',64),
('all',459,'QB',63),('all',459,'RB',59),('all',459,'WR',58),('all',459,'TE',62),('all',459,'OL',65),('all',459,'DL',63),('all',459,'LB',61),('all',459,'CB',58),('all',459,'S',59),
('all',460,'QB',78),('all',460,'RB',72),('all',460,'WR',71),('all',460,'TE',77),('all',460,'OL',79),('all',460,'DL',77),('all',460,'LB',76),('all',460,'CB',71),('all',460,'S',74),
('all',461,'QB',72),('all',461,'RB',89),('all',461,'WR',89),('all',461,'TE',83),('all',461,'OL',77),('all',461,'DL',81),('all',461,'LB',83),('all',461,'CB',88),('all',461,'S',84),
('all',462,'QB',86),('all',462,'RB',72),('all',462,'WR',71),('all',462,'TE',78),('all',462,'OL',82),('all',462,'DL',78),('all',462,'LB',78),('all',462,'CB',74),('all',462,'S',78),
('all',463,'QB',77),('all',463,'RB',71),('all',463,'WR',70),('all',463,'TE',78),('all',463,'OL',81),('all',463,'DL',78),('all',463,'LB',77),('all',463,'CB',70),('all',463,'S',75),
('all',464,'QB',69),('all',464,'RB',71),('all',464,'WR',66),('all',464,'TE',82),('all',464,'OL',90),('all',464,'DL',90),('all',464,'LB',85),('all',464,'CB',67),('all',464,'S',76),
('all',465,'QB',79),('all',465,'RB',70),('all',465,'WR',68),('all',465,'TE',78),('all',465,'OL',84),('all',465,'DL',83),('all',465,'LB',80),('all',465,'CB',69),('all',465,'S',75),
('all',466,'QB',81),('all',466,'RB',83),('all',466,'WR',81),('all',466,'TE',83),('all',466,'OL',81),('all',466,'DL',83),('all',466,'LB',83),('all',466,'CB',81),('all',466,'S',82),
('all',467,'QB',87),('all',467,'RB',80),('all',467,'WR',79),('all',467,'TE',79),('all',467,'OL',78),('all',467,'DL',78),('all',467,'LB',79),('all',467,'CB',79),('all',467,'S',79),
('all',468,'QB',88),('all',468,'RB',78),('all',468,'WR',80),('all',468,'TE',78),('all',468,'OL',77),('all',468,'DL',73),('all',468,'LB',76),('all',468,'CB',81),('all',468,'S',81),
('all',469,'QB',81),('all',469,'RB',79),('all',469,'WR',80),('all',469,'TE',79),('all',469,'OL',77),('all',469,'DL',76),('all',469,'LB',76),('all',469,'CB',80),('all',469,'S',77),
('all',470,'QB',72),('all',470,'RB',82),('all',470,'WR',81),('all',470,'TE',81),('all',470,'OL',81),('all',470,'DL',84),('all',470,'LB',83),('all',470,'CB',83),('all',470,'S',83),
('all',471,'QB',86),('all',471,'RB',74),('all',471,'WR',74),('all',471,'TE',75),('all',471,'OL',76),('all',471,'DL',74),('all',471,'LB',75),('all',471,'CB',76),('all',471,'S',78),
('all',472,'QB',70),('all',472,'RB',81),('all',472,'WR',81),('all',472,'TE',81),('all',472,'OL',81),('all',472,'DL',81),('all',472,'LB',81),('all',472,'CB',82),('all',472,'S',82),
('all',473,'QB',73),('all',473,'RB',79),('all',473,'WR',76),('all',473,'TE',83),('all',473,'OL',84),('all',473,'DL',86),('all',473,'LB',83),('all',473,'CB',75),('all',473,'S',78),
('all',474,'QB',87),('all',474,'RB',80),('all',474,'WR',81),('all',474,'TE',78),('all',474,'OL',75),('all',474,'DL',75),('all',474,'LB',77),('all',474,'CB',80),('all',474,'S',78),
('all',475,'QB',77),('all',475,'RB',80),('all',475,'WR',78),('all',475,'TE',80),('all',475,'OL',80),('all',475,'DL',81),('all',475,'LB',82),('all',475,'CB',78),('all',475,'S',81),
('all',476,'QB',82),('all',476,'RB',69),('all',476,'WR',68),('all',476,'TE',80),('all',476,'OL',86),('all',476,'DL',78),('all',476,'LB',79),('all',476,'CB',73),('all',476,'S',82),
('all',477,'QB',79),('all',477,'RB',72),('all',477,'WR',69),('all',477,'TE',80),('all',477,'OL',86),('all',477,'DL',83),('all',477,'LB',83),('all',477,'CB',73),('all',477,'S',83),
('all',478,'QB',76),('all',478,'RB',82),('all',478,'WR',83),('all',478,'TE',77),('all',478,'OL',73),('all',478,'DL',73),('all',478,'LB',75),('all',478,'CB',83),('all',478,'S',78),
('all',479,'QB',77),('all',479,'RB',76),('all',479,'WR',79),('all',479,'TE',65),('all',479,'OL',59),('all',479,'DL',62),('all',479,'LB',68),('all',479,'CB',79),('all',479,'S',74),
('all',480,'QB',84),('all',480,'RB',87),('all',480,'WR',89),('all',480,'TE',77),('all',480,'OL',71),('all',480,'DL',75),('all',480,'LB',83),('all',480,'CB',91),('all',480,'S',90),
('all',481,'QB',86),('all',481,'RB',84),('all',481,'WR',84),('all',481,'TE',75),('all',481,'OL',71),('all',481,'DL',77),('all',481,'LB',82),('all',481,'CB',84),('all',481,'S',85),
('all',482,'QB',87),('all',482,'RB',90),('all',482,'WR',91),('all',482,'TE',77),('all',482,'OL',68),('all',482,'DL',78),('all',482,'LB',83),('all',482,'CB',90),('all',482,'S',85),
('all',483,'QB',97),('all',483,'RB',88),('all',483,'WR',85),('all',483,'TE',94),('all',483,'OL',96),('all',483,'DL',94),('all',483,'LB',92),('all',483,'CB',87),('all',483,'S',91),
('all',484,'QB',99),('all',484,'RB',91),('all',484,'WR',89),('all',484,'TE',94),('all',484,'OL',93),('all',484,'DL',92),('all',484,'LB',92),('all',484,'CB',90),('all',484,'S',93),
('all',485,'QB',91),('all',485,'RB',81),('all',485,'WR',79),('all',485,'TE',86),('all',485,'OL',87),('all',485,'DL',84),('all',485,'LB',84),('all',485,'CB',80),('all',485,'S',84),
('all',486,'QB',86),('all',486,'RB',92),('all',486,'WR',89),('all',486,'TE',96),('all',486,'OL',96),('all',486,'DL',98),('all',486,'LB',97),('all',486,'CB',90),('all',486,'S',94),
('all',487,'QB',90),('all',487,'RB',88),('all',487,'WR',88),('all',487,'TE',95),('all',487,'OL',95),('all',487,'DL',91),('all',487,'LB',91),('all',487,'CB',88),('all',487,'S',92),
('all',488,'QB',82),('all',488,'RB',82),('all',488,'WR',83),('all',488,'TE',84),('all',488,'OL',82),('all',488,'DL',79),('all',488,'LB',82),('all',488,'CB',84),('all',488,'S',86),
('all',489,'QB',76),('all',489,'RB',77),('all',489,'WR',77),('all',489,'TE',71),('all',489,'OL',68),('all',489,'DL',70),('all',489,'LB',74),('all',489,'CB',77),('all',489,'S',76),
('all',490,'QB',86),('all',490,'RB',88),('all',490,'WR',89),('all',490,'TE',80),('all',490,'OL',74),('all',490,'DL',79),('all',490,'LB',84),('all',490,'CB',89),('all',490,'S',87),
('all',491,'QB',92),('all',491,'RB',91),('all',491,'WR',92),('all',491,'TE',86),('all',491,'OL',81),('all',491,'DL',82),('all',491,'LB',84),('all',491,'CB',93),('all',491,'S',88),
('all',492,'QB',86),('all',492,'RB',88),('all',492,'WR',89),('all',492,'TE',80),('all',492,'OL',74),('all',492,'DL',79),('all',492,'LB',84),('all',492,'CB',89),('all',492,'S',87),
('all',493,'QB',96),('all',493,'RB',97),('all',493,'WR',97),('all',493,'TE',99),('all',493,'OL',95),('all',493,'DL',95),('all',493,'LB',96),('all',493,'CB',98),('all',493,'S',98),
('all',494,'QB',86),('all',494,'RB',88),('all',494,'WR',88),('all',494,'TE',82),('all',494,'OL',76),('all',494,'DL',80),('all',494,'LB',84),('all',494,'CB',88),('all',494,'S',87),
('all',495,'QB',59),('all',495,'RB',62),('all',495,'WR',64),('all',495,'TE',59),('all',495,'OL',59),('all',495,'DL',58),('all',495,'LB',58),('all',495,'CB',63),('all',495,'S',60),
('all',496,'QB',68),('all',496,'RB',72),('all',496,'WR',74),('all',496,'TE',70),('all',496,'OL',68),('all',496,'DL',67),('all',496,'LB',68),('all',496,'CB',74),('all',496,'S',71),
('all',497,'QB',79),('all',497,'RB',85),('all',497,'WR',87),('all',497,'TE',83),('all',497,'OL',80),('all',497,'DL',78),('all',497,'LB',80),('all',497,'CB',88),('all',497,'S',84),
('all',498,'QB',58),('all',498,'RB',59),('all',498,'WR',59),('all',498,'TE',58),('all',498,'OL',59),('all',498,'DL',60),('all',498,'LB',58),('all',498,'CB',58),('all',498,'S',57),
('all',499,'QB',67),('all',499,'RB',67),('all',499,'WR',66),('all',499,'TE',69),('all',499,'OL',71),('all',499,'DL',71),('all',499,'LB',69),('all',499,'CB',64),('all',499,'S',66),
('all',500,'QB',79),('all',500,'RB',75),('all',500,'WR',73),('all',500,'TE',79),('all',500,'OL',81),('all',500,'DL',82),('all',500,'LB',80),('all',500,'CB',71),('all',500,'S',75),
('all',501,'QB',60),('all',501,'RB',58),('all',501,'WR',59),('all',501,'TE',57),('all',501,'OL',57),('all',501,'DL',58),('all',501,'LB',57),('all',501,'CB',58),('all',501,'S',57),
('all',502,'QB',70),('all',502,'RB',67),('all',502,'WR',67),('all',502,'TE',68),('all',502,'OL',68),('all',502,'DL',68),('all',502,'LB',67),('all',502,'CB',67),('all',502,'S',67),
('all',503,'QB',81),('all',503,'RB',76),('all',503,'WR',74),('all',503,'TE',79),('all',503,'OL',80),('all',503,'DL',80),('all',503,'LB',79),('all',503,'CB',74),('all',503,'S',76),
('all',504,'QB',53),('all',504,'RB',55),('all',504,'WR',55),('all',504,'TE',55),('all',504,'OL',56),('all',504,'DL',56),('all',504,'LB',55),('all',504,'CB',54),('all',504,'S',53),
('all',505,'QB',69),('all',505,'RB',72),('all',505,'WR',72),('all',505,'TE',71),('all',505,'OL',70),('all',505,'DL',71),('all',505,'LB',71),('all',505,'CB',72),('all',505,'S',72),
('all',506,'QB',53),('all',506,'RB',60),('all',506,'WR',61),('all',506,'TE',57),('all',506,'OL',56),('all',506,'DL',57),('all',506,'LB',57),('all',506,'CB',60),('all',506,'S',57),
('all',507,'QB',61),('all',507,'RB',66),('all',507,'WR',66),('all',507,'TE',66),('all',507,'OL',66),('all',507,'DL',67),('all',507,'LB',66),('all',507,'CB',66),('all',507,'S',66),
('all',508,'QB',71),('all',508,'RB',78),('all',508,'WR',77),('all',508,'TE',79),('all',508,'OL',79),('all',508,'DL',80),('all',508,'LB',80),('all',508,'CB',77),('all',508,'S',79),
('all',509,'QB',58),('all',509,'RB',61),('all',509,'WR',63),('all',509,'TE',58),('all',509,'OL',56),('all',509,'DL',57),('all',509,'LB',56),('all',509,'CB',62),('all',509,'S',57),
('all',510,'QB',74),('all',510,'RB',79),('all',510,'WR',80),('all',510,'TE',74),('all',510,'OL',71),('all',510,'DL',72),('all',510,'LB',73),('all',510,'CB',79),('all',510,'S',74),
('all',511,'QB',60),('all',511,'RB',62),('all',511,'WR',64),('all',511,'TE',60),('all',511,'OL',59),('all',511,'DL',59),('all',511,'LB',59),('all',511,'CB',64),('all',511,'S',60),
('all',512,'QB',78),('all',512,'RB',81),('all',512,'WR',81),('all',512,'TE',77),('all',512,'OL',74),('all',512,'DL',76),('all',512,'LB',77),('all',512,'CB',80),('all',512,'S',77),
('all',513,'QB',60),('all',513,'RB',62),('all',513,'WR',64),('all',513,'TE',60),('all',513,'OL',59),('all',513,'DL',59),('all',513,'LB',59),('all',513,'CB',64),('all',513,'S',60),
('all',514,'QB',78),('all',514,'RB',81),('all',514,'WR',81),('all',514,'TE',77),('all',514,'OL',74),('all',514,'DL',76),('all',514,'LB',77),('all',514,'CB',80),('all',514,'S',77),
('all',515,'QB',60),('all',515,'RB',62),('all',515,'WR',64),('all',515,'TE',61),('all',515,'OL',60),('all',515,'DL',60),('all',515,'LB',59),('all',515,'CB',63),('all',515,'S',60),
('all',516,'QB',78),('all',516,'RB',81),('all',516,'WR',81),('all',516,'TE',77),('all',516,'OL',74),('all',516,'DL',76),('all',516,'LB',77),('all',516,'CB',80),('all',516,'S',77),
('all',517,'QB',61),('all',517,'RB',52),('all',517,'WR',53),('all',517,'TE',56),('all',517,'OL',58),('all',517,'DL',54),('all',517,'LB',52),('all',517,'CB',52),('all',517,'S',53),
('all',518,'QB',80),('all',518,'RB',64),('all',518,'WR',64),('all',518,'TE',71),('all',518,'OL',74),('all',518,'DL',69),('all',518,'LB',70),('all',518,'CB',63),('all',518,'S',69),
('all',519,'QB',53),('all',519,'RB',56),('all',519,'WR',57),('all',519,'TE',53),('all',519,'OL',53),('all',519,'DL',55),('all',519,'LB',55),('all',519,'CB',56),('all',519,'S',54),
('all',520,'QB',61),('all',520,'RB',66),('all',520,'WR',66),('all',520,'TE',64),('all',520,'OL',65),('all',520,'DL',66),('all',520,'LB',65),('all',520,'CB',65),('all',520,'S',64),
('all',521,'QB',71),('all',521,'RB',80),('all',521,'WR',79),('all',521,'TE',78),('all',521,'OL',76),('all',521,'DL',79),('all',521,'LB',79),('all',521,'CB',78),('all',521,'S',77),
('all',522,'QB',58),('all',522,'RB',64),('all',522,'WR',65),('all',522,'TE',61),('all',522,'OL',60),('all',522,'DL',60),('all',522,'LB',58),('all',522,'CB',64),('all',522,'S',58),
('all',523,'QB',76),('all',523,'RB',85),('all',523,'WR',85),('all',523,'TE',81),('all',523,'OL',77),('all',523,'DL',78),('all',523,'LB',78),('all',523,'CB',84),('all',523,'S',80),
('all',524,'QB',50),('all',524,'RB',50),('all',524,'WR',48),('all',524,'TE',56),('all',524,'OL',63),('all',524,'DL',64),('all',524,'LB',59),('all',524,'CB',49),('all',524,'S',53),
('all',525,'QB',61),('all',525,'RB',57),('all',525,'WR',53),('all',525,'TE',67),('all',525,'OL',76),('all',525,'DL',76),('all',525,'LB',70),('all',525,'CB',55),('all',525,'S',62),
('all',526,'QB',71),('all',526,'RB',67),('all',526,'WR',61),('all',526,'TE',79),('all',526,'OL',88),('all',526,'DL',88),('all',526,'LB',83),('all',526,'CB',63),('all',526,'S',75),
('all',527,'QB',60),('all',527,'RB',65),('all',527,'WR',68),('all',527,'TE',59),('all',527,'OL',55),('all',527,'DL',56),('all',527,'LB',57),('all',527,'CB',66),('all',527,'S',60),
('all',528,'QB',72),('all',528,'RB',79),('all',528,'WR',82),('all',528,'TE',71),('all',528,'OL',65),('all',528,'DL',66),('all',528,'LB',69),('all',528,'CB',81),('all',528,'S',74),
('all',529,'QB',56),('all',529,'RB',65),('all',529,'WR',66),('all',529,'TE',62),('all',529,'OL',60),('all',529,'DL',63),('all',529,'LB',62),('all',529,'CB',64),('all',529,'S',61),
('all',530,'QB',70),('all',530,'RB',81),('all',530,'WR',79),('all',530,'TE',79),('all',530,'OL',77),('all',530,'DL',81),('all',530,'LB',81),('all',530,'CB',77),('all',530,'S',77),
('all',531,'QB',70),('all',531,'RB',67),('all',531,'WR',68),('all',531,'TE',71),('all',531,'OL',72),('all',531,'DL',69),('all',531,'LB',70),('all',531,'CB',68),('all',531,'S',71),
('all',532,'QB',53),('all',532,'RB',57),('all',532,'WR',56),('all',532,'TE',59),('all',532,'OL',62),('all',532,'DL',63),('all',532,'LB',60),('all',532,'CB',55),('all',532,'S',56),
('all',533,'QB',61),('all',533,'RB',64),('all',533,'WR',61),('all',533,'TE',69),('all',533,'OL',73),('all',533,'DL',74),('all',533,'LB',71),('all',533,'CB',61),('all',533,'S',66),
('all',534,'QB',69),('all',534,'RB',71),('all',534,'WR',67),('all',534,'TE',78),('all',534,'OL',83),('all',534,'DL',85),('all',534,'LB',81),('all',534,'CB',67),('all',534,'S',74),
('all',535,'QB',58),('all',535,'RB',62),('all',535,'WR',64),('all',535,'TE',58),('all',535,'OL',56),('all',535,'DL',57),('all',535,'LB',56),('all',535,'CB',62),('all',535,'S',57),
('all',536,'QB',66),('all',536,'RB',68),('all',536,'WR',69),('all',536,'TE',66),('all',536,'OL',65),('all',536,'DL',65),('all',536,'LB',65),('all',536,'CB',68),('all',536,'S',65),
('all',537,'QB',77),('all',537,'RB',76),('all',537,'WR',76),('all',537,'TE',78),('all',537,'OL',77),('all',537,'DL',77),('all',537,'LB',77),('all',537,'CB',75),('all',537,'S',76),
('all',538,'QB',66),('all',538,'RB',69),('all',538,'WR',67),('all',538,'TE',74),('all',538,'OL',77),('all',538,'DL',76),('all',538,'LB',75),('all',538,'CB',67),('all',538,'S',72),
('all',539,'QB',66),('all',539,'RB',78),('all',539,'WR',76),('all',539,'TE',78),('all',539,'OL',77),('all',539,'DL',80),('all',539,'LB',80),('all',539,'CB',76),('all',539,'S',77),
('all',540,'QB',58),('all',540,'RB',58),('all',540,'WR',59),('all',540,'TE',57),('all',540,'OL',57),('all',540,'DL',58),('all',540,'LB',59),('all',540,'CB',60),('all',540,'S',59),
('all',541,'QB',65),('all',541,'RB',62),('all',541,'WR',62),('all',541,'TE',63),('all',541,'OL',66),('all',541,'DL',65),('all',541,'LB',66),('all',541,'CB',63),('all',541,'S',66),
('all',542,'QB',75),('all',542,'RB',81),('all',542,'WR',80),('all',542,'TE',78),('all',542,'OL',76),('all',542,'DL',78),('all',542,'LB',79),('all',542,'CB',80),('all',542,'S',79),
('all',543,'QB',53),('all',543,'RB',58),('all',543,'WR',60),('all',543,'TE',56),('all',543,'OL',56),('all',543,'DL',56),('all',543,'LB',56),('all',543,'CB',60),('all',543,'S',57),
('all',544,'QB',62),('all',544,'RB',61),('all',544,'WR',61),('all',544,'TE',66),('all',544,'OL',71),('all',544,'DL',67),('all',544,'LB',66),('all',544,'CB',63),('all',544,'S',66),
('all',545,'QB',71),('all',545,'RB',83),('all',545,'WR',83),('all',545,'TE',83),('all',545,'OL',81),('all',545,'DL',81),('all',545,'LB',80),('all',545,'CB',83),('all',545,'S',81),
('all',546,'QB',57),('all',546,'RB',62),('all',546,'WR',65),('all',546,'TE',54),('all',546,'OL',51),('all',546,'DL',52),('all',546,'LB',54),('all',546,'CB',65),('all',546,'S',59),
('all',547,'QB',76),('all',547,'RB',83),('all',547,'WR',86),('all',547,'TE',76),('all',547,'OL',70),('all',547,'DL',71),('all',547,'LB',75),('all',547,'CB',86),('all',547,'S',80),
('all',548,'QB',61),('all',548,'RB',53),('all',548,'WR',54),('all',548,'TE',54),('all',548,'OL',56),('all',548,'DL',54),('all',548,'LB',53),('all',548,'CB',54),('all',548,'S',53),
('all',549,'QB',80),('all',549,'RB',77),('all',549,'WR',79),('all',549,'TE',73),('all',549,'OL',70),('all',549,'DL',69),('all',549,'LB',72),('all',549,'CB',78),('all',549,'S',75),
('all',550,'QB',71),('all',550,'RB',78),('all',550,'WR',79),('all',550,'TE',74),('all',550,'OL',70),('all',550,'DL',73),('all',550,'LB',72),('all',550,'CB',78),('all',550,'S',73),
('all',551,'QB',55),('all',551,'RB',62),('all',551,'WR',63),('all',551,'TE',60),('all',551,'OL',59),('all',551,'DL',61),('all',551,'LB',59),('all',551,'CB',61),('all',551,'S',58),
('all',552,'QB',61),('all',552,'RB',68),('all',552,'WR',68),('all',552,'TE',66),('all',552,'OL',66),('all',552,'DL',67),('all',552,'LB',66),('all',552,'CB',67),('all',552,'S',65),
('all',553,'QB',74),('all',553,'RB',81),('all',553,'WR',80),('all',553,'TE',81),('all',553,'OL',80),('all',553,'DL',82),('all',553,'LB',82),('all',553,'CB',79),('all',553,'S',80),
('all',554,'QB',53),('all',554,'RB',61),('all',554,'WR',60),('all',554,'TE',63),('all',554,'OL',64),('all',554,'DL',66),('all',554,'LB',63),('all',554,'CB',59),('all',554,'S',59),
('all',555,'QB',65),('all',555,'RB',81),('all',555,'WR',79),('all',555,'TE',80),('all',555,'OL',78),('all',555,'DL',82),('all',555,'LB',81),('all',555,'CB',77),('all',555,'S',77),
('all',556,'QB',77),('all',556,'RB',70),('all',556,'WR',69),('all',556,'TE',71),('all',556,'OL',72),('all',556,'DL',72),('all',556,'LB',72),('all',556,'CB',69),('all',556,'S',70),
('all',557,'QB',56),('all',557,'RB',61),('all',557,'WR',61),('all',557,'TE',61),('all',557,'OL',63),('all',557,'DL',64),('all',557,'LB',62),('all',557,'CB',62),('all',557,'S',61),
('all',558,'QB',72),('all',558,'RB',68),('all',558,'WR',65),('all',558,'TE',77),('all',558,'OL',84),('all',558,'DL',82),('all',558,'LB',79),('all',558,'CB',67),('all',558,'S',75),
('all',559,'QB',60),('all',559,'RB',62),('all',559,'WR',62),('all',559,'TE',63),('all',559,'OL',64),('all',559,'DL',65),('all',559,'LB',64),('all',559,'CB',63),('all',559,'S',64),
('all',560,'QB',72),('all',560,'RB',73),('all',560,'WR',71),('all',560,'TE',76),('all',560,'OL',79),('all',560,'DL',77),('all',560,'LB',78),('all',560,'CB',74),('all',560,'S',79),
('all',561,'QB',80),('all',561,'RB',79),('all',561,'WR',81),('all',561,'TE',75),('all',561,'OL',71),('all',561,'DL',70),('all',561,'LB',73),('all',561,'CB',81),('all',561,'S',77),
('all',562,'QB',61),('all',562,'RB',55),('all',562,'WR',56),('all',562,'TE',55),('all',562,'OL',57),('all',562,'DL',55),('all',562,'LB',56),('all',562,'CB',57),('all',562,'S',58),
('all',563,'QB',79),('all',563,'RB',64),('all',563,'WR',62),('all',563,'TE',73),('all',563,'OL',80),('all',563,'DL',74),('all',563,'LB',74),('all',563,'CB',67),('all',563,'S',74),
('all',564,'QB',60),('all',564,'RB',56),('all',564,'WR',54),('all',564,'TE',62),('all',564,'OL',68),('all',564,'DL',68),('all',564,'LB',64),('all',564,'CB',56),('all',564,'S',60),
('all',565,'QB',74),('all',565,'RB',66),('all',565,'WR',62),('all',565,'TE',75),('all',565,'OL',83),('all',565,'DL',82),('all',565,'LB',79),('all',565,'CB',65),('all',565,'S',73),
('all',566,'QB',66),('all',566,'RB',70),('all',566,'WR',69),('all',566,'TE',67),('all',566,'OL',66),('all',566,'DL',71),('all',566,'LB',69),('all',566,'CB',67),('all',566,'S',66),
('all',567,'QB',83),('all',567,'RB',88),('all',567,'WR',86),('all',567,'TE',84),('all',567,'OL',80),('all',567,'DL',85),('all',567,'LB',85),('all',567,'CB',85),('all',567,'S',83),
('all',568,'QB',60),('all',568,'RB',63),('all',568,'WR',65),('all',568,'TE',63),('all',568,'OL',63),('all',568,'DL',61),('all',568,'LB',61),('all',568,'CB',65),('all',568,'S',62),
('all',569,'QB',72),('all',569,'RB',75),('all',569,'WR',74),('all',569,'TE',77),('all',569,'OL',78),('all',569,'DL',77),('all',569,'LB',77),('all',569,'CB',74),('all',569,'S',76),
('all',570,'QB',64),('all',570,'RB',63),('all',570,'WR',64),('all',570,'TE',61),('all',570,'OL',60),('all',570,'DL',61),('all',570,'LB',60),('all',570,'CB',63),('all',570,'S',60),
('all',571,'QB',82),('all',571,'RB',82),('all',571,'WR',82),('all',571,'TE',79),('all',571,'OL',77),('all',571,'DL',79),('all',571,'LB',79),('all',571,'CB',81),('all',571,'S',78),
('all',572,'QB',57),('all',572,'RB',64),('all',572,'WR',67),('all',572,'TE',59),('all',572,'OL',56),('all',572,'DL',58),('all',572,'LB',58),('all',572,'CB',65),('all',572,'S',59),
('all',573,'QB',72),('all',573,'RB',83),('all',573,'WR',85),('all',573,'TE',75),('all',573,'OL',69),('all',573,'DL',73),('all',573,'LB',76),('all',573,'CB',83),('all',573,'S',78),
('all',574,'QB',61),('all',574,'RB',57),('all',574,'WR',59),('all',574,'TE',56),('all',574,'OL',56),('all',574,'DL',54),('all',574,'LB',55),('all',574,'CB',59),('all',574,'S',57),
('all',575,'QB',70),('all',575,'RB',65),('all',575,'WR',66),('all',575,'TE',65),('all',575,'OL',66),('all',575,'DL',63),('all',575,'LB',64),('all',575,'CB',66),('all',575,'S',66),
('all',576,'QB',81),('all',576,'RB',72),('all',576,'WR',73),('all',576,'TE',75),('all',576,'OL',75),('all',576,'DL',71),('all',576,'LB',73),('all',576,'CB',75),('all',576,'S',77),
('all',577,'QB',67),('all',577,'RB',52),('all',577,'WR',53),('all',577,'TE',50),('all',577,'OL',51),('all',577,'DL',50),('all',577,'LB',51),('all',577,'CB',52),('all',577,'S',51),
('all',578,'QB',75),('all',578,'RB',57),('all',578,'WR',58),('all',578,'TE',58),('all',578,'OL',60),('all',578,'DL',58),('all',578,'LB',58),('all',578,'CB',57),('all',578,'S',58),
('all',579,'QB',82),('all',579,'RB',65),('all',579,'WR',64),('all',579,'TE',69),('all',579,'OL',72),('all',579,'DL',69),('all',579,'LB',70),('all',579,'CB',64),('all',579,'S',69),
('all',580,'QB',58),('all',580,'RB',60),('all',580,'WR',62),('all',580,'TE',58),('all',580,'OL',57),('all',580,'DL',57),('all',580,'LB',57),('all',580,'CB',61),('all',580,'S',58),
('all',581,'QB',75),('all',581,'RB',79),('all',581,'WR',80),('all',581,'TE',75),('all',581,'OL',72),('all',581,'DL',73),('all',581,'LB',74),('all',581,'CB',79),('all',581,'S',75),
('all',582,'QB',62),('all',582,'RB',58),('all',582,'WR',59),('all',582,'TE',57),('all',582,'OL',58),('all',582,'DL',57),('all',582,'LB',57),('all',582,'CB',59),('all',582,'S',58),
('all',583,'QB',71),('all',583,'RB',66),('all',583,'WR',66),('all',583,'TE',67),('all',583,'OL',69),('all',583,'DL',67),('all',583,'LB',67),('all',583,'CB',67),('all',583,'S',67),
('all',584,'QB',84),('all',584,'RB',79),('all',584,'WR',78),('all',584,'TE',79),('all',584,'OL',79),('all',584,'DL',79),('all',584,'LB',80),('all',584,'CB',79),('all',584,'S',80),
('all',585,'QB',59),('all',585,'RB',66),('all',585,'WR',68),('all',585,'TE',64),('all',585,'OL',62),('all',585,'DL',62),('all',585,'LB',62),('all',585,'CB',67),('all',585,'S',62),
('all',586,'QB',71),('all',586,'RB',79),('all',586,'WR',79),('all',586,'TE',79),('all',586,'OL',77),('all',586,'DL',78),('all',586,'LB',78),('all',586,'CB',78),('all',586,'S',77),
('all',587,'QB',72),('all',587,'RB',78),('all',587,'WR',80),('all',587,'TE',70),('all',587,'OL',64),('all',587,'DL',68),('all',587,'LB',71),('all',587,'CB',79),('all',587,'S',74),
('all',588,'QB',58),('all',588,'RB',63),('all',588,'WR',63),('all',588,'TE',60),('all',588,'OL',59),('all',588,'DL',62),('all',588,'LB',61),('all',588,'CB',62),('all',588,'S',60),
('all',589,'QB',73),('all',589,'RB',66),('all',589,'WR',61),('all',589,'TE',74),('all',589,'OL',81),('all',589,'DL',83),('all',589,'LB',81),('all',589,'CB',63),('all',589,'S',75),
('all',590,'QB',59),('all',590,'RB',52),('all',590,'WR',52),('all',590,'TE',51),('all',590,'OL',52),('all',590,'DL',54),('all',590,'LB',54),('all',590,'CB',51),('all',590,'S',53),
('all',591,'QB',75),('all',591,'RB',65),('all',591,'WR',64),('all',591,'TE',68),('all',591,'OL',70),('all',591,'DL',70),('all',591,'LB',70),('all',591,'CB',62),('all',591,'S',68),
('all',592,'QB',66),('all',592,'RB',59),('all',592,'WR',60),('all',592,'TE',62),('all',592,'OL',63),('all',592,'DL',59),('all',592,'LB',59),('all',592,'CB',60),('all',592,'S',60),
('all',593,'QB',78),('all',593,'RB',71),('all',593,'WR',71),('all',593,'TE',75),('all',593,'OL',76),('all',593,'DL',71),('all',593,'LB',72),('all',593,'CB',71),('all',593,'S',73),
('all',594,'QB',64),('all',594,'RB',71),('all',594,'WR',72),('all',594,'TE',74),('all',594,'OL',72),('all',594,'DL',72),('all',594,'LB',71),('all',594,'CB',69),('all',594,'S',70),
('all',595,'QB',61),('all',595,'RB',63),('all',595,'WR',66),('all',595,'TE',55),('all',595,'OL',51),('all',595,'DL',54),('all',595,'LB',57),('all',595,'CB',65),('all',595,'S',60),
('all',596,'QB',77),('all',596,'RB',81),('all',596,'WR',83),('all',596,'TE',74),('all',596,'OL',69),('all',596,'DL',71),('all',596,'LB',73),('all',596,'CB',81),('all',596,'S',76),
('all',597,'QB',57),('all',597,'RB',51),('all',597,'WR',50),('all',597,'TE',58),('all',597,'OL',65),('all',597,'DL',61),('all',597,'LB',59),('all',597,'CB',52),('all',597,'S',58),
('all',598,'QB',73),('all',598,'RB',64),('all',598,'WR',61),('all',598,'TE',75),('all',598,'OL',82),('all',598,'DL',79),('all',598,'LB',78),('all',598,'CB',64),('all',598,'S',75),
('all',599,'QB',59),('all',599,'RB',55),('all',599,'WR',54),('all',599,'TE',58),('all',599,'OL',62),('all',599,'DL',61),('all',599,'LB',59),('all',599,'CB',55),('all',599,'S',58),
('all',600,'QB',71),('all',600,'RB',67),('all',600,'WR',65),('all',600,'TE',71),('all',600,'OL',74),('all',600,'DL',73),('all',600,'LB',72),('all',600,'CB',67),('all',600,'S',71),
('all',601,'QB',76),('all',601,'RB',80),('all',601,'WR',79),('all',601,'TE',81),('all',601,'OL',81),('all',601,'DL',82),('all',601,'LB',82),('all',601,'CB',81),('all',601,'S',82),
('all',602,'QB',57),('all',602,'RB',61),('all',602,'WR',63),('all',602,'TE',52),('all',602,'OL',49),('all',602,'DL',53),('all',602,'LB',55),('all',602,'CB',62),('all',602,'S',56),
('all',603,'QB',69),('all',603,'RB',63),('all',603,'WR',62),('all',603,'TE',67),('all',603,'OL',70),('all',603,'DL',69),('all',603,'LB',68),('all',603,'CB',62),('all',603,'S',65),
('all',604,'QB',80),('all',604,'RB',72),('all',604,'WR',69),('all',604,'TE',77),('all',604,'OL',80),('all',604,'DL',80),('all',604,'LB',78),('all',604,'CB',69),('all',604,'S',74),
('all',605,'QB',66),('all',605,'RB',56),('all',605,'WR',56),('all',605,'TE',58),('all',605,'OL',60),('all',605,'DL',60),('all',605,'LB',58),('all',605,'CB',56),('all',605,'S',57),
('all',606,'QB',84),('all',606,'RB',67),('all',606,'WR',66),('all',606,'TE',71),('all',606,'OL',74),('all',606,'DL',71),('all',606,'LB',72),('all',606,'CB',66),('all',606,'S',71),
('all',607,'QB',60),('all',607,'RB',51),('all',607,'WR',52),('all',607,'TE',51),('all',607,'OL',54),('all',607,'DL',52),('all',607,'LB',52),('all',607,'CB',52),('all',607,'S',52),
('all',608,'QB',71),('all',608,'RB',63),('all',608,'WR',64),('all',608,'TE',62),('all',608,'OL',62),('all',608,'DL',60),('all',608,'LB',61),('all',608,'CB',64),('all',608,'S',63),
('all',609,'QB',89),('all',609,'RB',76),('all',609,'WR',77),('all',609,'TE',75),('all',609,'OL',74),('all',609,'DL',72),('all',609,'LB',74),('all',609,'CB',78),('all',609,'S',78),
('all',610,'QB',55),('all',610,'RB',62),('all',610,'WR',61),('all',610,'TE',62),('all',610,'OL',64),('all',610,'DL',66),('all',610,'LB',63),('all',610,'CB',61),('all',610,'S',61),
('all',611,'QB',62),('all',611,'RB',70),('all',611,'WR',68),('all',611,'TE',71),('all',611,'OL',72),('all',611,'DL',76),('all',611,'LB',73),('all',611,'CB',68),('all',611,'S',69),
('all',612,'QB',73),('all',612,'RB',84),('all',612,'WR',81),('all',612,'TE',85),('all',612,'OL',84),('all',612,'DL',89),('all',612,'LB',87),('all',612,'CB',82),('all',612,'S',83),
('all',613,'QB',59),('all',613,'RB',57),('all',613,'WR',57),('all',613,'TE',57),('all',613,'OL',59),('all',613,'DL',60),('all',613,'LB',58),('all',613,'CB',56),('all',613,'S',56),
('all',614,'QB',74),('all',614,'RB',72),('all',614,'WR',68),('all',614,'TE',79),('all',614,'OL',84),('all',614,'DL',84),('all',614,'LB',81),('all',614,'CB',68),('all',614,'S',75),
('all',615,'QB',85),('all',615,'RB',83),('all',615,'WR',86),('all',615,'TE',80),('all',615,'OL',75),('all',615,'DL',71),('all',615,'LB',75),('all',615,'CB',86),('all',615,'S',82),
('all',616,'QB',58),('all',616,'RB',54),('all',616,'WR',54),('all',616,'TE',57),('all',616,'OL',60),('all',616,'DL',58),('all',616,'LB',58),('all',616,'CB',56),('all',616,'S',58),
('all',617,'QB',80),('all',617,'RB',90),('all',617,'WR',93),('all',617,'TE',79),('all',617,'OL',69),('all',617,'DL',71),('all',617,'LB',74),('all',617,'CB',91),('all',617,'S',80),
('all',618,'QB',76),('all',618,'RB',65),('all',618,'WR',65),('all',618,'TE',69),('all',618,'OL',70),('all',618,'DL',69),('all',618,'LB',70),('all',618,'CB',65),('all',618,'S',70),
('all',619,'QB',61),('all',619,'RB',65),('all',619,'WR',65),('all',619,'TE',65),('all',619,'OL',65),('all',619,'DL',66),('all',619,'LB',64),('all',619,'CB',65),('all',619,'S',63),
('all',620,'QB',78),('all',620,'RB',84),('all',620,'WR',82),('all',620,'TE',80),('all',620,'OL',77),('all',620,'DL',81),('all',620,'LB',81),('all',620,'CB',82),('all',620,'S',79),
('all',621,'QB',72),('all',621,'RB',71),('all',621,'WR',67),('all',621,'TE',77),('all',621,'OL',82),('all',621,'DL',82),('all',621,'LB',80),('all',621,'CB',68),('all',621,'S',75),
('all',622,'QB',56),('all',622,'RB',56),('all',622,'WR',55),('all',622,'TE',62),('all',622,'OL',66),('all',622,'DL',65),('all',622,'LB',61),('all',622,'CB',55),('all',622,'S',57),
('all',623,'QB',70),('all',623,'RB',72),('all',623,'WR',68),('all',623,'TE',79),('all',623,'OL',83),('all',623,'DL',83),('all',623,'LB',80),('all',623,'CB',68),('all',623,'S',74),
('all',624,'QB',58),('all',624,'RB',64),('all',624,'WR',63),('all',624,'TE',63),('all',624,'OL',64),('all',624,'DL',66),('all',624,'LB',64),('all',624,'CB',64),('all',624,'S',62),
('all',625,'QB',70),('all',625,'RB',75),('all',625,'WR',72),('all',625,'TE',78),('all',625,'OL',81),('all',625,'DL',83),('all',625,'LB',80),('all',625,'CB',73),('all',625,'S',77),
('all',626,'QB',69),('all',626,'RB',72),('all',626,'WR',70),('all',626,'TE',78),('all',626,'OL',81),('all',626,'DL',80),('all',626,'LB',79),('all',626,'CB',70),('all',626,'S',76),
('all',627,'QB',59),('all',627,'RB',64),('all',627,'WR',65),('all',627,'TE',63),('all',627,'OL',62),('all',627,'DL',65),('all',627,'LB',64),('all',627,'CB',64),('all',627,'S',62),
('all',628,'QB',72),('all',628,'RB',79),('all',628,'WR',77),('all',628,'TE',79),('all',628,'OL',79),('all',628,'DL',81),('all',628,'LB',80),('all',628,'CB',76),('all',628,'S',78),
('all',629,'QB',62),('all',629,'RB',64),('all',629,'WR',66),('all',629,'TE',64),('all',629,'OL',63),('all',629,'DL',63),('all',629,'LB',63),('all',629,'CB',66),('all',629,'S',64),
('all',630,'QB',73),('all',630,'RB',77),('all',630,'WR',78),('all',630,'TE',78),('all',630,'OL',77),('all',630,'DL',74),('all',630,'LB',76),('all',630,'CB',79),('all',630,'S',79),
('all',631,'QB',78),('all',631,'RB',73),('all',631,'WR',71),('all',631,'TE',74),('all',631,'OL',76),('all',631,'DL',76),('all',631,'LB',75),('all',631,'CB',70),('all',631,'S',72),
('all',632,'QB',68),('all',632,'RB',82),('all',632,'WR',82),('all',632,'TE',79),('all',632,'OL',76),('all',632,'DL',81),('all',632,'LB',81),('all',632,'CB',83),('all',632,'S',81),
('all',633,'QB',58),('all',633,'RB',57),('all',633,'WR',57),('all',633,'TE',59),('all',633,'OL',61),('all',633,'DL',61),('all',633,'LB',59),('all',633,'CB',56),('all',633,'S',57),
('all',634,'QB',68),('all',634,'RB',67),('all',634,'WR',67),('all',634,'TE',70),('all',634,'OL',72),('all',634,'DL',71),('all',634,'LB',70),('all',634,'CB',66),('all',634,'S',68),
('all',635,'QB',89),('all',635,'RB',86),('all',635,'WR',85),('all',635,'TE',86),('all',635,'OL',85),('all',635,'DL',85),('all',635,'LB',85),('all',635,'CB',85),('all',635,'S',85),
('all',636,'QB',62),('all',636,'RB',65),('all',636,'WR',64),('all',636,'TE',66),('all',636,'OL',67),('all',636,'DL',68),('all',636,'LB',65),('all',636,'CB',64),('all',636,'S',63),
('all',637,'QB',90),('all',637,'RB',83),('all',637,'WR',85),('all',637,'TE',80),('all',637,'OL',75),('all',637,'DL',73),('all',637,'LB',76),('all',637,'CB',84),('all',637,'S',81),
('all',638,'QB',81),('all',638,'RB',86),('all',638,'WR',86),('all',638,'TE',88),('all',638,'OL',87),('all',638,'DL',86),('all',638,'LB',85),('all',638,'CB',87),('all',638,'S',87),
('all',639,'QB',80),('all',639,'RB',88),('all',639,'WR',87),('all',639,'TE',89),('all',639,'OL',87),('all',639,'DL',89),('all',639,'LB',89),('all',639,'CB',87),('all',639,'S',87),
('all',640,'QB',86),('all',640,'RB',88),('all',640,'WR',89),('all',640,'TE',87),('all',640,'OL',83),('all',640,'DL',81),('all',640,'LB',84),('all',640,'CB',89),('all',640,'S',88),
('all',641,'QB',88),('all',641,'RB',88),('all',641,'WR',87),('all',641,'TE',84),('all',641,'OL',81),('all',641,'DL',83),('all',641,'LB',84),('all',641,'CB',87),('all',641,'S',85),
('all',642,'QB',88),('all',642,'RB',88),('all',642,'WR',87),('all',642,'TE',84),('all',642,'OL',81),('all',642,'DL',83),('all',642,'LB',84),('all',642,'CB',87),('all',642,'S',85),
('all',643,'QB',98),('all',643,'RB',89),('all',643,'WR',87),('all',643,'TE',92),('all',643,'OL',92),('all',643,'DL',91),('all',643,'LB',92),('all',643,'CB',88),('all',643,'S',91),
('all',644,'QB',92),('all',644,'RB',89),('all',644,'WR',86),('all',644,'TE',94),('all',644,'OL',96),('all',644,'DL',98),('all',644,'LB',96),('all',644,'CB',87),('all',644,'S',92),
('all',645,'QB',86),('all',645,'RB',87),('all',645,'WR',86),('all',645,'TE',86),('all',645,'OL',84),('all',645,'DL',87),('all',645,'LB',87),('all',645,'CB',86),('all',645,'S',86),
('all',646,'QB',92),('all',646,'RB',89),('all',646,'WR',87),('all',646,'TE',92),('all',646,'OL',91),('all',646,'DL',91),('all',646,'LB',91),('all',646,'CB',86),('all',646,'S',89),
('all',647,'QB',90),('all',647,'RB',86),('all',647,'WR',88),('all',647,'TE',83),('all',647,'OL',79),('all',647,'DL',78),('all',647,'LB',81),('all',647,'CB',87),('all',647,'S',85),
('all',648,'QB',93),('all',648,'RB',85),('all',648,'WR',87),('all',648,'TE',80),('all',648,'OL',75),('all',648,'DL',75),('all',648,'LB',81),('all',648,'CB',86),('all',648,'S',86),
('all',649,'QB',89),('all',649,'RB',87),('all',649,'WR',85),('all',649,'TE',86),('all',649,'OL',85),('all',649,'DL',87),('all',649,'LB',88),('all',649,'CB',86),('all',649,'S',87),
('all',650,'QB',58),('all',650,'RB',57),('all',650,'WR',57),('all',650,'TE',58),('all',650,'OL',60),('all',650,'DL',61),('all',650,'LB',59),('all',650,'CB',57),('all',650,'S',58),
('all',651,'QB',65),('all',651,'RB',66),('all',651,'WR',66),('all',651,'TE',69),('all',651,'OL',71),('all',651,'DL',71),('all',651,'LB',70),('all',651,'CB',67),('all',651,'S',68),
('all',652,'QB',75),('all',652,'RB',75),('all',652,'WR',73),('all',652,'TE',80),('all',652,'OL',84),('all',652,'DL',84),('all',652,'LB',82),('all',652,'CB',74),('all',652,'S',79),
('all',653,'QB',62),('all',653,'RB',61),('all',653,'WR',63),('all',653,'TE',58),('all',653,'OL',57),('all',653,'DL',57),('all',653,'LB',57),('all',653,'CB',63),('all',653,'S',59),
('all',654,'QB',73),('all',654,'RB',70),('all',654,'WR',71),('all',654,'TE',67),('all',654,'OL',66),('all',654,'DL',65),('all',654,'LB',66),('all',654,'CB',71),('all',654,'S',68),
('all',655,'QB',86),('all',655,'RB',83),('all',655,'WR',85),('all',655,'TE',79),('all',655,'OL',75),('all',655,'DL',74),('all',655,'LB',77),('all',655,'CB',85),('all',655,'S',81),
('all',656,'QB',61),('all',656,'RB',64),('all',656,'WR',66),('all',656,'TE',59),('all',656,'OL',57),('all',656,'DL',59),('all',656,'LB',59),('all',656,'CB',65),('all',656,'S',60),
('all',657,'QB',71),('all',657,'RB',74),('all',657,'WR',77),('all',657,'TE',68),('all',657,'OL',64),('all',657,'DL',65),('all',657,'LB',67),('all',657,'CB',76),('all',657,'S',70),
('all',658,'QB',81),('all',658,'RB',87),('all',658,'WR',88),('all',658,'TE',82),('all',658,'OL',76),('all',658,'DL',78),('all',658,'LB',80),('all',658,'CB',87),('all',658,'S',82),
('all',659,'QB',52),('all',659,'RB',57),('all',659,'WR',59),('all',659,'TE',53),('all',659,'OL',52),('all',659,'DL',52),('all',659,'LB',52),('all',659,'CB',58),('all',659,'S',53),
('all',660,'QB',68),('all',660,'RB',72),('all',660,'WR',73),('all',660,'TE',72),('all',660,'OL',71),('all',660,'DL',68),('all',660,'LB',70),('all',660,'CB',73),('all',660,'S',72),
('all',661,'QB',55),('all',661,'RB',61),('all',661,'WR',63),('all',661,'TE',55),('all',661,'OL',53),('all',661,'DL',55),('all',661,'LB',56),('all',661,'CB',62),('all',661,'S',57),
('all',662,'QB',65),('all',662,'RB',71),('all',662,'WR',72),('all',662,'TE',68),('all',662,'OL',66),('all',662,'DL',67),('all',662,'LB',67),('all',662,'CB',71),('all',662,'S',68),
('all',663,'QB',75),('all',663,'RB',87),('all',663,'WR',89),('all',663,'TE',80),('all',663,'OL',73),('all',663,'DL',75),('all',663,'LB',77),('all',663,'CB',88),('all',663,'S',81),
('all',664,'QB',49),('all',664,'RB',50),('all',664,'WR',52),('all',664,'TE',48),('all',664,'OL',49),('all',664,'DL',50),('all',664,'LB',49),('all',664,'CB',51),('all',664,'S',49),
('all',665,'QB',50),('all',665,'RB',49),('all',665,'WR',50),('all',665,'TE',50),('all',665,'OL',53),('all',665,'DL',51),('all',665,'LB',50),('all',665,'CB',50),('all',665,'S',50),
('all',666,'QB',72),('all',666,'RB',72),('all',666,'WR',75),('all',666,'TE',68),('all',666,'OL',65),('all',666,'DL',64),('all',666,'LB',66),('all',666,'CB',73),('all',666,'S',68),
('all',667,'QB',66),('all',667,'RB',66),('all',667,'WR',69),('all',667,'TE',64),('all',667,'OL',62),('all',667,'DL',62),('all',667,'LB',62),('all',667,'CB',68),('all',667,'S',64),
('all',668,'QB',81),('all',668,'RB',81),('all',668,'WR',83),('all',668,'TE',79),('all',668,'OL',75),('all',668,'DL',74),('all',668,'LB',75),('all',668,'CB',82),('all',668,'S',78),
('all',669,'QB',63),('all',669,'RB',59),('all',669,'WR',62),('all',669,'TE',50),('all',669,'OL',46),('all',669,'DL',49),('all',669,'LB',54),('all',669,'CB',61),('all',669,'S',58),
('all',670,'QB',71),('all',670,'RB',64),('all',670,'WR',67),('all',670,'TE',58),('all',670,'OL',55),('all',670,'DL',56),('all',670,'LB',61),('all',670,'CB',66),('all',670,'S',65),
('all',671,'QB',90),('all',671,'RB',80),('all',671,'WR',81),('all',671,'TE',77),('all',671,'OL',73),('all',671,'DL',71),('all',671,'LB',77),('all',671,'CB',82),('all',671,'S',83),
('all',672,'QB',63),('all',672,'RB',61),('all',672,'WR',62),('all',672,'TE',63),('all',672,'OL',64),('all',672,'DL',63),('all',672,'LB',61),('all',672,'CB',61),('all',672,'S',60),
('all',673,'QB',80),('all',673,'RB',76),('all',673,'WR',75),('all',673,'TE',79),('all',673,'OL',78),('all',673,'DL',78),('all',673,'LB',77),('all',673,'CB',73),('all',673,'S',75),
('all',674,'QB',59),('all',674,'RB',60),('all',674,'WR',60),('all',674,'TE',61),('all',674,'OL',63),('all',674,'DL',65),('all',674,'LB',63),('all',674,'CB',60),('all',674,'S',60),
('all',675,'QB',73),('all',675,'RB',73),('all',675,'WR',70),('all',675,'TE',78),('all',675,'OL',81),('all',675,'DL',82),('all',675,'LB',79),('all',675,'CB',69),('all',675,'S',74),
('all',676,'QB',74),('all',676,'RB',81),('all',676,'WR',82),('all',676,'TE',76),('all',676,'OL',72),('all',676,'DL',72),('all',676,'LB',75),('all',676,'CB',81),('all',676,'S',78),
('all',677,'QB',64),('all',677,'RB',66),('all',677,'WR',68),('all',677,'TE',61),('all',677,'OL',58),('all',677,'DL',59),('all',677,'LB',60),('all',677,'CB',67),('all',677,'S',63),
('all',678,'QB',76),('all',678,'RB',80),('all',678,'WR',83),('all',678,'TE',73),('all',678,'OL',67),('all',678,'DL',67),('all',678,'LB',71),('all',678,'CB',82),('all',678,'S',77),
('all',679,'QB',55),('all',679,'RB',56),('all',679,'WR',55),('all',679,'TE',58),('all',679,'OL',63),('all',679,'DL',65),('all',679,'LB',62),('all',679,'CB',57),('all',679,'S',59),
('all',680,'QB',63),('all',680,'RB',65),('all',680,'WR',62),('all',680,'TE',69),('all',680,'OL',75),('all',680,'DL',79),('all',680,'LB',76),('all',680,'CB',65),('all',680,'S',71),
('all',681,'QB',76),('all',681,'RB',72),('all',681,'WR',73),('all',681,'TE',78),('all',681,'OL',80),('all',681,'DL',75),('all',681,'LB',77),('all',681,'CB',77),('all',681,'S',82),
('all',682,'QB',63),('all',682,'RB',56),('all',682,'WR',57),('all',682,'TE',54),('all',682,'OL',54),('all',682,'DL',56),('all',682,'LB',57),('all',682,'CB',57),('all',682,'S',57),
('all',683,'QB',77),('all',683,'RB',64),('all',683,'WR',63),('all',683,'TE',67),('all',683,'OL',70),('all',683,'DL',68),('all',683,'LB',69),('all',683,'CB',62),('all',683,'S',68),
('all',684,'QB',63),('all',684,'RB',61),('all',684,'WR',63),('all',684,'TE',59),('all',684,'OL',59),('all',684,'DL',59),('all',684,'LB',60),('all',684,'CB',62),('all',684,'S',61),
('all',685,'QB',76),('all',685,'RB',74),('all',685,'WR',74),('all',685,'TE',72),('all',685,'OL',70),('all',685,'DL',71),('all',685,'LB',73),('all',685,'CB',75),('all',685,'S',75),
('all',686,'QB',56),('all',686,'RB',58),('all',686,'WR',59),('all',686,'TE',56),('all',686,'OL',56),('all',686,'DL',57),('all',686,'LB',57),('all',686,'CB',58),('all',686,'S',57),
('all',687,'QB',72),('all',687,'RB',74),('all',687,'WR',74),('all',687,'TE',76),('all',687,'OL',77),('all',687,'DL',76),('all',687,'LB',76),('all',687,'CB',74),('all',687,'S',75),
('all',688,'QB',57),('all',688,'RB',59),('all',688,'WR',59),('all',688,'TE',61),('all',688,'OL',63),('all',688,'DL',61),('all',688,'LB',60),('all',688,'CB',60),('all',688,'S',59),
('all',689,'QB',72),('all',689,'RB',75),('all',689,'WR',72),('all',689,'TE',79),('all',689,'OL',82),('all',689,'DL',82),('all',689,'LB',81),('all',689,'CB',74),('all',689,'S',79),
('all',690,'QB',61),('all',690,'RB',56),('all',690,'WR',56),('all',690,'TE',57),('all',690,'OL',60),('all',690,'DL',60),('all',690,'LB',59),('all',690,'CB',56),('all',690,'S',57),
('all',691,'QB',82),('all',691,'RB',69),('all',691,'WR',68),('all',691,'TE',75),('all',691,'OL',78),('all',691,'DL',74),('all',691,'LB',75),('all',691,'CB',70),('all',691,'S',76),
('all',692,'QB',62),('all',692,'RB',59),('all',692,'WR',60),('all',692,'TE',59),('all',692,'OL',61),('all',692,'DL',60),('all',692,'LB',59),('all',692,'CB',60),('all',692,'S',60),
('all',693,'QB',83),('all',693,'RB',72),('all',693,'WR',71),('all',693,'TE',74),('all',693,'OL',76),('all',693,'DL',73),('all',693,'LB',74),('all',693,'CB',72),('all',693,'S',75),
('all',694,'QB',60),('all',694,'RB',62),('all',694,'WR',65),('all',694,'TE',57),('all',694,'OL',55),('all',694,'DL',55),('all',694,'LB',55),('all',694,'CB',63),('all',694,'S',57),
('all',695,'QB',83),('all',695,'RB',81),('all',695,'WR',84),('all',695,'TE',75),('all',695,'OL',69),('all',695,'DL',68),('all',695,'LB',72),('all',695,'CB',83),('all',695,'S',78),
('all',696,'QB',60),('all',696,'RB',62),('all',696,'WR',61),('all',696,'TE',65),('all',696,'OL',68),('all',696,'DL',70),('all',696,'LB',66),('all',696,'CB',62),('all',696,'S',63),
('all',697,'QB',73),('all',697,'RB',75),('all',697,'WR',72),('all',697,'TE',82),('all',697,'OL',86),('all',697,'DL',86),('all',697,'LB',83),('all',697,'CB',74),('all',697,'S',78),
('all',698,'QB',65),('all',698,'RB',61),('all',698,'WR',62),('all',698,'TE',64),('all',698,'OL',65),('all',698,'DL',63),('all',698,'LB',61),('all',698,'CB',61),('all',698,'S',61),
('all',699,'QB',81),('all',699,'RB',72),('all',699,'WR',72),('all',699,'TE',78),('all',699,'OL',80),('all',699,'DL',76),('all',699,'LB',75),('all',699,'CB',71),('all',699,'S',74),
('all',700,'QB',87),('all',700,'RB',74),('all',700,'WR',75),('all',700,'TE',75),('all',700,'OL',74),('all',700,'DL',71),('all',700,'LB',75),('all',700,'CB',75),('all',700,'S',78),
('all',701,'QB',75),('all',701,'RB',85),('all',701,'WR',86),('all',701,'TE',79),('all',701,'OL',74),('all',701,'DL',76),('all',701,'LB',78),('all',701,'CB',86),('all',701,'S',80),
('all',702,'QB',73),('all',702,'RB',78),('all',702,'WR',80),('all',702,'TE',67),('all',702,'OL',61),('all',702,'DL',63),('all',702,'LB',68),('all',702,'CB',79),('all',702,'S',73),
('all',703,'QB',77),('all',703,'RB',71),('all',703,'WR',72),('all',703,'TE',73),('all',703,'OL',75),('all',703,'DL',72),('all',703,'LB',77),('all',703,'CB',76),('all',703,'S',82),
('all',704,'QB',62),('all',704,'RB',58),('all',704,'WR',59),('all',704,'TE',55),('all',704,'OL',55),('all',704,'DL',55),('all',704,'LB',56),('all',704,'CB',59),('all',704,'S',58),
('all',705,'QB',76),('all',705,'RB',71),('all',705,'WR',71),('all',705,'TE',70),('all',705,'OL',69),('all',705,'DL',68),('all',705,'LB',70),('all',705,'CB',71),('all',705,'S',72),
('all',706,'QB',91),('all',706,'RB',83),('all',706,'WR',83),('all',706,'TE',86),('all',706,'OL',84),('all',706,'DL',82),('all',706,'LB',84),('all',706,'CB',83),('all',706,'S',87),
('all',707,'QB',76),('all',707,'RB',75),('all',707,'WR',75),('all',707,'TE',70),('all',707,'OL',68),('all',707,'DL',70),('all',707,'LB',74),('all',707,'CB',76),('all',707,'S',76),
('all',708,'QB',60),('all',708,'RB',58),('all',708,'WR',57),('all',708,'TE',57),('all',708,'OL',59),('all',708,'DL',60),('all',708,'LB',59),('all',708,'CB',57),('all',708,'S',58),
('all',709,'QB',72),('all',709,'RB',72),('all',709,'WR',69),('all',709,'TE',75),('all',709,'OL',78),('all',709,'DL',78),('all',709,'LB',77),('all',709,'CB',69),('all',709,'S',74),
('all',710,'QB',59),('all',710,'RB',62),('all',710,'WR',62),('all',710,'TE',60),('all',710,'OL',61),('all',710,'DL',63),('all',710,'LB',62),('all',710,'CB',63),('all',710,'S',62),
('all',711,'QB',72),('all',711,'RB',78),('all',711,'WR',77),('all',711,'TE',77),('all',711,'OL',77),('all',711,'DL',78),('all',711,'LB',79),('all',711,'CB',79),('all',711,'S',80),
('all',712,'QB',54),('all',712,'RB',54),('all',712,'WR',52),('all',712,'TE',62),('all',712,'OL',68),('all',712,'DL',66),('all',712,'LB',61),('all',712,'CB',53),('all',712,'S',57),
('all',713,'QB',65),('all',713,'RB',65),('all',713,'WR',60),('all',713,'TE',79),('all',713,'OL',90),('all',713,'DL',89),('all',713,'LB',83),('all',713,'CB',64),('all',713,'S',75),
('all',714,'QB',55),('all',714,'RB',56),('all',714,'WR',59),('all',714,'TE',54),('all',714,'OL',53),('all',714,'DL',52),('all',714,'LB',51),('all',714,'CB',58),('all',714,'S',53),
('all',715,'QB',82),('all',715,'RB',87),('all',715,'WR',89),('all',715,'TE',83),('all',715,'OL',77),('all',715,'DL',77),('all',715,'LB',79),('all',715,'CB',89),('all',715,'S',83),
('all',716,'QB',94),('all',716,'RB',91),('all',716,'WR',89),('all',716,'TE',93),('all',716,'OL',91),('all',716,'DL',92),('all',716,'LB',92),('all',716,'CB',88),('all',716,'S',91),
('all',717,'QB',94),('all',717,'RB',91),('all',717,'WR',89),('all',717,'TE',94),('all',717,'OL',92),('all',717,'DL',92),('all',717,'LB',92),('all',717,'CB',88),('all',717,'S',91),
('all',718,'QB',82),('all',718,'RB',85),('all',718,'WR',85),('all',718,'TE',90),('all',718,'OL',90),('all',718,'DL',88),('all',718,'LB',87),('all',718,'CB',86),('all',718,'S',88),
('all',719,'QB',89),('all',719,'RB',77),('all',719,'WR',75),('all',719,'TE',80),('all',719,'OL',84),('all',719,'DL',83),('all',719,'LB',87),('all',719,'CB',80),('all',719,'S',88),
('all',720,'QB',95),('all',720,'RB',82),('all',720,'WR',80),('all',720,'TE',79),('all',720,'OL',76),('all',720,'DL',78),('all',720,'LB',83),('all',720,'CB',80),('all',720,'S',84),
('all',721,'QB',89),('all',721,'RB',80),('all',721,'WR',77),('all',721,'TE',85),('all',721,'OL',88),('all',721,'DL',87),('all',721,'LB',86),('all',721,'CB',79),('all',721,'S',84),
('all',722,'QB',59),('all',722,'RB',59),('all',722,'WR',60),('all',722,'TE',56),('all',722,'OL',56),('all',722,'DL',57),('all',722,'LB',57),('all',722,'CB',59),('all',722,'S',57),
('all',723,'QB',69),('all',723,'RB',66),('all',723,'WR',66),('all',723,'TE',68),('all',723,'OL',69),('all',723,'DL',68),('all',723,'LB',68),('all',723,'CB',66),('all',723,'S',67),
('all',724,'QB',82),('all',724,'RB',77),('all',724,'WR',76),('all',724,'TE',78),('all',724,'OL',78),('all',724,'DL',79),('all',724,'LB',80),('all',724,'CB',76),('all',724,'S',79),
('all',725,'QB',61),('all',725,'RB',64),('all',725,'WR',66),('all',725,'TE',59),('all',725,'OL',57),('all',725,'DL',60),('all',725,'LB',59),('all',725,'CB',65),('all',725,'S',60),
('all',726,'QB',70),('all',726,'RB',74),('all',726,'WR',75),('all',726,'TE',70),('all',726,'OL',68),('all',726,'DL',70),('all',726,'LB',69),('all',726,'CB',73),('all',726,'S',69),
('all',727,'QB',77),('all',727,'RB',75),('all',727,'WR',72),('all',727,'TE',79),('all',727,'OL',82),('all',727,'DL',82),('all',727,'LB',81),('all',727,'CB',73),('all',727,'S',78),
('all',728,'QB',63),('all',728,'RB',58),('all',728,'WR',58),('all',728,'TE',58),('all',728,'OL',59),('all',728,'DL',59),('all',728,'LB',58),('all',728,'CB',58),('all',728,'S',58),
('all',729,'QB',74),('all',729,'RB',65),('all',729,'WR',65),('all',729,'TE',66),('all',729,'OL',68),('all',729,'DL',67),('all',729,'LB',67),('all',729,'CB',66),('all',729,'S',67),
('all',730,'QB',88),('all',730,'RB',74),('all',730,'WR',73),('all',730,'TE',76),('all',730,'OL',77),('all',730,'DL',74),('all',730,'LB',76),('all',730,'CB',74),('all',730,'S',77),
('all',731,'QB',53),('all',731,'RB',62),('all',731,'WR',63),('all',731,'TE',55),('all',731,'OL',52),('all',731,'DL',57),('all',731,'LB',57),('all',731,'CB',61),('all',731,'S',56),
('all',732,'QB',60),('all',732,'RB',68),('all',732,'WR',69),('all',732,'TE',66),('all',732,'OL',64),('all',732,'DL',67),('all',732,'LB',66),('all',732,'CB',68),('all',732,'S',65),
('all',733,'QB',74),('all',733,'RB',73),('all',733,'WR',71),('all',733,'TE',74),('all',733,'OL',76),('all',733,'DL',79),('all',733,'LB',78),('all',733,'CB',70),('all',733,'S',74),
('all',734,'QB',52),('all',734,'RB',56),('all',734,'WR',57),('all',734,'TE',54),('all',734,'OL',55),('all',734,'DL',57),('all',734,'LB',56),('all',734,'CB',55),('all',734,'S',53),
('all',735,'QB',66),('all',735,'RB',66),('all',735,'WR',64),('all',735,'TE',67),('all',735,'OL',70),('all',735,'DL',72),('all',735,'LB',71),('all',735,'CB',63),('all',735,'S',67),
('all',736,'QB',59),('all',736,'RB',59),('all',736,'WR',59),('all',736,'TE',57),('all',736,'OL',57),('all',736,'DL',58),('all',736,'LB',58),('all',736,'CB',58),('all',736,'S',57),
('all',737,'QB',66),('all',737,'RB',62),('all',737,'WR',61),('all',737,'TE',65),('all',737,'OL',69),('all',737,'DL',69),('all',737,'LB',69),('all',737,'CB',62),('all',737,'S',67),
('all',738,'QB',86),('all',738,'RB',67),('all',738,'WR',66),('all',738,'TE',72),('all',738,'OL',76),('all',738,'DL',73),('all',738,'LB',72),('all',738,'CB',67),('all',738,'S',71),
('all',739,'QB',59),('all',739,'RB',64),('all',739,'WR',64),('all',739,'TE',62),('all',739,'OL',62),('all',739,'DL',65),('all',739,'LB',63),('all',739,'CB',64),('all',739,'S',62),
('all',740,'QB',70),('all',740,'RB',69),('all',740,'WR',65),('all',740,'TE',76),('all',740,'OL',81),('all',740,'DL',82),('all',740,'LB',79),('all',740,'CB',64),('all',740,'S',72),
('all',741,'QB',78),('all',741,'RB',78),('all',741,'WR',80),('all',741,'TE',72),('all',741,'OL',67),('all',741,'DL',69),('all',741,'LB',72),('all',741,'CB',79),('all',741,'S',76),
('all',742,'QB',60),('all',742,'RB',67),('all',742,'WR',71),('all',742,'TE',54),('all',742,'OL',47),('all',742,'DL',52),('all',742,'LB',56),('all',742,'CB',69),('all',742,'S',60),
('all',743,'QB',78),('all',743,'RB',84),('all',743,'WR',88),('all',743,'TE',70),('all',743,'OL',59),('all',743,'DL',64),('all',743,'LB',70),('all',743,'CB',87),('all',743,'S',78),
('all',744,'QB',54),('all',744,'RB',61),('all',744,'WR',61),('all',744,'TE',58),('all',744,'OL',58),('all',744,'DL',59),('all',744,'LB',58),('all',744,'CB',60),('all',744,'S',57),
('all',745,'QB',71),('all',745,'RB',84),('all',745,'WR',84),('all',745,'TE',79),('all',745,'OL',74),('all',745,'DL',78),('all',745,'LB',79),('all',745,'CB',83),('all',745,'S',79),
('all',746,'QB',49),('all',746,'RB',51),('all',746,'WR',54),('all',746,'TE',43),('all',746,'OL',42),('all',746,'DL',42),('all',746,'LB',46),('all',746,'CB',52),('all',746,'S',48),
('all',747,'QB',58),('all',747,'RB',58),('all',747,'WR',59),('all',747,'TE',58),('all',747,'OL',59),('all',747,'DL',59),('all',747,'LB',58),('all',747,'CB',59),('all',747,'S',58),
('all',748,'QB',76),('all',748,'RB',68),('all',748,'WR',67),('all',748,'TE',74),('all',748,'OL',79),('all',748,'DL',75),('all',748,'LB',77),('all',748,'CB',72),('all',748,'S',80),
('all',749,'QB',61),('all',749,'RB',63),('all',749,'WR',61),('all',749,'TE',69),('all',749,'OL',72),('all',749,'DL',73),('all',749,'LB',69),('all',749,'CB',61),('all',749,'S',64),
('all',750,'QB',71),('all',750,'RB',68),('all',750,'WR',63),('all',750,'TE',80),('all',750,'OL',87),('all',750,'DL',86),('all',750,'LB',81),('all',750,'CB',64),('all',750,'S',74),
('all',751,'QB',58),('all',751,'RB',53),('all',751,'WR',54),('all',751,'TE',53),('all',751,'OL',55),('all',751,'DL',54),('all',751,'LB',54),('all',751,'CB',54),('all',751,'S',55),
('all',752,'QB',74),('all',752,'RB',67),('all',752,'WR',66),('all',752,'TE',73),('all',752,'OL',77),('all',752,'DL',72),('all',752,'LB',74),('all',752,'CB',68),('all',752,'S',75),
('all',753,'QB',56),('all',753,'RB',54),('all',753,'WR',54),('all',753,'TE',51),('all',753,'OL',52),('all',753,'DL',53),('all',753,'LB',53),('all',753,'CB',53),('all',753,'S',52),
('all',754,'QB',75),('all',754,'RB',70),('all',754,'WR',67),('all',754,'TE',72),('all',754,'OL',76),('all',754,'DL',76),('all',754,'LB',76),('all',754,'CB',68),('all',754,'S',74),
('all',755,'QB',62),('all',755,'RB',51),('all',755,'WR',52),('all',755,'TE',51),('all',755,'OL',53),('all',755,'DL',52),('all',755,'LB',53),('all',755,'CB',52),('all',755,'S',54),
('all',756,'QB',75),('all',756,'RB',61),('all',756,'WR',61),('all',756,'TE',64),('all',756,'OL',67),('all',756,'DL',63),('all',756,'LB',65),('all',756,'CB',62),('all',756,'S',67),
('all',757,'QB',63),('all',757,'RB',65),('all',757,'WR',68),('all',757,'TE',60),('all',757,'OL',57),('all',757,'DL',57),('all',757,'LB',57),('all',757,'CB',66),('all',757,'S',60),
('all',758,'QB',80),('all',758,'RB',82),('all',758,'WR',85),('all',758,'TE',76),('all',758,'OL',70),('all',758,'DL',70),('all',758,'LB',72),('all',758,'CB',84),('all',758,'S',77),
('all',759,'QB',59),('all',759,'RB',61),('all',759,'WR',62),('all',759,'TE',61),('all',759,'OL',61),('all',759,'DL',63),('all',759,'LB',61),('all',759,'CB',61),('all',759,'S',60),
('all',760,'QB',69),('all',760,'RB',73),('all',760,'WR',70),('all',760,'TE',79),('all',760,'OL',81),('all',760,'DL',82),('all',760,'LB',79),('all',760,'CB',69),('all',760,'S',74),
('all',761,'QB',51),('all',761,'RB',51),('all',761,'WR',52),('all',761,'TE',49),('all',761,'OL',50),('all',761,'DL',49),('all',761,'LB',49),('all',761,'CB',51),('all',761,'S',49),
('all',762,'QB',58),('all',762,'RB',61),('all',762,'WR',63),('all',762,'TE',59),('all',762,'OL',58),('all',762,'DL',56),('all',762,'LB',57),('all',762,'CB',62),('all',762,'S',59),
('all',763,'QB',73),('all',763,'RB',78),('all',763,'WR',76),('all',763,'TE',78),('all',763,'OL',79),('all',763,'DL',81),('all',763,'LB',82),('all',763,'CB',77),('all',763,'S',80),
('all',764,'QB',80),('all',764,'RB',82),('all',764,'WR',85),('all',764,'TE',69),('all',764,'OL',61),('all',764,'DL',64),('all',764,'LB',73),('all',764,'CB',86),('all',764,'S',81),
('all',765,'QB',80),('all',765,'RB',71),('all',765,'WR',72),('all',765,'TE',75),('all',765,'OL',76),('all',765,'DL',71),('all',765,'LB',73),('all',765,'CB',72),('all',765,'S',75),
('all',766,'QB',67),('all',766,'RB',77),('all',766,'WR',75),('all',766,'TE',80),('all',766,'OL',80),('all',766,'DL',82),('all',766,'LB',80),('all',766,'CB',75),('all',766,'S',77),
('all',767,'QB',51),('all',767,'RB',61),('all',767,'WR',64),('all',767,'TE',57),('all',767,'OL',55),('all',767,'DL',54),('all',767,'LB',54),('all',767,'CB',63),('all',767,'S',56),
('all',768,'QB',73),('all',768,'RB',71),('all',768,'WR',66),('all',768,'TE',80),('all',768,'OL',88),('all',768,'DL',87),('all',768,'LB',84),('all',768,'CB',69),('all',768,'S',79),
('all',769,'QB',61),('all',769,'RB',51),('all',769,'WR',49),('all',769,'TE',59),('all',769,'OL',66),('all',769,'DL',63),('all',769,'LB',59),('all',769,'CB',50),('all',769,'S',55),
('all',770,'QB',77),('all',770,'RB',65),('all',770,'WR',62),('all',770,'TE',74),('all',770,'OL',80),('all',770,'DL',76),('all',770,'LB',74),('all',770,'CB',64),('all',770,'S',71),
('all',771,'QB',67),('all',771,'RB',58),('all',771,'WR',56),('all',771,'TE',61),('all',771,'OL',67),('all',771,'DL',65),('all',771,'LB',69),('all',771,'CB',60),('all',771,'S',70),
('all',772,'QB',81),('all',772,'RB',74),('all',772,'WR',72),('all',772,'TE',79),('all',772,'OL',82),('all',772,'DL',80),('all',772,'LB',80),('all',772,'CB',73),('all',772,'S',78),
('all',773,'QB',83),('all',773,'RB',84),('all',773,'WR',84),('all',773,'TE',85),('all',773,'OL',83),('all',773,'DL',82),('all',773,'LB',83),('all',773,'CB',84),('all',773,'S',84),
('all',774,'QB',72),('all',774,'RB',69),('all',774,'WR',69),('all',774,'TE',71),('all',774,'OL',72),('all',774,'DL',70),('all',774,'LB',72),('all',774,'CB',71),('all',774,'S',74),
('all',775,'QB',75),('all',775,'RB',75),('all',775,'WR',72),('all',775,'TE',73),('all',775,'OL',73),('all',775,'DL',76),('all',775,'LB',77),('all',775,'CB',73),('all',775,'S',75),
('all',776,'QB',77),('all',776,'RB',65),('all',776,'WR',63),('all',776,'TE',76),('all',776,'OL',84),('all',776,'DL',79),('all',776,'LB',76),('all',776,'CB',66),('all',776,'S',74),
('all',777,'QB',67),('all',777,'RB',79),('all',777,'WR',80),('all',777,'TE',71),('all',777,'OL',66),('all',777,'DL',71),('all',777,'LB',74),('all',777,'CB',79),('all',777,'S',75),
('all',778,'QB',73),('all',778,'RB',82),('all',778,'WR',83),('all',778,'TE',71),('all',778,'OL',65),('all',778,'DL',70),('all',778,'LB',76),('all',778,'CB',84),('all',778,'S',81),
('all',779,'QB',73),('all',779,'RB',79),('all',779,'WR',79),('all',779,'TE',76),('all',779,'OL',73),('all',779,'DL',76),('all',779,'LB',77),('all',779,'CB',78),('all',779,'S',77),
('all',780,'QB',85),('all',780,'RB',65),('all',780,'WR',63),('all',780,'TE',73),('all',780,'OL',79),('all',780,'DL',72),('all',780,'LB',71),('all',780,'CB',65),('all',780,'S',70),
('all',781,'QB',78),('all',781,'RB',70),('all',781,'WR',65),('all',781,'TE',79),('all',781,'OL',86),('all',781,'DL',86),('all',781,'LB',82),('all',781,'CB',67),('all',781,'S',76),
('all',782,'QB',58),('all',782,'RB',58),('all',782,'WR',58),('all',782,'TE',60),('all',782,'OL',63),('all',782,'DL',62),('all',782,'LB',59),('all',782,'CB',58),('all',782,'S',58),
('all',783,'QB',69),('all',783,'RB',68),('all',783,'WR',68),('all',783,'TE',71),('all',783,'OL',72),('all',783,'DL',71),('all',783,'LB',70),('all',783,'CB',69),('all',783,'S',70),
('all',784,'QB',85),('all',784,'RB',83),('all',784,'WR',82),('all',784,'TE',86),('all',784,'OL',87),('all',784,'DL',87),('all',784,'LB',87),('all',784,'CB',84),('all',784,'S',87),
('all',785,'QB',82),('all',785,'RB',92),('all',785,'WR',92),('all',785,'TE',85),('all',785,'OL',80),('all',785,'DL',83),('all',785,'LB',85),('all',785,'CB',92),('all',785,'S',87),
('all',786,'QB',91),('all',786,'RB',84),('all',786,'WR',85),('all',786,'TE',80),('all',786,'OL',77),('all',786,'DL',77),('all',786,'LB',81),('all',786,'CB',85),('all',786,'S',84),
('all',787,'QB',81),('all',787,'RB',81),('all',787,'WR',78),('all',787,'TE',83),('all',787,'OL',86),('all',787,'DL',87),('all',787,'LB',87),('all',787,'CB',80),('all',787,'S',85),
('all',788,'QB',86),('all',788,'RB',82),('all',788,'WR',83),('all',788,'TE',82),('all',788,'OL',80),('all',788,'DL',78),('all',788,'LB',82),('all',788,'CB',85),('all',788,'S',87),
('all',789,'QB',52),('all',789,'RB',53),('all',789,'WR',54),('all',789,'TE',43),('all',789,'OL',42),('all',789,'DL',44),('all',789,'LB',48),('all',789,'CB',53),('all',789,'S',50),
('all',790,'QB',68),('all',790,'RB',61),('all',790,'WR',60),('all',790,'TE',70),('all',790,'OL',76),('all',790,'DL',69),('all',790,'LB',70),('all',790,'CB',65),('all',790,'S',73),
('all',791,'QB',90),('all',791,'RB',90),('all',791,'WR',88),('all',791,'TE',94),('all',791,'OL',93),('all',791,'DL',94),('all',791,'LB',93),('all',791,'CB',88),('all',791,'S',91),
('all',792,'QB',95),('all',792,'RB',90),('all',792,'WR',90),('all',792,'TE',92),('all',792,'OL',89),('all',792,'DL',89),('all',792,'LB',90),('all',792,'CB',88),('all',792,'S',90),
('all',793,'QB',92),('all',793,'RB',85),('all',793,'WR',88),('all',793,'TE',81),('all',793,'OL',74),('all',793,'DL',71),('all',793,'LB',76),('all',793,'CB',87),('all',793,'S',83),
('all',794,'QB',71),('all',794,'RB',80),('all',794,'WR',77),('all',794,'TE',87),('all',794,'OL',91),('all',794,'DL',93),('all',794,'LB',89),('all',794,'CB',78),('all',794,'S',83),
('all',795,'QB',86),('all',795,'RB',95),('all',795,'WR',95),('all',795,'TE',85),('all',795,'OL',76),('all',795,'DL',83),('all',795,'LB',84),('all',795,'CB',92),('all',795,'S',84),
('all',796,'QB',91),('all',796,'RB',80),('all',796,'WR',79),('all',796,'TE',81),('all',796,'OL',81),('all',796,'DL',79),('all',796,'LB',78),('all',796,'CB',78),('all',796,'S',78),
('all',797,'QB',84),('all',797,'RB',76),('all',797,'WR',73),('all',797,'TE',86),('all',797,'OL',91),('all',797,'DL',86),('all',797,'LB',83),('all',797,'CB',75),('all',797,'S',81),
('all',798,'QB',71),('all',798,'RB',89),('all',798,'WR',87),('all',798,'TE',78),('all',798,'OL',74),('all',798,'DL',87),('all',798,'LB',88),('all',798,'CB',88),('all',798,'S',85),
('all',799,'QB',78),('all',799,'RB',71),('all',799,'WR',70),('all',799,'TE',82),('all',799,'OL',84),('all',799,'DL',81),('all',799,'LB',77),('all',799,'CB',65),('all',799,'S',70),
('all',800,'QB',89),('all',800,'RB',82),('all',800,'WR',80),('all',800,'TE',86),('all',800,'OL',87),('all',800,'DL',86),('all',800,'LB',85),('all',800,'CB',80),('all',800,'S',84),
('all',801,'QB',91),('all',801,'RB',79),('all',801,'WR',77),('all',801,'TE',82),('all',801,'OL',84),('all',801,'DL',83),('all',801,'LB',84),('all',801,'CB',79),('all',801,'S',85),
('all',802,'QB',84),('all',802,'RB',93),('all',802,'WR',93),('all',802,'TE',87),('all',802,'OL',80),('all',802,'DL',85),('all',802,'LB',88),('all',802,'CB',93),('all',802,'S',90),
('all',803,'QB',69),('all',803,'RB',71),('all',803,'WR',73),('all',803,'TE',66),('all',803,'OL',63),('all',803,'DL',66),('all',803,'LB',67),('all',803,'CB',72),('all',803,'S',68),
('all',804,'QB',86),('all',804,'RB',86),('all',804,'WR',88),('all',804,'TE',83),('all',804,'OL',79),('all',804,'DL',78),('all',804,'LB',78),('all',804,'CB',87),('all',804,'S',82),
('all',805,'QB',74),('all',805,'RB',66),('all',805,'WR',59),('all',805,'TE',82),('all',805,'OL',94),('all',805,'DL',92),('all',805,'LB',87),('all',805,'CB',66),('all',805,'S',81),
('all',806,'QB',91),('all',806,'RB',87),('all',806,'WR',86),('all',806,'TE',81),('all',806,'OL',77),('all',806,'DL',82),('all',806,'LB',83),('all',806,'CB',85),('all',806,'S',83),
('all',807,'QB',86),('all',807,'RB',96),('all',807,'WR',97),('all',807,'TE',89),('all',807,'OL',81),('all',807,'DL',84),('all',807,'LB',87),('all',807,'CB',96),('all',807,'S',90),
('all',808,'QB',60),('all',808,'RB',57),('all',808,'WR',55),('all',808,'TE',56),('all',808,'OL',60),('all',808,'DL',61),('all',808,'LB',61),('all',808,'CB',55),('all',808,'S',58),
('all',809,'QB',77),('all',809,'RB',72),('all',809,'WR',66),('all',809,'TE',86),('all',809,'OL',95),('all',809,'DL',95),('all',809,'LB',89),('all',809,'CB',68),('all',809,'S',80),
('all',810,'QB',57),('all',810,'RB',63),('all',810,'WR',64),('all',810,'TE',59),('all',810,'OL',57),('all',810,'DL',60),('all',810,'LB',60),('all',810,'CB',64),('all',810,'S',60),
('all',811,'QB',66),('all',811,'RB',73),('all',811,'WR',73),('all',811,'TE',70),('all',811,'OL',68),('all',811,'DL',70),('all',811,'LB',70),('all',811,'CB',72),('all',811,'S',70),
('all',812,'QB',73),('all',812,'RB',80),('all',812,'WR',79),('all',812,'TE',82),('all',812,'OL',82),('all',812,'DL',84),('all',812,'LB',83),('all',812,'CB',78),('all',812,'S',80),
('all',813,'QB',57),('all',813,'RB',65),('all',813,'WR',66),('all',813,'TE',60),('all',813,'OL',57),('all',813,'DL',60),('all',813,'LB',60),('all',813,'CB',65),('all',813,'S',60),
('all',814,'QB',67),('all',814,'RB',76),('all',814,'WR',77),('all',814,'TE',70),('all',814,'OL',66),('all',814,'DL',70),('all',814,'LB',71),('all',814,'CB',76),('all',814,'S',72),
('all',815,'QB',75),('all',815,'RB',88),('all',815,'WR',88),('all',815,'TE',83),('all',815,'OL',78),('all',815,'DL',82),('all',815,'LB',83),('all',815,'CB',87),('all',815,'S',84),
('all',816,'QB',62),('all',816,'RB',63),('all',816,'WR',66),('all',816,'TE',58),('all',816,'OL',55),('all',816,'DL',56),('all',816,'LB',56),('all',816,'CB',65),('all',816,'S',59),
('all',817,'QB',73),('all',817,'RB',73),('all',817,'WR',76),('all',817,'TE',69),('all',817,'OL',65),('all',817,'DL',65),('all',817,'LB',66),('all',817,'CB',75),('all',817,'S',69),
('all',818,'QB',84),('all',818,'RB',86),('all',818,'WR',87),('all',818,'TE',81),('all',818,'OL',76),('all',818,'DL',77),('all',818,'LB',78),('all',818,'CB',87),('all',818,'S',81),
('all',819,'QB',53),('all',819,'RB',53),('all',819,'WR',53),('all',819,'TE',53),('all',819,'OL',55),('all',819,'DL',56),('all',819,'LB',54),('all',819,'CB',52),('all',819,'S',52),
('all',820,'QB',68),('all',820,'RB',63),('all',820,'WR',61),('all',820,'TE',67),('all',820,'OL',71),('all',820,'DL',72),('all',820,'LB',72),('all',820,'CB',60),('all',820,'S',68),
('all',821,'QB',53),('all',821,'RB',58),('all',821,'WR',60),('all',821,'TE',52),('all',821,'OL',50),('all',821,'DL',52),('all',821,'LB',53),('all',821,'CB',59),('all',821,'S',54),
('all',822,'QB',62),('all',822,'RB',69),('all',822,'WR',70),('all',822,'TE',66),('all',822,'OL',64),('all',822,'DL',65),('all',822,'LB',65),('all',822,'CB',69),('all',822,'S',66),
('all',823,'QB',71),('all',823,'RB',74),('all',823,'WR',73),('all',823,'TE',78),('all',823,'OL',80),('all',823,'DL',78),('all',823,'LB',78),('all',823,'CB',74),('all',823,'S',77),
('all',824,'QB',50),('all',824,'RB',52),('all',824,'WR',54),('all',824,'TE',49),('all',824,'OL',49),('all',824,'DL',47),('all',824,'LB',47),('all',824,'CB',53),('all',824,'S',49),
('all',825,'QB',64),('all',825,'RB',57),('all',825,'WR',57),('all',825,'TE',60),('all',825,'OL',63),('all',825,'DL',59),('all',825,'LB',60),('all',825,'CB',59),('all',825,'S',62),
('all',826,'QB',81),('all',826,'RB',79),('all',826,'WR',81),('all',826,'TE',77),('all',826,'OL',75),('all',826,'DL',72),('all',826,'LB',76),('all',826,'CB',83),('all',826,'S',82),
('all',827,'QB',57),('all',827,'RB',55),('all',827,'WR',58),('all',827,'TE',54),('all',827,'OL',53),('all',827,'DL',51),('all',827,'LB',51),('all',827,'CB',57),('all',827,'S',53),
('all',828,'QB',77),('all',828,'RB',77),('all',828,'WR',79),('all',828,'TE',73),('all',828,'OL',69),('all',828,'DL',68),('all',828,'LB',71),('all',828,'CB',78),('all',828,'S',75),
('all',829,'QB',55),('all',829,'RB',48),('all',829,'WR',49),('all',829,'TE',50),('all',829,'OL',54),('all',829,'DL',53),('all',829,'LB',52),('all',829,'CB',49),('all',829,'S',52),
('all',830,'QB',78),('all',830,'RB',71),('all',830,'WR',72),('all',830,'TE',68),('all',830,'OL',67),('all',830,'DL',65),('all',830,'LB',70),('all',830,'CB',74),('all',830,'S',75),
('all',831,'QB',56),('all',831,'RB',57),('all',831,'WR',58),('all',831,'TE',56),('all',831,'OL',56),('all',831,'DL',56),('all',831,'LB',55),('all',831,'CB',58),('all',831,'S',56),
('all',832,'QB',73),('all',832,'RB',78),('all',832,'WR',78),('all',832,'TE',78),('all',832,'OL',77),('all',832,'DL',76),('all',832,'LB',77),('all',832,'CB',80),('all',832,'S',79),
('all',833,'QB',55),('all',833,'RB',57),('all',833,'WR',57),('all',833,'TE',57),('all',833,'OL',58),('all',833,'DL',59),('all',833,'LB',57),('all',833,'CB',57),('all',833,'S',56),
('all',834,'QB',69),('all',834,'RB',76),('all',834,'WR',74),('all',834,'TE',78),('all',834,'OL',79),('all',834,'DL',81),('all',834,'LB',79),('all',834,'CB',74),('all',834,'S',76),
('all',835,'QB',55),('all',835,'RB',52),('all',835,'WR',52),('all',835,'TE',54),('all',835,'OL',57),('all',835,'DL',56),('all',835,'LB',54),('all',835,'CB',52),('all',835,'S',53),
('all',836,'QB',77),('all',836,'RB',85),('all',836,'WR',86),('all',836,'TE',78),('all',836,'OL',73),('all',836,'DL',75),('all',836,'LB',77),('all',836,'CB',85),('all',836,'S',79),
('all',837,'QB',55),('all',837,'RB',51),('all',837,'WR',52),('all',837,'TE',53),('all',837,'OL',56),('all',837,'DL',54),('all',837,'LB',53),('all',837,'CB',52),('all',837,'S',52),
('all',838,'QB',67),('all',838,'RB',64),('all',838,'WR',64),('all',838,'TE',69),('all',838,'OL',72),('all',838,'DL',69),('all',838,'LB',67),('all',838,'CB',65),('all',838,'S',67),
('all',839,'QB',76),('all',839,'RB',66),('all',839,'WR',63),('all',839,'TE',77),('all',839,'OL',84),('all',839,'DL',79),('all',839,'LB',77),('all',839,'CB',65),('all',839,'S',73),
('all',840,'QB',54),('all',840,'RB',51),('all',840,'WR',52),('all',840,'TE',49),('all',840,'OL',51),('all',840,'DL',53),('all',840,'LB',53),('all',840,'CB',52),('all',840,'S',53),
('all',841,'QB',76),('all',841,'RB',75),('all',841,'WR',74),('all',841,'TE',69),('all',841,'OL',67),('all',841,'DL',73),('all',841,'LB',75),('all',841,'CB',74),('all',841,'S',74),
('all',842,'QB',78),('all',842,'RB',66),('all',842,'WR',64),('all',842,'TE',69),('all',842,'OL',71),('all',842,'DL',71),('all',842,'LB',72),('all',842,'CB',63),('all',842,'S',69),
('all',843,'QB',57),('all',843,'RB',59),('all',843,'WR',60),('all',843,'TE',61),('all',843,'OL',63),('all',843,'DL',62),('all',843,'LB',60),('all',843,'CB',60),('all',843,'S',60),
('all',844,'QB',73),('all',844,'RB',75),('all',844,'WR',73),('all',844,'TE',80),('all',844,'OL',84),('all',844,'DL',83),('all',844,'LB',81),('all',844,'CB',75),('all',844,'S',79),
('all',845,'QB',78),('all',845,'RB',77),('all',845,'WR',78),('all',845,'TE',74),('all',845,'OL',71),('all',845,'DL',71),('all',845,'LB',74),('all',845,'CB',77),('all',845,'S',76),
('all',846,'QB',55),('all',846,'RB',62),('all',846,'WR',64),('all',846,'TE',55),('all',846,'OL',53),('all',846,'DL',57),('all',846,'LB',57),('all',846,'CB',63),('all',846,'S',57),
('all',847,'QB',71),('all',847,'RB',89),('all',847,'WR',89),('all',847,'TE',81),('all',847,'OL',75),('all',847,'DL',80),('all',847,'LB',81),('all',847,'CB',88),('all',847,'S',82),
('all',848,'QB',56),('all',848,'RB',53),('all',848,'WR',54),('all',848,'TE',52),('all',848,'OL',54),('all',848,'DL',53),('all',848,'LB',52),('all',848,'CB',54),('all',848,'S',51),
('all',849,'QB',81),('all',849,'RB',76),('all',849,'WR',74),('all',849,'TE',76),('all',849,'OL',76),('all',849,'DL',76),('all',849,'LB',76),('all',849,'CB',74),('all',849,'S',75),
('all',850,'QB',59),('all',850,'RB',59),('all',850,'WR',60),('all',850,'TE',56),('all',850,'OL',55),('all',850,'DL',58),('all',850,'LB',58),('all',850,'CB',59),('all',850,'S',58),
('all',851,'QB',79),('all',851,'RB',76),('all',851,'WR',74),('all',851,'TE',80),('all',851,'OL',81),('all',851,'DL',81),('all',851,'LB',80),('all',851,'CB',73),('all',851,'S',77),
('all',852,'QB',59),('all',852,'RB',57),('all',852,'WR',56),('all',852,'TE',57),('all',852,'OL',60),('all',852,'DL',61),('all',852,'LB',59),('all',852,'CB',56),('all',852,'S',57),
('all',853,'QB',72),('all',853,'RB',69),('all',853,'WR',65),('all',853,'TE',74),('all',853,'OL',78),('all',853,'DL',79),('all',853,'LB',77),('all',853,'CB',66),('all',853,'S',73),
('all',854,'QB',63),('all',854,'RB',60),('all',854,'WR',62),('all',854,'TE',51),('all',854,'OL',48),('all',854,'DL',52),('all',854,'LB',55),('all',854,'CB',62),('all',854,'S',58),
('all',855,'QB',89),('all',855,'RB',76),('all',855,'WR',78),('all',855,'TE',67),('all',855,'OL',62),('all',855,'DL',65),('all',855,'LB',72),('all',855,'CB',78),('all',855,'S',77),
('all',856,'QB',59),('all',856,'RB',54),('all',856,'WR',56),('all',856,'TE',52),('all',856,'OL',53),('all',856,'DL',52),('all',856,'LB',52),('all',856,'CB',56),('all',856,'S',54),
('all',857,'QB',70),('all',857,'RB',62),('all',857,'WR',64),('all',857,'TE',61),('all',857,'OL',61),('all',857,'DL',59),('all',857,'LB',61),('all',857,'CB',64),('all',857,'S',63),
('all',858,'QB',87),('all',858,'RB',67),('all',858,'WR',64),('all',858,'TE',70),('all',858,'OL',75),('all',858,'DL',73),('all',858,'LB',75),('all',858,'CB',66),('all',858,'S',73),
('all',859,'QB',57),('all',859,'RB',57),('all',859,'WR',58),('all',859,'TE',54),('all',859,'OL',54),('all',859,'DL',54),('all',859,'LB',53),('all',859,'CB',57),('all',859,'S',54),
('all',860,'QB',67),('all',860,'RB',67),('all',860,'WR',68),('all',860,'TE',64),('all',860,'OL',63),('all',860,'DL',62),('all',860,'LB',63),('all',860,'CB',67),('all',860,'S',64),
('all',861,'QB',78),('all',861,'RB',74),('all',861,'WR',71),('all',861,'TE',77),('all',861,'OL',78),('all',861,'DL',80),('all',861,'LB',78),('all',861,'CB',70),('all',861,'S',74),
('all',862,'QB',74),('all',862,'RB',81),('all',862,'WR',82),('all',862,'TE',81),('all',862,'OL',79),('all',862,'DL',79),('all',862,'LB',80),('all',862,'CB',82),('all',862,'S',81),
('all',863,'QB',66),('all',863,'RB',68),('all',863,'WR',65),('all',863,'TE',71),('all',863,'OL',75),('all',863,'DL',77),('all',863,'LB',75),('all',863,'CB',66),('all',863,'S',71),
('all',864,'QB',91),('all',864,'RB',69),('all',864,'WR',68),('all',864,'TE',66),('all',864,'OL',66),('all',864,'DL',68),('all',864,'LB',73),('all',864,'CB',68),('all',864,'S',73),
('all',865,'QB',74),('all',865,'RB',75),('all',865,'WR',72),('all',865,'TE',79),('all',865,'OL',82),('all',865,'DL',85),('all',865,'LB',83),('all',865,'CB',73),('all',865,'S',78),
('all',866,'QB',84),('all',866,'RB',76),('all',866,'WR',75),('all',866,'TE',77),('all',866,'OL',77),('all',866,'DL',76),('all',866,'LB',77),('all',866,'CB',75),('all',866,'S',77),
('all',867,'QB',71),('all',867,'RB',66),('all',867,'WR',62),('all',867,'TE',75),('all',867,'OL',83),('all',867,'DL',80),('all',867,'LB',79),('all',867,'CB',67),('all',867,'S',76),
('all',868,'QB',59),('all',868,'RB',55),('all',868,'WR',57),('all',868,'TE',49),('all',868,'OL',48),('all',868,'DL',50),('all',868,'LB',52),('all',868,'CB',56),('all',868,'S',54),
('all',869,'QB',85),('all',869,'RB',75),('all',869,'WR',76),('all',869,'TE',68),('all',869,'OL',64),('all',869,'DL',65),('all',869,'LB',71),('all',869,'CB',77),('all',869,'S',77),
('all',870,'QB',71),('all',870,'RB',74),('all',870,'WR',72),('all',870,'TE',77),('all',870,'OL',79),('all',870,'DL',79),('all',870,'LB',77),('all',870,'CB',73),('all',870,'S',75),
('all',871,'QB',74),('all',871,'RB',62),('all',871,'WR',58),('all',871,'TE',62),('all',871,'OL',67),('all',871,'DL',70),('all',871,'LB',71),('all',871,'CB',60),('all',871,'S',68),
('all',872,'QB',51),('all',872,'RB',46),('all',872,'WR',47),('all',872,'TE',45),('all',872,'OL',48),('all',872,'DL',47),('all',872,'LB',46),('all',872,'CB',46),('all',872,'S',45),
('all',873,'QB',84),('all',873,'RB',72),('all',873,'WR',72),('all',873,'TE',72),('all',873,'OL',72),('all',873,'DL',70),('all',873,'LB',71),('all',873,'CB',72),('all',873,'S',73),
('all',874,'QB',59),('all',874,'RB',72),('all',874,'WR',69),('all',874,'TE',81),('all',874,'OL',87),('all',874,'DL',88),('all',874,'LB',81),('all',874,'CB',70),('all',874,'S',74),
('all',875,'QB',72),('all',875,'RB',68),('all',875,'WR',67),('all',875,'TE',74),('all',875,'OL',79),('all',875,'DL',76),('all',875,'LB',75),('all',875,'CB',69),('all',875,'S',74),
('all',876,'QB',82),('all',876,'RB',79),('all',876,'WR',80),('all',876,'TE',74),('all',876,'OL',70),('all',876,'DL',70),('all',876,'LB',73),('all',876,'CB',80),('all',876,'S',77),
('all',877,'QB',71),('all',877,'RB',78),('all',877,'WR',78),('all',877,'TE',69),('all',877,'OL',65),('all',877,'DL',70),('all',877,'LB',72),('all',877,'CB',78),('all',877,'S',73),
('all',878,'QB',58),('all',878,'RB',58),('all',878,'WR',57),('all',878,'TE',64),('all',878,'OL',67),('all',878,'DL',66),('all',878,'LB',62),('all',878,'CB',57),('all',878,'S',59),
('all',879,'QB',73),('all',879,'RB',67),('all',879,'WR',62),('all',879,'TE',78),('all',879,'OL',84),('all',879,'DL',83),('all',879,'LB',78),('all',879,'CB',61),('all',879,'S',70),
('all',880,'QB',76),('all',880,'RB',76),('all',880,'WR',74),('all',880,'TE',80),('all',880,'OL',81),('all',880,'DL',81),('all',880,'LB',79),('all',880,'CB',75),('all',880,'S',77),
('all',881,'QB',77),('all',881,'RB',72),('all',881,'WR',69),('all',881,'TE',78),('all',881,'OL',81),('all',881,'DL',80),('all',881,'LB',78),('all',881,'CB',70),('all',881,'S',75),
('all',882,'QB',74),('all',882,'RB',75),('all',882,'WR',75),('all',882,'TE',80),('all',882,'OL',82),('all',882,'DL',80),('all',882,'LB',78),('all',882,'CB',75),('all',882,'S',78),
('all',883,'QB',76),('all',883,'RB',71),('all',883,'WR',70),('all',883,'TE',78),('all',883,'OL',82),('all',883,'DL',79),('all',883,'LB',78),('all',883,'CB',71),('all',883,'S',76),
('all',884,'QB',80),('all',884,'RB',77),('all',884,'WR',77),('all',884,'TE',79),('all',884,'OL',79),('all',884,'DL',81),('all',884,'LB',78),('all',884,'CB',79),('all',884,'S',77),
('all',885,'QB',56),('all',885,'RB',65),('all',885,'WR',67),('all',885,'TE',57),('all',885,'OL',53),('all',885,'DL',56),('all',885,'LB',57),('all',885,'CB',66),('all',885,'S',58),
('all',886,'QB',66),('all',886,'RB',76),('all',886,'WR',78),('all',886,'TE',71),('all',886,'OL',66),('all',886,'DL',68),('all',886,'LB',69),('all',886,'CB',77),('all',886,'S',71),
('all',887,'QB',84),('all',887,'RB',96),('all',887,'WR',97),('all',887,'TE',90),('all',887,'OL',83),('all',887,'DL',86),('all',887,'LB',88),('all',887,'CB',96),('all',887,'S',89),
('all',888,'QB',87),('all',888,'RB',99),('all',888,'WR',99),('all',888,'TE',96),('all',888,'OL',91),('all',888,'DL',92),('all',888,'LB',94),('all',888,'CB',99),('all',888,'S',97),
('all',889,'QB',87),('all',889,'RB',98),('all',889,'WR',99),('all',889,'TE',97),('all',889,'OL',92),('all',889,'DL',92),('all',889,'LB',94),('all',889,'CB',99),('all',889,'S',97),
('all',890,'QB',97),('all',890,'RB',95),('all',890,'WR',97),('all',890,'TE',98),('all',890,'OL',94),('all',890,'DL',89),('all',890,'LB',89),('all',890,'CB',96),('all',890,'S',93),
('all',891,'QB',65),('all',891,'RB',70),('all',891,'WR',69),('all',891,'TE',67),('all',891,'OL',67),('all',891,'DL',69),('all',891,'LB',70),('all',891,'CB',68),('all',891,'S',68),
('all',892,'QB',73),('all',892,'RB',84),('all',892,'WR',82),('all',892,'TE',85),('all',892,'OL',84),('all',892,'DL',87),('all',892,'LB',86),('all',892,'CB',82),('all',892,'S',83),
('all',893,'QB',80),('all',893,'RB',89),('all',893,'WR',88),('all',893,'TE',88),('all',893,'OL',86),('all',893,'DL',87),('all',893,'LB',88),('all',893,'CB',88),('all',893,'S',89),
('all',894,'QB',82),('all',894,'RB',96),('all',894,'WR',99),('all',894,'TE',89),('all',894,'OL',79),('all',894,'DL',81),('all',894,'LB',82),('all',894,'CB',98),('all',894,'S',88),
('all',895,'QB',80),('all',895,'RB',80),('all',895,'WR',81),('all',895,'TE',83),('all',895,'OL',80),('all',895,'DL',80),('all',895,'LB',79),('all',895,'CB',76),('all',895,'S',76),
('all',896,'QB',78),('all',896,'RB',72),('all',896,'WR',66),('all',896,'TE',85),('all',896,'OL',95),('all',896,'DL',93),('all',896,'LB',89),('all',896,'CB',68),('all',896,'S',82),
('all',897,'QB',92),('all',897,'RB',90),('all',897,'WR',94),('all',897,'TE',84),('all',897,'OL',76),('all',897,'DL',75),('all',897,'LB',79),('all',897,'CB',92),('all',897,'S',84),
('all',898,'QB',76),('all',898,'RB',77),('all',898,'WR',78),('all',898,'TE',75),('all',898,'OL',72),('all',898,'DL',73),('all',898,'LB',75),('all',898,'CB',77),('all',898,'S',77),
('all',899,'QB',80),('all',899,'RB',75),('all',899,'WR',73),('all',899,'TE',78),('all',899,'OL',79),('all',899,'DL',79),('all',899,'LB',78),('all',899,'CB',72),('all',899,'S',75),
('all',900,'QB',69),('all',900,'RB',79),('all',900,'WR',77),('all',900,'TE',81),('all',900,'OL',82),('all',900,'DL',85),('all',900,'LB',83),('all',900,'CB',77),('all',900,'S',80),
('all',901,'QB',71),('all',901,'RB',74),('all',901,'WR',70),('all',901,'TE',83),('all',901,'OL',88),('all',901,'DL',89),('all',901,'LB',85),('all',901,'CB',70),('all',901,'S',78),
('all',902,'QB',76),('all',902,'RB',78),('all',902,'WR',77),('all',902,'TE',81),('all',902,'OL',80),('all',902,'DL',81),('all',902,'LB',80),('all',902,'CB',75),('all',902,'S',77),
('all',903,'QB',71),('all',903,'RB',88),('all',903,'WR',88),('all',903,'TE',83),('all',903,'OL',77),('all',903,'DL',82),('all',903,'LB',83),('all',903,'CB',87),('all',903,'S',83),
('all',904,'QB',72),('all',904,'RB',79),('all',904,'WR',78),('all',904,'TE',81),('all',904,'OL',81),('all',904,'DL',82),('all',904,'LB',81),('all',904,'CB',78),('all',904,'S',79),
('all',905,'QB',90),('all',905,'RB',87),('all',905,'WR',86),('all',905,'TE',84),('all',905,'OL',81),('all',905,'DL',83),('all',905,'LB',84),('all',905,'CB',86),('all',905,'S',84),
('all',906,'QB',59),('all',906,'RB',63),('all',906,'WR',64),('all',906,'TE',59),('all',906,'OL',58),('all',906,'DL',60),('all',906,'LB',60),('all',906,'CB',64),('all',906,'S',60),
('all',907,'QB',67),('all',907,'RB',73),('all',907,'WR',73),('all',907,'TE',69),('all',907,'OL',67),('all',907,'DL',69),('all',907,'LB',69),('all',907,'CB',73),('all',907,'S',70),
('all',908,'QB',78),('all',908,'RB',88),('all',908,'WR',88),('all',908,'TE',82),('all',908,'OL',77),('all',908,'DL',80),('all',908,'LB',82),('all',908,'CB',88),('all',908,'S',83),
('all',909,'QB',60),('all',909,'RB',56),('all',909,'WR',57),('all',909,'TE',57),('all',909,'OL',59),('all',909,'DL',58),('all',909,'LB',56),('all',909,'CB',56),('all',909,'S',56),
('all',910,'QB',71),('all',910,'RB',63),('all',910,'WR',64),('all',910,'TE',66),('all',910,'OL',68),('all',910,'DL',66),('all',910,'LB',65),('all',910,'CB',64),('all',910,'S',65),
('all',911,'QB',81),('all',911,'RB',74),('all',911,'WR',73),('all',911,'TE',79),('all',911,'OL',82),('all',911,'DL',78),('all',911,'LB',77),('all',911,'CB',73),('all',911,'S',76),
('all',912,'QB',59),('all',912,'RB',60),('all',912,'WR',60),('all',912,'TE',58),('all',912,'OL',59),('all',912,'DL',60),('all',912,'LB',59),('all',912,'CB',60),('all',912,'S',58),
('all',913,'QB',67),('all',913,'RB',69),('all',913,'WR',68),('all',913,'TE',69),('all',913,'OL',69),('all',913,'DL',70),('all',913,'LB',69),('all',913,'CB',68),('all',913,'S',68),
('all',914,'QB',78),('all',914,'RB',80),('all',914,'WR',78),('all',914,'TE',81),('all',914,'OL',80),('all',914,'DL',82),('all',914,'LB',82),('all',914,'CB',78),('all',914,'S',79),
('all',915,'QB',54),('all',915,'RB',53),('all',915,'WR',54),('all',915,'TE',54),('all',915,'OL',56),('all',915,'DL',55),('all',915,'LB',53),('all',915,'CB',53),('all',915,'S',53),
('all',916,'QB',72),('all',916,'RB',73),('all',916,'WR',72),('all',916,'TE',77),('all',916,'OL',78),('all',916,'DL',78),('all',916,'LB',77),('all',916,'CB',71),('all',916,'S',74),
('all',917,'QB',51),('all',917,'RB',48),('all',917,'WR',48),('all',917,'TE',48),('all',917,'OL',52),('all',917,'DL',51),('all',917,'LB',50),('all',917,'CB',48),('all',917,'S',49),
('all',918,'QB',67),('all',918,'RB',63),('all',918,'WR',61),('all',918,'TE',67),('all',918,'OL',71),('all',918,'DL',70),('all',918,'LB',70),('all',918,'CB',63),('all',918,'S',68),
('all',919,'QB',48),('all',919,'RB',54),('all',919,'WR',55),('all',919,'TE',49),('all',919,'OL',48),('all',919,'DL',51),('all',919,'LB',51),('all',919,'CB',55),('all',919,'S',51),
('all',920,'QB',67),('all',920,'RB',78),('all',920,'WR',77),('all',920,'TE',74),('all',920,'OL',73),('all',920,'DL',75),('all',920,'LB',76),('all',920,'CB',77),('all',920,'S',75),
('all',921,'QB',53),('all',921,'RB',58),('all',921,'WR',60),('all',921,'TE',52),('all',921,'OL',50),('all',921,'DL',52),('all',921,'LB',52),('all',921,'CB',58),('all',921,'S',53),
('all',922,'QB',61),('all',922,'RB',70),('all',922,'WR',71),('all',922,'TE',64),('all',922,'OL',60),('all',922,'DL',63),('all',922,'LB',64),('all',922,'CB',70),('all',922,'S',64),
('all',923,'QB',73),('all',923,'RB',82),('all',923,'WR',82),('all',923,'TE',79),('all',923,'OL',76),('all',923,'DL',79),('all',923,'LB',79),('all',923,'CB',81),('all',923,'S',79),
('all',924,'QB',58),('all',924,'RB',65),('all',924,'WR',68),('all',924,'TE',58),('all',924,'OL',54),('all',924,'DL',56),('all',924,'LB',58),('all',924,'CB',67),('all',924,'S',60),
('all',925,'QB',73),('all',925,'RB',83),('all',925,'WR',85),('all',925,'TE',73),('all',925,'OL',66),('all',925,'DL',69),('all',925,'LB',74),('all',925,'CB',84),('all',925,'S',78),
('all',926,'QB',57),('all',926,'RB',63),('all',926,'WR',64),('all',926,'TE',61),('all',926,'OL',60),('all',926,'DL',61),('all',926,'LB',61),('all',926,'CB',65),('all',926,'S',62),
('all',927,'QB',71),('all',927,'RB',79),('all',927,'WR',80),('all',927,'TE',76),('all',927,'OL',74),('all',927,'DL',75),('all',927,'LB',77),('all',927,'CB',82),('all',927,'S',80),
('all',928,'QB',59),('all',928,'RB',52),('all',928,'WR',53),('all',928,'TE',52),('all',928,'OL',54),('all',928,'DL',53),('all',928,'LB',53),('all',928,'CB',53),('all',928,'S',53),
('all',929,'QB',69),('all',929,'RB',59),('all',929,'WR',58),('all',929,'TE',60),('all',929,'OL',63),('all',929,'DL',61),('all',929,'LB',62),('all',929,'CB',59),('all',929,'S',61),
('all',930,'QB',85),('all',930,'RB',68),('all',930,'WR',67),('all',930,'TE',73),('all',930,'OL',77),('all',930,'DL',73),('all',930,'LB',74),('all',930,'CB',68),('all',930,'S',74),
('all',931,'QB',65),('all',931,'RB',77),('all',931,'WR',78),('all',931,'TE',69),('all',931,'OL',64),('all',931,'DL',69),('all',931,'LB',71),('all',931,'CB',75),('all',931,'S',71),
('all',932,'QB',53),('all',932,'RB',52),('all',932,'WR',52),('all',932,'TE',56),('all',932,'OL',61),('all',932,'DL',60),('all',932,'LB',57),('all',932,'CB',52),('all',932,'S',54),
('all',933,'QB',60),('all',933,'RB',58),('all',933,'WR',57),('all',933,'TE',65),('all',933,'OL',71),('all',933,'DL',68),('all',933,'LB',65),('all',933,'CB',59),('all',933,'S',63),
('all',934,'QB',70),('all',934,'RB',67),('all',934,'WR',64),('all',934,'TE',78),('all',934,'OL',85),('all',934,'DL',82),('all',934,'LB',80),('all',934,'CB',66),('all',934,'S',76),
('all',935,'QB',56),('all',935,'RB',53),('all',935,'WR',53),('all',935,'TE',54),('all',935,'OL',56),('all',935,'DL',55),('all',935,'LB',54),('all',935,'CB',53),('all',935,'S',52),
('all',936,'QB',85),('all',936,'RB',75),('all',936,'WR',76),('all',936,'TE',78),('all',936,'OL',78),('all',936,'DL',75),('all',936,'LB',75),('all',936,'CB',77),('all',936,'S',77),
('all',937,'QB',76),('all',937,'RB',81),('all',937,'WR',79),('all',937,'TE',81),('all',937,'OL',81),('all',937,'DL',83),('all',937,'LB',83),('all',937,'CB',80),('all',937,'S',82),
('all',938,'QB',58),('all',938,'RB',56),('all',938,'WR',59),('all',938,'TE',50),('all',938,'OL',48),('all',938,'DL',49),('all',938,'LB',51),('all',938,'CB',58),('all',938,'S',53),
('all',939,'QB',79),('all',939,'RB',68),('all',939,'WR',68),('all',939,'TE',74),('all',939,'OL',77),('all',939,'DL',73),('all',939,'LB',72),('all',939,'CB',67),('all',939,'S',72),
('all',940,'QB',59),('all',940,'RB',62),('all',940,'WR',65),('all',940,'TE',56),('all',940,'OL',53),('all',940,'DL',54),('all',940,'LB',55),('all',940,'CB',64),('all',940,'S',57),
('all',941,'QB',79),('all',941,'RB',85),('all',941,'WR',87),('all',941,'TE',78),('all',941,'OL',72),('all',941,'DL',72),('all',941,'LB',74),('all',941,'CB',86),('all',941,'S',79),
('all',942,'QB',59),('all',942,'RB',62),('all',942,'WR',61),('all',942,'TE',62),('all',942,'OL',63),('all',942,'DL',65),('all',942,'LB',63),('all',942,'CB',61),('all',942,'S',61),
('all',943,'QB',72),('all',943,'RB',79),('all',943,'WR',78),('all',943,'TE',80),('all',943,'OL',80),('all',943,'DL',82),('all',943,'LB',82),('all',943,'CB',78),('all',943,'S',79),
('all',944,'QB',56),('all',944,'RB',65),('all',944,'WR',67),('all',944,'TE',56),('all',944,'OL',51),('all',944,'DL',56),('all',944,'LB',58),('all',944,'CB',66),('all',944,'S',59),
('all',945,'QB',76),('all',945,'RB',83),('all',945,'WR',84),('all',945,'TE',77),('all',945,'OL',73),('all',945,'DL',75),('all',945,'LB',77),('all',945,'CB',83),('all',945,'S',79),
('all',946,'QB',56),('all',946,'RB',61),('all',946,'WR',62),('all',946,'TE',54),('all',946,'OL',52),('all',946,'DL',55),('all',946,'LB',56),('all',946,'CB',61),('all',946,'S',56),
('all',947,'QB',75),('all',947,'RB',80),('all',947,'WR',78),('all',947,'TE',74),('all',947,'OL',72),('all',947,'DL',76),('all',947,'LB',78),('all',947,'CB',78),('all',947,'S',77),
('all',948,'QB',66),('all',948,'RB',66),('all',948,'WR',68),('all',948,'TE',64),('all',948,'OL',62),('all',948,'DL',59),('all',948,'LB',61),('all',948,'CB',68),('all',948,'S',65),
('all',949,'QB',81),('all',949,'RB',83),('all',949,'WR',84),('all',949,'TE',80),('all',949,'OL',76),('all',949,'DL',74),('all',949,'LB',77),('all',949,'CB',84),('all',949,'S',82),
('all',950,'QB',64),('all',950,'RB',73),('all',950,'WR',71),('all',950,'TE',76),('all',950,'OL',79),('all',950,'DL',79),('all',950,'LB',77),('all',950,'CB',73),('all',950,'S',75),
('all',951,'QB',60),('all',951,'RB',59),('all',951,'WR',60),('all',951,'TE',56),('all',951,'OL',55),('all',951,'DL',58),('all',951,'LB',57),('all',951,'CB',59),('all',951,'S',57),
('all',952,'QB',79),('all',952,'RB',76),('all',952,'WR',74),('all',952,'TE',73),('all',952,'OL',73),('all',952,'DL',76),('all',952,'LB',76),('all',952,'CB',74),('all',952,'S',74),
('all',953,'QB',55),('all',953,'RB',54),('all',953,'WR',55),('all',953,'TE',52),('all',953,'OL',53),('all',953,'DL',54),('all',953,'LB',55),('all',953,'CB',56),('all',953,'S',55),
('all',954,'QB',82),('all',954,'RB',67),('all',954,'WR',68),('all',954,'TE',66),('all',954,'OL',66),('all',954,'DL',65),('all',954,'LB',69),('all',954,'CB',69),('all',954,'S',71),
('all',955,'QB',57),('all',955,'RB',62),('all',955,'WR',65),('all',955,'TE',53),('all',955,'OL',49),('all',955,'DL',51),('all',955,'LB',53),('all',955,'CB',64),('all',955,'S',56),
('all',956,'QB',78),('all',956,'RB',79),('all',956,'WR',82),('all',956,'TE',77),('all',956,'OL',73),('all',956,'DL',71),('all',956,'LB',72),('all',956,'CB',80),('all',956,'S',75),
('all',957,'QB',58),('all',957,'RB',61),('all',957,'WR',62),('all',957,'TE',58),('all',957,'OL',57),('all',957,'DL',57),('all',957,'LB',57),('all',957,'CB',62),('all',957,'S',59),
('all',958,'QB',65),('all',958,'RB',69),('all',958,'WR',71),('all',958,'TE',68),('all',958,'OL',67),('all',958,'DL',65),('all',958,'LB',66),('all',958,'CB',71),('all',958,'S',68),
('all',959,'QB',77),('all',959,'RB',80),('all',959,'WR',81),('all',959,'TE',80),('all',959,'OL',76),('all',959,'DL',75),('all',959,'LB',77),('all',959,'CB',81),('all',959,'S',80),
('all',960,'QB',53),('all',960,'RB',66),('all',960,'WR',69),('all',960,'TE',57),('all',960,'OL',52),('all',960,'DL',55),('all',960,'LB',55),('all',960,'CB',68),('all',960,'S',58),
('all',961,'QB',69),('all',961,'RB',83),('all',961,'WR',84),('all',961,'TE',73),('all',961,'OL',67),('all',961,'DL',72),('all',961,'LB',75),('all',961,'CB',84),('all',961,'S',77),
('all',962,'QB',73),('all',962,'RB',78),('all',962,'WR',77),('all',962,'TE',78),('all',962,'OL',78),('all',962,'DL',79),('all',962,'LB',79),('all',962,'CB',77),('all',962,'S',78),
('all',963,'QB',58),('all',963,'RB',64),('all',963,'WR',66),('all',963,'TE',64),('all',963,'OL',62),('all',963,'DL',60),('all',963,'LB',58),('all',963,'CB',65),('all',963,'S',59),
('all',964,'QB',69),('all',964,'RB',78),('all',964,'WR',80),('all',964,'TE',77),('all',964,'OL',73),('all',964,'DL',72),('all',964,'LB',73),('all',964,'CB',79),('all',964,'S',75),
('all',965,'QB',55),('all',965,'RB',58),('all',965,'WR',58),('all',965,'TE',61),('all',965,'OL',65),('all',965,'DL',64),('all',965,'LB',61),('all',965,'CB',58),('all',965,'S',59),
('all',966,'QB',71),('all',966,'RB',80),('all',966,'WR',78),('all',966,'TE',81),('all',966,'OL',82),('all',966,'DL',83),('all',966,'LB',81),('all',966,'CB',78),('all',966,'S',79),
('all',967,'QB',77),('all',967,'RB',85),('all',967,'WR',86),('all',967,'TE',80),('all',967,'OL',76),('all',967,'DL',77),('all',967,'LB',78),('all',967,'CB',86),('all',967,'S',80),
('all',968,'QB',69),('all',968,'RB',71),('all',968,'WR',69),('all',968,'TE',79),('all',968,'OL',85),('all',968,'DL',82),('all',968,'LB',78),('all',968,'CB',71),('all',968,'S',76),
('all',969,'QB',71),('all',969,'RB',63),('all',969,'WR',65),('all',969,'TE',60),('all',969,'OL',59),('all',969,'DL',57),('all',969,'LB',58),('all',969,'CB',64),('all',969,'S',60),
('all',970,'QB',86),('all',970,'RB',78),('all',970,'WR',79),('all',970,'TE',77),('all',970,'OL',76),('all',970,'DL',73),('all',970,'LB',75),('all',970,'CB',79),('all',970,'S',78),
('all',971,'QB',55),('all',971,'RB',55),('all',971,'WR',55),('all',971,'TE',59),('all',971,'OL',63),('all',971,'DL',62),('all',971,'LB',59),('all',971,'CB',55),('all',971,'S',57),
('all',972,'QB',72),('all',972,'RB',75),('all',972,'WR',74),('all',972,'TE',76),('all',972,'OL',77),('all',972,'DL',77),('all',972,'LB',78),('all',972,'CB',75),('all',972,'S',78),
('all',973,'QB',74),('all',973,'RB',80),('all',973,'WR',78),('all',973,'TE',78),('all',973,'OL',77),('all',973,'DL',79),('all',973,'LB',79),('all',973,'CB',78),('all',973,'S',77),
('all',974,'QB',55),('all',974,'RB',59),('all',974,'WR',60),('all',974,'TE',63),('all',974,'OL',64),('all',974,'DL',63),('all',974,'LB',60),('all',974,'CB',57),('all',974,'S',57),
('all',975,'QB',68),('all',975,'RB',76),('all',975,'WR',75),('all',975,'TE',83),('all',975,'OL',84),('all',975,'DL',83),('all',975,'LB',79),('all',975,'CB',72),('all',975,'S',74),
('all',976,'QB',73),('all',976,'RB',74),('all',976,'WR',72),('all',976,'TE',76),('all',976,'OL',78),('all',976,'DL',77),('all',976,'LB',76),('all',976,'CB',72),('all',976,'S',73),
('all',977,'QB',72),('all',977,'RB',68),('all',977,'WR',66),('all',977,'TE',80),('all',977,'OL',87),('all',977,'DL',83),('all',977,'LB',79),('all',977,'CB',65),('all',977,'S',73),
('all',978,'QB',84),('all',978,'RB',76),('all',978,'WR',78),('all',978,'TE',70),('all',978,'OL',66),('all',978,'DL',65),('all',978,'LB',70),('all',978,'CB',77),('all',978,'S',74),
('all',979,'QB',74),('all',979,'RB',83),('all',979,'WR',82),('all',979,'TE',82),('all',979,'OL',80),('all',979,'DL',82),('all',979,'LB',82),('all',979,'CB',81),('all',979,'S',82),
('all',980,'QB',68),('all',980,'RB',61),('all',980,'WR',59),('all',980,'TE',70),('all',980,'OL',75),('all',980,'DL',70),('all',980,'LB',69),('all',980,'CB',58),('all',980,'S',66),
('all',981,'QB',80),('all',981,'RB',73),('all',981,'WR',72),('all',981,'TE',78),('all',981,'OL',80),('all',981,'DL',77),('all',981,'LB',76),('all',981,'CB',70),('all',981,'S',73),
('all',982,'QB',76),('all',982,'RB',73),('all',982,'WR',71),('all',982,'TE',77),('all',982,'OL',79),('all',982,'DL',78),('all',982,'LB',77),('all',982,'CB',70),('all',982,'S',74),
('all',983,'QB',74),('all',983,'RB',74),('all',983,'WR',70),('all',983,'TE',82),('all',983,'OL',87),('all',983,'DL',88),('all',983,'LB',85),('all',983,'CB',71),('all',983,'S',80),
('all',984,'QB',71),('all',984,'RB',82),('all',984,'WR',79),('all',984,'TE',88),('all',984,'OL',90),('all',984,'DL',92),('all',984,'LB',88),('all',984,'CB',80),('all',984,'S',83),
('all',985,'QB',80),('all',985,'RB',88),('all',985,'WR',91),('all',985,'TE',82),('all',985,'OL',76),('all',985,'DL',75),('all',985,'LB',80),('all',985,'CB',91),('all',985,'S',87),
('all',986,'QB',79),('all',986,'RB',77),('all',986,'WR',74),('all',986,'TE',80),('all',986,'OL',82),('all',986,'DL',84),('all',986,'LB',84),('all',986,'CB',75),('all',986,'S',81),
('all',987,'QB',95),('all',987,'RB',92),('all',987,'WR',97),('all',987,'TE',81),('all',987,'OL',70),('all',987,'DL',70),('all',987,'LB',78),('all',987,'CB',97),('all',987,'S',89),
('all',988,'QB',82),('all',988,'RB',82),('all',988,'WR',80),('all',988,'TE',85),('all',988,'OL',85),('all',988,'DL',86),('all',988,'LB',86),('all',988,'CB',80),('all',988,'S',84),
('all',989,'QB',87),('all',989,'RB',84),('all',989,'WR',85),('all',989,'TE',83),('all',989,'OL',81),('all',989,'DL',80),('all',989,'LB',81),('all',989,'CB',85),('all',989,'S',83),
('all',990,'QB',77),('all',990,'RB',86),('all',990,'WR',85),('all',990,'TE',87),('all',990,'OL',86),('all',990,'DL',88),('all',990,'LB',87),('all',990,'CB',86),('all',990,'S',86),
('all',991,'QB',86),('all',991,'RB',91),('all',991,'WR',93),('all',991,'TE',83),('all',991,'OL',77),('all',991,'DL',80),('all',991,'LB',82),('all',991,'CB',94),('all',991,'S',87),
('all',992,'QB',71),('all',992,'RB',74),('all',992,'WR',71),('all',992,'TE',84),('all',992,'OL',89),('all',992,'DL',90),('all',992,'LB',86),('all',992,'CB',70),('all',992,'S',78),
('all',993,'QB',86),('all',993,'RB',85),('all',993,'WR',86),('all',993,'TE',84),('all',993,'OL',80),('all',993,'DL',79),('all',993,'LB',80),('all',993,'CB',86),('all',993,'S',83),
('all',994,'QB',93),('all',994,'RB',86),('all',994,'WR',88),('all',994,'TE',81),('all',994,'OL',76),('all',994,'DL',75),('all',994,'LB',79),('all',994,'CB',88),('all',994,'S',84),
('all',995,'QB',77),('all',995,'RB',79),('all',995,'WR',76),('all',995,'TE',86),('all',995,'OL',88),('all',995,'DL',90),('all',995,'LB',87),('all',995,'CB',77),('all',995,'S',83),
('all',996,'QB',56),('all',996,'RB',61),('all',996,'WR',62),('all',996,'TE',61),('all',996,'OL',61),('all',996,'DL',63),('all',996,'LB',61),('all',996,'CB',60),('all',996,'S',59),
('all',997,'QB',65),('all',997,'RB',69),('all',997,'WR',69),('all',997,'TE',71),('all',997,'OL',71),('all',997,'DL',72),('all',997,'LB',71),('all',997,'CB',68),('all',997,'S',69),
('all',998,'QB',79),('all',998,'RB',85),('all',998,'WR',82),('all',998,'TE',88),('all',998,'OL',88),('all',998,'DL',91),('all',998,'LB',89),('all',998,'CB',82),('all',998,'S',85),
('all',999,'QB',64),('all',999,'RB',50),('all',999,'WR',50),('all',999,'TE',53),('all',999,'OL',57),('all',999,'DL',54),('all',999,'LB',54),('all',999,'CB',51),('all',999,'S',54),
('all',1000,'QB',88),('all',1000,'RB',79),('all',1000,'WR',80),('all',1000,'TE',78),('all',1000,'OL',76),('all',1000,'DL',74),('all',1000,'LB',76),('all',1000,'CB',81),('all',1000,'S',80),
('all',1001,'QB',86),('all',1001,'RB',79),('all',1001,'WR',79),('all',1001,'TE',82),('all',1001,'OL',83),('all',1001,'DL',80),('all',1001,'LB',82),('all',1001,'CB',80),('all',1001,'S',85),
('all',1002,'QB',81),('all',1002,'RB',93),('all',1002,'WR',92),('all',1002,'TE',88),('all',1002,'OL',83),('all',1002,'DL',87),('all',1002,'LB',87),('all',1002,'CB',92),('all',1002,'S',87),
('all',1003,'QB',73),('all',1003,'RB',73),('all',1003,'WR',70),('all',1003,'TE',85),('all',1003,'OL',90),('all',1003,'DL',88),('all',1003,'LB',84),('all',1003,'CB',70),('all',1003,'S',79),
('all',1004,'QB',93),('all',1004,'RB',86),('all',1004,'WR',87),('all',1004,'TE',78),('all',1004,'OL',73),('all',1004,'DL',74),('all',1004,'LB',80),('all',1004,'CB',88),('all',1004,'S',86),
('all',1005,'QB',78),('all',1005,'RB',92),('all',1005,'WR',91),('all',1005,'TE',91),('all',1005,'OL',87),('all',1005,'DL',90),('all',1005,'LB',90),('all',1005,'CB',90),('all',1005,'S',89),
('all',1006,'QB',85),('all',1006,'RB',89),('all',1006,'WR',88),('all',1006,'TE',86),('all',1006,'OL',82),('all',1006,'DL',87),('all',1006,'LB',87),('all',1006,'CB',88),('all',1006,'S',86),
('all',1007,'QB',87),('all',1007,'RB',98),('all',1007,'WR',98),('all',1007,'TE',98),('all',1007,'OL',93),('all',1007,'DL',95),('all',1007,'LB',96),('all',1007,'CB',98),('all',1007,'S',97),
('all',1008,'QB',97),('all',1008,'RB',96),('all',1008,'WR',98),('all',1008,'TE',95),('all',1008,'OL',89),('all',1008,'DL',87),('all',1008,'LB',89),('all',1008,'CB',99),('all',1008,'S',95),
('all',1009,'QB',88),('all',1009,'RB',86),('all',1009,'WR',87),('all',1009,'TE',87),('all',1009,'OL',84),('all',1009,'DL',82),('all',1009,'LB',82),('all',1009,'CB',87),('all',1009,'S',84),
('all',1010,'QB',81),('all',1010,'RB',89),('all',1010,'WR',87),('all',1010,'TE',88),('all',1010,'OL',86),('all',1010,'DL',88),('all',1010,'LB',89),('all',1010,'CB',87),('all',1010,'S',88),
('all',1011,'QB',76),('all',1011,'RB',67),('all',1011,'WR',66),('all',1011,'TE',70),('all',1011,'OL',72),('all',1011,'DL',73),('all',1011,'LB',73),('all',1011,'CB',67),('all',1011,'S',72),
('all',1012,'QB',63),('all',1012,'RB',59),('all',1012,'WR',61),('all',1012,'TE',53),('all',1012,'OL',51),('all',1012,'DL',54),('all',1012,'LB',56),('all',1012,'CB',61),('all',1012,'S',58),
('all',1013,'QB',83),('all',1013,'RB',74),('all',1013,'WR',76),('all',1013,'TE',70),('all',1013,'OL',68),('all',1013,'DL',69),('all',1013,'LB',73),('all',1013,'CB',76),('all',1013,'S',76),
('all',1014,'QB',75),('all',1014,'RB',81),('all',1014,'WR',78),('all',1014,'TE',84),('all',1014,'OL',86),('all',1014,'DL',87),('all',1014,'LB',86),('all',1014,'CB',80),('all',1014,'S',84),
('all',1015,'QB',88),('all',1015,'RB',85),('all',1015,'WR',87),('all',1015,'TE',79),('all',1015,'OL',73),('all',1015,'DL',74),('all',1015,'LB',78),('all',1015,'CB',86),('all',1015,'S',82),
('all',1016,'QB',81),('all',1016,'RB',85),('all',1016,'WR',86),('all',1016,'TE',82),('all',1016,'OL',78),('all',1016,'DL',78),('all',1016,'LB',82),('all',1016,'CB',86),('all',1016,'S',86),
('all',1017,'QB',77),('all',1017,'RB',88),('all',1017,'WR',87),('all',1017,'TE',84),('all',1017,'OL',81),('all',1017,'DL',83),('all',1017,'LB',85),('all',1017,'CB',87),('all',1017,'S',86),
('all',1018,'QB',86),('all',1018,'RB',82),('all',1018,'WR',81),('all',1018,'TE',85),('all',1018,'OL',86),('all',1018,'DL',86),('all',1018,'LB',85),('all',1018,'CB',82),('all',1018,'S',84),
('all',1019,'QB',83),('all',1019,'RB',70),('all',1019,'WR',68),('all',1019,'TE',77),('all',1019,'OL',81),('all',1019,'DL',78),('all',1019,'LB',77),('all',1019,'CB',69),('all',1019,'S',75),
('all',1020,'QB',78),('all',1020,'RB',84),('all',1020,'WR',82),('all',1020,'TE',90),('all',1020,'OL',91),('all',1020,'DL',90),('all',1020,'LB',88),('all',1020,'CB',84),('all',1020,'S',87),
('all',1021,'QB',90),('all',1021,'RB',78),('all',1021,'WR',79),('all',1021,'TE',85),('all',1021,'OL',86),('all',1021,'DL',81),('all',1021,'LB',80),('all',1021,'CB',78),('all',1021,'S',80),
('all',1022,'QB',81),('all',1022,'RB',92),('all',1022,'WR',92),('all',1022,'TE',90),('all',1022,'OL',85),('all',1022,'DL',87),('all',1022,'LB',88),('all',1022,'CB',92),('all',1022,'S',90),
('all',1023,'QB',90),('all',1023,'RB',84),('all',1023,'WR',85),('all',1023,'TE',85),('all',1023,'OL',83),('all',1023,'DL',80),('all',1023,'LB',82),('all',1023,'CB',86),('all',1023,'S',86),
('all',1024,'QB',72),('all',1024,'RB',70),('all',1024,'WR',71),('all',1024,'TE',68),('all',1024,'OL',67),('all',1024,'DL',68),('all',1024,'LB',71),('all',1024,'CB',71),('all',1024,'S',72),
('all',1025,'QB',82),('all',1025,'RB',85),('all',1025,'WR',86),('all',1025,'TE',78),('all',1025,'OL',74),('all',1025,'DL',79),('all',1025,'LB',84),('all',1025,'CB',88),('all',1025,'S',88);

insert into public.g151_pokemon (pool, pid, types) values
('gen1',1,array['grass','poison']),('gen1',2,array['grass','poison']),('gen1',3,array['grass','poison']),('gen1',4,array['fire']),('gen1',5,array['fire']),('gen1',6,array['fire','flying']),
('gen1',7,array['water']),('gen1',8,array['water']),('gen1',9,array['water']),('gen1',10,array['bug']),('gen1',11,array['bug']),('gen1',12,array['bug','flying']),
('gen1',13,array['bug','poison']),('gen1',14,array['bug','poison']),('gen1',15,array['bug','poison']),('gen1',16,array['normal','flying']),('gen1',17,array['normal','flying']),('gen1',18,array['normal','flying']),
('gen1',19,array['normal']),('gen1',20,array['normal']),('gen1',21,array['normal','flying']),('gen1',22,array['normal','flying']),('gen1',23,array['poison']),('gen1',24,array['poison']),
('gen1',25,array['electric']),('gen1',26,array['electric']),('gen1',27,array['ground']),('gen1',28,array['ground']),('gen1',29,array['poison']),('gen1',30,array['poison']),
('gen1',31,array['poison','ground']),('gen1',32,array['poison']),('gen1',33,array['poison']),('gen1',34,array['poison','ground']),('gen1',35,array['fairy']),('gen1',36,array['fairy']),
('gen1',37,array['fire']),('gen1',38,array['fire']),('gen1',39,array['normal','fairy']),('gen1',40,array['normal','fairy']),('gen1',41,array['poison','flying']),('gen1',42,array['poison','flying']),
('gen1',43,array['grass','poison']),('gen1',44,array['grass','poison']),('gen1',45,array['grass','poison']),('gen1',46,array['bug','grass']),('gen1',47,array['bug','grass']),('gen1',48,array['bug','poison']),
('gen1',49,array['bug','poison']),('gen1',50,array['ground']),('gen1',51,array['ground']),('gen1',52,array['normal']),('gen1',53,array['normal']),('gen1',54,array['water']),
('gen1',55,array['water']),('gen1',56,array['fighting']),('gen1',57,array['fighting']),('gen1',58,array['fire']),('gen1',59,array['fire']),('gen1',60,array['water']),
('gen1',61,array['water']),('gen1',62,array['water','fighting']),('gen1',63,array['psychic']),('gen1',64,array['psychic']),('gen1',65,array['psychic']),('gen1',66,array['fighting']),
('gen1',67,array['fighting']),('gen1',68,array['fighting']),('gen1',69,array['grass','poison']),('gen1',70,array['grass','poison']),('gen1',71,array['grass','poison']),('gen1',72,array['water','poison']),
('gen1',73,array['water','poison']),('gen1',74,array['rock','ground']),('gen1',75,array['rock','ground']),('gen1',76,array['rock','ground']),('gen1',77,array['fire']),('gen1',78,array['fire']),
('gen1',79,array['water','psychic']),('gen1',80,array['water','psychic']),('gen1',81,array['electric','steel']),('gen1',82,array['electric','steel']),('gen1',83,array['normal','flying']),('gen1',84,array['normal','flying']),
('gen1',85,array['normal','flying']),('gen1',86,array['water']),('gen1',87,array['water','ice']),('gen1',88,array['poison']),('gen1',89,array['poison']),('gen1',90,array['water']),
('gen1',91,array['water','ice']),('gen1',92,array['ghost','poison']),('gen1',93,array['ghost','poison']),('gen1',94,array['ghost','poison']),('gen1',95,array['rock','ground']),('gen1',96,array['psychic']),
('gen1',97,array['psychic']),('gen1',98,array['water']),('gen1',99,array['water']),('gen1',100,array['electric']),('gen1',101,array['electric']),('gen1',102,array['grass','psychic']),
('gen1',103,array['grass','psychic']),('gen1',104,array['ground']),('gen1',105,array['ground']),('gen1',106,array['fighting']),('gen1',107,array['fighting']),('gen1',108,array['normal']),
('gen1',109,array['poison']),('gen1',110,array['poison']),('gen1',111,array['ground','rock']),('gen1',112,array['ground','rock']),('gen1',113,array['normal']),('gen1',114,array['grass']),
('gen1',115,array['normal']),('gen1',116,array['water']),('gen1',117,array['water']),('gen1',118,array['water']),('gen1',119,array['water']),('gen1',120,array['water']),
('gen1',121,array['water','psychic']),('gen1',122,array['psychic','fairy']),('gen1',123,array['bug','flying']),('gen1',124,array['ice','psychic']),('gen1',125,array['electric']),('gen1',126,array['fire']),
('gen1',127,array['bug']),('gen1',128,array['normal']),('gen1',129,array['water']),('gen1',130,array['water','flying']),('gen1',131,array['water','ice']),('gen1',132,array['normal']),
('gen1',133,array['normal']),('gen1',134,array['water']),('gen1',135,array['electric']),('gen1',136,array['fire']),('gen1',137,array['normal']),('gen1',138,array['rock','water']),
('gen1',139,array['rock','water']),('gen1',140,array['rock','water']),('gen1',141,array['rock','water']),('gen1',142,array['rock','flying']),('gen1',143,array['normal']),('gen1',144,array['ice','flying']),
('gen1',145,array['electric','flying']),('gen1',146,array['fire','flying']),('gen1',147,array['dragon']),('gen1',148,array['dragon']),('gen1',149,array['dragon','flying']),('gen1',151,array['psychic']),
('all',1,array['grass','poison']),('all',2,array['grass','poison']),('all',3,array['grass','poison']),('all',4,array['fire']),('all',5,array['fire']),('all',6,array['fire','flying']),
('all',7,array['water']),('all',8,array['water']),('all',9,array['water']),('all',10,array['bug']),('all',11,array['bug']),('all',12,array['bug','flying']),
('all',13,array['bug','poison']),('all',14,array['bug','poison']),('all',15,array['bug','poison']),('all',16,array['normal','flying']),('all',17,array['normal','flying']),('all',18,array['normal','flying']),
('all',19,array['normal']),('all',20,array['normal']),('all',21,array['normal','flying']),('all',22,array['normal','flying']),('all',23,array['poison']),('all',24,array['poison']),
('all',25,array['electric']),('all',26,array['electric']),('all',27,array['ground']),('all',28,array['ground']),('all',29,array['poison']),('all',30,array['poison']),
('all',31,array['poison','ground']),('all',32,array['poison']),('all',33,array['poison']),('all',34,array['poison','ground']),('all',35,array['fairy']),('all',36,array['fairy']),
('all',37,array['fire']),('all',38,array['fire']),('all',39,array['normal','fairy']),('all',40,array['normal','fairy']),('all',41,array['poison','flying']),('all',42,array['poison','flying']),
('all',43,array['grass','poison']),('all',44,array['grass','poison']),('all',45,array['grass','poison']),('all',46,array['bug','grass']),('all',47,array['bug','grass']),('all',48,array['bug','poison']),
('all',49,array['bug','poison']),('all',50,array['ground']),('all',51,array['ground']),('all',52,array['normal']),('all',53,array['normal']),('all',54,array['water']),
('all',55,array['water']),('all',56,array['fighting']),('all',57,array['fighting']),('all',58,array['fire']),('all',59,array['fire']),('all',60,array['water']),
('all',61,array['water']),('all',62,array['water','fighting']),('all',63,array['psychic']),('all',64,array['psychic']),('all',65,array['psychic']),('all',66,array['fighting']),
('all',67,array['fighting']),('all',68,array['fighting']),('all',69,array['grass','poison']),('all',70,array['grass','poison']),('all',71,array['grass','poison']),('all',72,array['water','poison']),
('all',73,array['water','poison']),('all',74,array['rock','ground']),('all',75,array['rock','ground']),('all',76,array['rock','ground']),('all',77,array['fire']),('all',78,array['fire']),
('all',79,array['water','psychic']),('all',80,array['water','psychic']),('all',81,array['electric','steel']),('all',82,array['electric','steel']),('all',83,array['normal','flying']),('all',84,array['normal','flying']),
('all',85,array['normal','flying']),('all',86,array['water']),('all',87,array['water','ice']),('all',88,array['poison']),('all',89,array['poison']),('all',90,array['water']),
('all',91,array['water','ice']),('all',92,array['ghost','poison']),('all',93,array['ghost','poison']),('all',94,array['ghost','poison']),('all',95,array['rock','ground']),('all',96,array['psychic']),
('all',97,array['psychic']),('all',98,array['water']),('all',99,array['water']),('all',100,array['electric']),('all',101,array['electric']),('all',102,array['grass','psychic']),
('all',103,array['grass','psychic']),('all',104,array['ground']),('all',105,array['ground']),('all',106,array['fighting']),('all',107,array['fighting']),('all',108,array['normal']),
('all',109,array['poison']),('all',110,array['poison']),('all',111,array['ground','rock']),('all',112,array['ground','rock']),('all',113,array['normal']),('all',114,array['grass']),
('all',115,array['normal']),('all',116,array['water']),('all',117,array['water']),('all',118,array['water']),('all',119,array['water']),('all',120,array['water']),
('all',121,array['water','psychic']),('all',122,array['psychic','fairy']),('all',123,array['bug','flying']),('all',124,array['ice','psychic']),('all',125,array['electric']),('all',126,array['fire']),
('all',127,array['bug']),('all',128,array['normal']),('all',129,array['water']),('all',130,array['water','flying']),('all',131,array['water','ice']),('all',132,array['normal']),
('all',133,array['normal']),('all',134,array['water']),('all',135,array['electric']),('all',136,array['fire']),('all',137,array['normal']),('all',138,array['rock','water']),
('all',139,array['rock','water']),('all',140,array['rock','water']),('all',141,array['rock','water']),('all',142,array['rock','flying']),('all',143,array['normal']),('all',144,array['ice','flying']),
('all',145,array['electric','flying']),('all',146,array['fire','flying']),('all',147,array['dragon']),('all',148,array['dragon']),('all',149,array['dragon','flying']),('all',151,array['psychic']),
('all',152,array['grass']),('all',153,array['grass']),('all',154,array['grass']),('all',155,array['fire']),('all',156,array['fire']),('all',157,array['fire']),
('all',158,array['water']),('all',159,array['water']),('all',160,array['water']),('all',161,array['normal']),('all',162,array['normal']),('all',163,array['normal','flying']),
('all',164,array['normal','flying']),('all',165,array['bug','flying']),('all',166,array['bug','flying']),('all',167,array['bug','poison']),('all',168,array['bug','poison']),('all',169,array['poison','flying']),
('all',170,array['water','electric']),('all',171,array['water','electric']),('all',172,array['electric']),('all',173,array['fairy']),('all',174,array['normal','fairy']),('all',175,array['fairy']),
('all',176,array['fairy','flying']),('all',177,array['psychic','flying']),('all',178,array['psychic','flying']),('all',179,array['electric']),('all',180,array['electric']),('all',181,array['electric']),
('all',182,array['grass']),('all',183,array['water','fairy']),('all',184,array['water','fairy']),('all',185,array['rock']),('all',186,array['water']),('all',187,array['grass','flying']),
('all',188,array['grass','flying']),('all',189,array['grass','flying']),('all',190,array['normal']),('all',191,array['grass']),('all',192,array['grass']),('all',193,array['bug','flying']),
('all',194,array['water','ground']),('all',195,array['water','ground']),('all',196,array['psychic']),('all',197,array['dark']),('all',198,array['dark','flying']),('all',199,array['water','psychic']),
('all',200,array['ghost']),('all',201,array['psychic']),('all',202,array['psychic']),('all',203,array['normal','psychic']),('all',204,array['bug']),('all',205,array['bug','steel']),
('all',206,array['normal']),('all',207,array['ground','flying']),('all',208,array['steel','ground']),('all',209,array['fairy']),('all',210,array['fairy']),('all',211,array['water','poison']),
('all',212,array['bug','steel']),('all',213,array['bug','rock']),('all',214,array['bug','fighting']),('all',215,array['dark','ice']),('all',216,array['normal']),('all',217,array['normal']),
('all',218,array['fire']),('all',219,array['fire','rock']),('all',220,array['ice','ground']),('all',221,array['ice','ground']),('all',222,array['water','rock']),('all',223,array['water']),
('all',224,array['water']),('all',225,array['ice','flying']),('all',226,array['water','flying']),('all',227,array['steel','flying']),('all',228,array['dark','fire']),('all',229,array['dark','fire']),
('all',230,array['water','dragon']),('all',231,array['ground']),('all',232,array['ground']),('all',233,array['normal']),('all',234,array['normal']),('all',235,array['normal']),
('all',236,array['fighting']),('all',237,array['fighting']),('all',238,array['ice','psychic']),('all',239,array['electric']),('all',240,array['fire']),('all',241,array['normal']),
('all',242,array['normal']),('all',243,array['electric']),('all',244,array['fire']),('all',245,array['water']),('all',246,array['rock','ground']),('all',247,array['rock','ground']),
('all',248,array['rock','dark']),('all',249,array['psychic','flying']),('all',250,array['fire','flying']),('all',251,array['psychic','grass']),('all',252,array['grass']),('all',253,array['grass']),
('all',254,array['grass']),('all',255,array['fire']),('all',256,array['fire','fighting']),('all',257,array['fire','fighting']),('all',258,array['water']),('all',259,array['water','ground']),
('all',260,array['water','ground']),('all',261,array['dark']),('all',262,array['dark']),('all',263,array['normal']),('all',264,array['normal']),('all',265,array['bug']),
('all',266,array['bug']),('all',267,array['bug','flying']),('all',268,array['bug']),('all',269,array['bug','poison']),('all',270,array['water','grass']),('all',271,array['water','grass']),
('all',272,array['water','grass']),('all',273,array['grass']),('all',274,array['grass','dark']),('all',275,array['grass','dark']),('all',276,array['normal','flying']),('all',277,array['normal','flying']),
('all',278,array['water','flying']),('all',279,array['water','flying']),('all',280,array['psychic','fairy']),('all',281,array['psychic','fairy']),('all',282,array['psychic','fairy']),('all',283,array['bug','water']),
('all',284,array['bug','flying']),('all',285,array['grass']),('all',286,array['grass','fighting']),('all',287,array['normal']),('all',288,array['normal']),('all',289,array['normal']),
('all',290,array['bug','ground']),('all',291,array['bug','flying']),('all',292,array['bug','ghost']),('all',293,array['normal']),('all',294,array['normal']),('all',295,array['normal']),
('all',296,array['fighting']),('all',297,array['fighting']),('all',298,array['normal','fairy']),('all',299,array['rock']),('all',300,array['normal']),('all',301,array['normal']),
('all',302,array['dark','ghost']),('all',303,array['steel','fairy']),('all',304,array['steel','rock']),('all',305,array['steel','rock']),('all',306,array['steel','rock']),('all',307,array['fighting','psychic']),
('all',308,array['fighting','psychic']),('all',309,array['electric']),('all',310,array['electric']),('all',311,array['electric']),('all',312,array['electric']),('all',313,array['bug']),
('all',314,array['bug']),('all',315,array['grass','poison']),('all',316,array['poison']),('all',317,array['poison']),('all',318,array['water','dark']),('all',319,array['water','dark']),
('all',320,array['water']),('all',321,array['water']),('all',322,array['fire','ground']),('all',323,array['fire','ground']),('all',324,array['fire']),('all',325,array['psychic']),
('all',326,array['psychic']),('all',327,array['normal']),('all',328,array['ground']),('all',329,array['ground','dragon']),('all',330,array['ground','dragon']),('all',331,array['grass']),
('all',332,array['grass','dark']),('all',333,array['normal','flying']),('all',334,array['dragon','flying']),('all',335,array['normal']),('all',336,array['poison']),('all',337,array['rock','psychic']),
('all',338,array['rock','psychic']),('all',339,array['water','ground']),('all',340,array['water','ground']),('all',341,array['water']),('all',342,array['water','dark']),('all',343,array['ground','psychic']),
('all',344,array['ground','psychic']),('all',345,array['rock','grass']),('all',346,array['rock','grass']),('all',347,array['rock','bug']),('all',348,array['rock','bug']),('all',349,array['water']),
('all',350,array['water']),('all',351,array['normal']),('all',352,array['normal']),('all',353,array['ghost']),('all',354,array['ghost']),('all',355,array['ghost']),
('all',356,array['ghost']),('all',357,array['grass','flying']),('all',358,array['psychic']),('all',359,array['dark']),('all',360,array['psychic']),('all',361,array['ice']),
('all',362,array['ice']),('all',363,array['ice','water']),('all',364,array['ice','water']),('all',365,array['ice','water']),('all',366,array['water']),('all',367,array['water']),
('all',368,array['water']),('all',369,array['water','rock']),('all',370,array['water']),('all',371,array['dragon']),('all',372,array['dragon']),('all',373,array['dragon','flying']),
('all',374,array['steel','psychic']),('all',375,array['steel','psychic']),('all',376,array['steel','psychic']),('all',377,array['rock']),('all',378,array['ice']),('all',379,array['steel']),
('all',380,array['dragon','psychic']),('all',381,array['dragon','psychic']),('all',382,array['water']),('all',383,array['ground']),('all',384,array['dragon','flying']),('all',385,array['steel','psychic']),
('all',386,array['psychic']),('all',387,array['grass']),('all',388,array['grass']),('all',389,array['grass','ground']),('all',390,array['fire']),('all',391,array['fire','fighting']),
('all',392,array['fire','fighting']),('all',393,array['water']),('all',394,array['water']),('all',395,array['water','steel']),('all',396,array['normal','flying']),('all',397,array['normal','flying']),
('all',398,array['normal','flying']),('all',399,array['normal']),('all',400,array['normal','water']),('all',401,array['bug']),('all',402,array['bug']),('all',403,array['electric']),
('all',404,array['electric']),('all',405,array['electric']),('all',406,array['grass','poison']),('all',407,array['grass','poison']),('all',408,array['rock']),('all',409,array['rock']),
('all',410,array['rock','steel']),('all',411,array['rock','steel']),('all',412,array['bug']),('all',413,array['bug','grass']),('all',414,array['bug','flying']),('all',415,array['bug','flying']),
('all',416,array['bug','flying']),('all',417,array['electric']),('all',418,array['water']),('all',419,array['water']),('all',420,array['grass']),('all',421,array['grass']),
('all',422,array['water']),('all',423,array['water','ground']),('all',424,array['normal']),('all',425,array['ghost','flying']),('all',426,array['ghost','flying']),('all',427,array['normal']),
('all',428,array['normal']),('all',429,array['ghost']),('all',430,array['dark','flying']),('all',431,array['normal']),('all',432,array['normal']),('all',433,array['psychic']),
('all',434,array['poison','dark']),('all',435,array['poison','dark']),('all',436,array['steel','psychic']),('all',437,array['steel','psychic']),('all',438,array['rock']),('all',439,array['psychic','fairy']),
('all',440,array['normal']),('all',441,array['normal','flying']),('all',442,array['ghost','dark']),('all',443,array['dragon','ground']),('all',444,array['dragon','ground']),('all',445,array['dragon','ground']),
('all',446,array['normal']),('all',447,array['fighting']),('all',448,array['fighting','steel']),('all',449,array['ground']),('all',450,array['ground']),('all',451,array['poison','bug']),
('all',452,array['poison','dark']),('all',453,array['poison','fighting']),('all',454,array['poison','fighting']),('all',455,array['grass']),('all',456,array['water']),('all',457,array['water']),
('all',458,array['water','flying']),('all',459,array['grass','ice']),('all',460,array['grass','ice']),('all',461,array['dark','ice']),('all',462,array['electric','steel']),('all',463,array['normal']),
('all',464,array['ground','rock']),('all',465,array['grass']),('all',466,array['electric']),('all',467,array['fire']),('all',468,array['fairy','flying']),('all',469,array['bug','flying']),
('all',470,array['grass']),('all',471,array['ice']),('all',472,array['ground','flying']),('all',473,array['ice','ground']),('all',474,array['normal']),('all',475,array['psychic','fighting']),
('all',476,array['rock','steel']),('all',477,array['ghost']),('all',478,array['ice','ghost']),('all',479,array['electric','ghost']),('all',480,array['psychic']),('all',481,array['psychic']),
('all',482,array['psychic']),('all',483,array['steel','dragon']),('all',484,array['water','dragon']),('all',485,array['fire','steel']),('all',486,array['normal']),('all',487,array['ghost','dragon']),
('all',488,array['psychic']),('all',489,array['water']),('all',490,array['water']),('all',491,array['dark']),('all',492,array['grass']),('all',493,array['normal']),
('all',494,array['psychic','fire']),('all',495,array['grass']),('all',496,array['grass']),('all',497,array['grass']),('all',498,array['fire']),('all',499,array['fire','fighting']),
('all',500,array['fire','fighting']),('all',501,array['water']),('all',502,array['water']),('all',503,array['water']),('all',504,array['normal']),('all',505,array['normal']),
('all',506,array['normal']),('all',507,array['normal']),('all',508,array['normal']),('all',509,array['dark']),('all',510,array['dark']),('all',511,array['grass']),
('all',512,array['grass']),('all',513,array['fire']),('all',514,array['fire']),('all',515,array['water']),('all',516,array['water']),('all',517,array['psychic']),
('all',518,array['psychic']),('all',519,array['normal','flying']),('all',520,array['normal','flying']),('all',521,array['normal','flying']),('all',522,array['electric']),('all',523,array['electric']),
('all',524,array['rock']),('all',525,array['rock']),('all',526,array['rock']),('all',527,array['psychic','flying']),('all',528,array['psychic','flying']),('all',529,array['ground']),
('all',530,array['ground','steel']),('all',531,array['normal']),('all',532,array['fighting']),('all',533,array['fighting']),('all',534,array['fighting']),('all',535,array['water']),
('all',536,array['water','ground']),('all',537,array['water','ground']),('all',538,array['fighting']),('all',539,array['fighting']),('all',540,array['bug','grass']),('all',541,array['bug','grass']),
('all',542,array['bug','grass']),('all',543,array['bug','poison']),('all',544,array['bug','poison']),('all',545,array['bug','poison']),('all',546,array['grass','fairy']),('all',547,array['grass','fairy']),
('all',548,array['grass']),('all',549,array['grass']),('all',550,array['water']),('all',551,array['ground','dark']),('all',552,array['ground','dark']),('all',553,array['ground','dark']),
('all',554,array['fire']),('all',555,array['fire']),('all',556,array['grass']),('all',557,array['bug','rock']),('all',558,array['bug','rock']),('all',559,array['dark','fighting']),
('all',560,array['dark','fighting']),('all',561,array['psychic','flying']),('all',562,array['ghost']),('all',563,array['ghost']),('all',564,array['water','rock']),('all',565,array['water','rock']),
('all',566,array['rock','flying']),('all',567,array['rock','flying']),('all',568,array['poison']),('all',569,array['poison']),('all',570,array['dark']),('all',571,array['dark']),
('all',572,array['normal']),('all',573,array['normal']),('all',574,array['psychic']),('all',575,array['psychic']),('all',576,array['psychic']),('all',577,array['psychic']),
('all',578,array['psychic']),('all',579,array['psychic']),('all',580,array['water','flying']),('all',581,array['water','flying']),('all',582,array['ice']),('all',583,array['ice']),
('all',584,array['ice']),('all',585,array['normal','grass']),('all',586,array['normal','grass']),('all',587,array['electric','flying']),('all',588,array['bug']),('all',589,array['bug','steel']),
('all',590,array['grass','poison']),('all',591,array['grass','poison']),('all',592,array['water','ghost']),('all',593,array['water','ghost']),('all',594,array['water']),('all',595,array['bug','electric']),
('all',596,array['bug','electric']),('all',597,array['grass','steel']),('all',598,array['grass','steel']),('all',599,array['steel']),('all',600,array['steel']),('all',601,array['steel']),
('all',602,array['electric']),('all',603,array['electric']),('all',604,array['electric']),('all',605,array['psychic']),('all',606,array['psychic']),('all',607,array['ghost','fire']),
('all',608,array['ghost','fire']),('all',609,array['ghost','fire']),('all',610,array['dragon']),('all',611,array['dragon']),('all',612,array['dragon']),('all',613,array['ice']),
('all',614,array['ice']),('all',615,array['ice']),('all',616,array['bug']),('all',617,array['bug']),('all',618,array['ground','electric']),('all',619,array['fighting']),
('all',620,array['fighting']),('all',621,array['dragon']),('all',622,array['ground','ghost']),('all',623,array['ground','ghost']),('all',624,array['dark','steel']),('all',625,array['dark','steel']),
('all',626,array['normal']),('all',627,array['normal','flying']),('all',628,array['normal','flying']),('all',629,array['dark','flying']),('all',630,array['dark','flying']),('all',631,array['fire']),
('all',632,array['bug','steel']),('all',633,array['dark','dragon']),('all',634,array['dark','dragon']),('all',635,array['dark','dragon']),('all',636,array['bug','fire']),('all',637,array['bug','fire']),
('all',638,array['steel','fighting']),('all',639,array['rock','fighting']),('all',640,array['grass','fighting']),('all',641,array['flying']),('all',642,array['electric','flying']),('all',643,array['dragon','fire']),
('all',644,array['dragon','electric']),('all',645,array['ground','flying']),('all',646,array['dragon','ice']),('all',647,array['water','fighting']),('all',648,array['normal','psychic']),('all',649,array['bug','steel']),
('all',650,array['grass']),('all',651,array['grass']),('all',652,array['grass','fighting']),('all',653,array['fire']),('all',654,array['fire']),('all',655,array['fire','psychic']),
('all',656,array['water']),('all',657,array['water']),('all',658,array['water','dark']),('all',659,array['normal']),('all',660,array['normal','ground']),('all',661,array['normal','flying']),
('all',662,array['fire','flying']),('all',663,array['fire','flying']),('all',664,array['bug']),('all',665,array['bug']),('all',666,array['bug','flying']),('all',667,array['fire','normal']),
('all',668,array['fire','normal']),('all',669,array['fairy']),('all',670,array['fairy']),('all',671,array['fairy']),('all',672,array['grass']),('all',673,array['grass']),
('all',674,array['fighting']),('all',675,array['fighting','dark']),('all',676,array['normal']),('all',677,array['psychic']),('all',678,array['psychic']),('all',679,array['steel','ghost']),
('all',680,array['steel','ghost']),('all',681,array['steel','ghost']),('all',682,array['fairy']),('all',683,array['fairy']),('all',684,array['fairy']),('all',685,array['fairy']),
('all',686,array['dark','psychic']),('all',687,array['dark','psychic']),('all',688,array['rock','water']),('all',689,array['rock','water']),('all',690,array['poison','water']),('all',691,array['poison','dragon']),
('all',692,array['water']),('all',693,array['water']),('all',694,array['electric','normal']),('all',695,array['electric','normal']),('all',696,array['rock','dragon']),('all',697,array['rock','dragon']),
('all',698,array['rock','ice']),('all',699,array['rock','ice']),('all',700,array['fairy']),('all',701,array['fighting','flying']),('all',702,array['electric','fairy']),('all',703,array['rock','fairy']),
('all',704,array['dragon']),('all',705,array['dragon']),('all',706,array['dragon']),('all',707,array['steel','fairy']),('all',708,array['ghost','grass']),('all',709,array['ghost','grass']),
('all',710,array['ghost','grass']),('all',711,array['ghost','grass']),('all',712,array['ice']),('all',713,array['ice']),('all',714,array['flying','dragon']),('all',715,array['flying','dragon']),
('all',716,array['fairy']),('all',717,array['dark','flying']),('all',718,array['dragon','ground']),('all',719,array['rock','fairy']),('all',720,array['psychic','ghost']),('all',721,array['fire','water']),
('all',722,array['grass','flying']),('all',723,array['grass','flying']),('all',724,array['grass','ghost']),('all',725,array['fire']),('all',726,array['fire']),('all',727,array['fire','dark']),
('all',728,array['water']),('all',729,array['water']),('all',730,array['water','fairy']),('all',731,array['normal','flying']),('all',732,array['normal','flying']),('all',733,array['normal','flying']),
('all',734,array['normal']),('all',735,array['normal']),('all',736,array['bug']),('all',737,array['bug','electric']),('all',738,array['bug','electric']),('all',739,array['fighting']),
('all',740,array['fighting','ice']),('all',741,array['fire','flying']),('all',742,array['bug','fairy']),('all',743,array['bug','fairy']),('all',744,array['rock']),('all',745,array['rock']),
('all',746,array['water']),('all',747,array['poison','water']),('all',748,array['poison','water']),('all',749,array['ground']),('all',750,array['ground']),('all',751,array['water','bug']),
('all',752,array['water','bug']),('all',753,array['grass']),('all',754,array['grass']),('all',755,array['grass','fairy']),('all',756,array['grass','fairy']),('all',757,array['poison','fire']),
('all',758,array['poison','fire']),('all',759,array['normal','fighting']),('all',760,array['normal','fighting']),('all',761,array['grass']),('all',762,array['grass']),('all',763,array['grass']),
('all',764,array['fairy']),('all',765,array['normal','psychic']),('all',766,array['fighting']),('all',767,array['bug','water']),('all',768,array['bug','water']),('all',769,array['ghost','ground']),
('all',770,array['ghost','ground']),('all',771,array['water']),('all',772,array['normal']),('all',773,array['normal']),('all',774,array['rock','flying']),('all',775,array['normal']),
('all',776,array['fire','dragon']),('all',777,array['electric','steel']),('all',778,array['ghost','fairy']),('all',779,array['water','psychic']),('all',780,array['normal','dragon']),('all',781,array['ghost','grass']),
('all',782,array['dragon']),('all',783,array['dragon','fighting']),('all',784,array['dragon','fighting']),('all',785,array['electric','fairy']),('all',786,array['psychic','fairy']),('all',787,array['grass','fairy']),
('all',788,array['water','fairy']),('all',789,array['psychic']),('all',790,array['psychic']),('all',791,array['psychic','steel']),('all',792,array['psychic','ghost']),('all',793,array['rock','poison']),
('all',794,array['bug','fighting']),('all',795,array['bug','fighting']),('all',796,array['electric']),('all',797,array['steel','flying']),('all',798,array['grass','steel']),('all',799,array['dark','dragon']),
('all',800,array['psychic']),('all',801,array['steel','fairy']),('all',802,array['fighting','ghost']),('all',803,array['poison']),('all',804,array['poison','dragon']),('all',805,array['rock','steel']),
('all',806,array['fire','ghost']),('all',807,array['electric']),('all',808,array['steel']),('all',809,array['steel']),('all',810,array['grass']),('all',811,array['grass']),
('all',812,array['grass']),('all',813,array['fire']),('all',814,array['fire']),('all',815,array['fire']),('all',816,array['water']),('all',817,array['water']),
('all',818,array['water']),('all',819,array['normal']),('all',820,array['normal']),('all',821,array['flying']),('all',822,array['flying']),('all',823,array['flying','steel']),
('all',824,array['bug']),('all',825,array['bug','psychic']),('all',826,array['bug','psychic']),('all',827,array['dark']),('all',828,array['dark']),('all',829,array['grass']),
('all',830,array['grass']),('all',831,array['normal']),('all',832,array['normal']),('all',833,array['water']),('all',834,array['water','rock']),('all',835,array['electric']),
('all',836,array['electric']),('all',837,array['rock']),('all',838,array['rock','fire']),('all',839,array['rock','fire']),('all',840,array['grass','dragon']),('all',841,array['grass','dragon']),
('all',842,array['grass','dragon']),('all',843,array['ground']),('all',844,array['ground']),('all',845,array['flying','water']),('all',846,array['water']),('all',847,array['water']),
('all',848,array['electric','poison']),('all',849,array['electric','poison']),('all',850,array['fire','bug']),('all',851,array['fire','bug']),('all',852,array['fighting']),('all',853,array['fighting']),
('all',854,array['ghost']),('all',855,array['ghost']),('all',856,array['psychic']),('all',857,array['psychic']),('all',858,array['psychic','fairy']),('all',859,array['dark','fairy']),
('all',860,array['dark','fairy']),('all',861,array['dark','fairy']),('all',862,array['dark','normal']),('all',863,array['steel']),('all',864,array['ghost']),('all',865,array['fighting']),
('all',866,array['ice','psychic']),('all',867,array['ground','ghost']),('all',868,array['fairy']),('all',869,array['fairy']),('all',870,array['fighting']),('all',871,array['electric']),
('all',872,array['ice','bug']),('all',873,array['ice','bug']),('all',874,array['rock']),('all',875,array['ice']),('all',876,array['psychic','normal']),('all',877,array['electric','dark']),
('all',878,array['steel']),('all',879,array['steel']),('all',880,array['electric','dragon']),('all',881,array['electric','ice']),('all',882,array['water','dragon']),('all',883,array['water','ice']),
('all',884,array['steel','dragon']),('all',885,array['dragon','ghost']),('all',886,array['dragon','ghost']),('all',887,array['dragon','ghost']),('all',888,array['fairy']),('all',889,array['fighting']),
('all',890,array['poison','dragon']),('all',891,array['fighting']),('all',892,array['fighting','dark']),('all',893,array['dark','grass']),('all',894,array['electric']),('all',895,array['dragon']),
('all',896,array['ice']),('all',897,array['ghost']),('all',898,array['psychic','grass']),('all',899,array['normal','psychic']),('all',900,array['bug','rock']),('all',901,array['ground','normal']),
('all',902,array['water','ghost']),('all',903,array['fighting','poison']),('all',904,array['dark','poison']),('all',905,array['fairy','flying']),('all',906,array['grass']),('all',907,array['grass']),
('all',908,array['grass','dark']),('all',909,array['fire']),('all',910,array['fire']),('all',911,array['fire','ghost']),('all',912,array['water']),('all',913,array['water']),
('all',914,array['water','fighting']),('all',915,array['normal']),('all',916,array['normal']),('all',917,array['bug']),('all',918,array['bug']),('all',919,array['bug']),
('all',920,array['bug','dark']),('all',921,array['electric']),('all',922,array['electric','fighting']),('all',923,array['electric','fighting']),('all',924,array['normal']),('all',925,array['normal']),
('all',926,array['fairy']),('all',927,array['fairy']),('all',928,array['grass','normal']),('all',929,array['grass','normal']),('all',930,array['grass','normal']),('all',931,array['normal','flying']),
('all',932,array['rock']),('all',933,array['rock']),('all',934,array['rock']),('all',935,array['fire']),('all',936,array['fire','psychic']),('all',937,array['fire','ghost']),
('all',938,array['electric']),('all',939,array['electric']),('all',940,array['electric','flying']),('all',941,array['electric','flying']),('all',942,array['dark']),('all',943,array['dark']),
('all',944,array['poison','normal']),('all',945,array['poison','normal']),('all',946,array['grass','ghost']),('all',947,array['grass','ghost']),('all',948,array['ground','grass']),('all',949,array['ground','grass']),
('all',950,array['rock']),('all',951,array['grass']),('all',952,array['grass','fire']),('all',953,array['bug']),('all',954,array['bug','psychic']),('all',955,array['psychic']),
('all',956,array['psychic']),('all',957,array['fairy','steel']),('all',958,array['fairy','steel']),('all',959,array['fairy','steel']),('all',960,array['water']),('all',961,array['water']),
('all',962,array['flying','dark']),('all',963,array['water']),('all',964,array['water']),('all',965,array['steel','poison']),('all',966,array['steel','poison']),('all',967,array['dragon','normal']),
('all',968,array['steel']),('all',969,array['rock','poison']),('all',970,array['rock','poison']),('all',971,array['ghost']),('all',972,array['ghost']),('all',973,array['flying','fighting']),
('all',974,array['ice']),('all',975,array['ice']),('all',976,array['water','psychic']),('all',977,array['water']),('all',978,array['dragon','water']),('all',979,array['fighting','ghost']),
('all',980,array['poison','ground']),('all',981,array['normal','psychic']),('all',982,array['normal']),('all',983,array['dark','steel']),('all',984,array['ground','fighting']),('all',985,array['fairy','psychic']),
('all',986,array['grass','dark']),('all',987,array['ghost','fairy']),('all',988,array['bug','fighting']),('all',989,array['electric','ground']),('all',990,array['ground','steel']),('all',991,array['ice','water']),
('all',992,array['fighting','electric']),('all',993,array['dark','flying']),('all',994,array['fire','poison']),('all',995,array['rock','electric']),('all',996,array['dragon','ice']),('all',997,array['dragon','ice']),
('all',998,array['dragon','ice']),('all',999,array['ghost']),('all',1000,array['steel','ghost']),('all',1001,array['dark','grass']),('all',1002,array['dark','ice']),('all',1003,array['dark','ground']),
('all',1004,array['dark','fire']),('all',1005,array['dragon','dark']),('all',1006,array['fairy','fighting']),('all',1007,array['fighting','dragon']),('all',1008,array['electric','dragon']),('all',1009,array['water','dragon']),
('all',1010,array['grass','psychic']),('all',1011,array['grass','dragon']),('all',1012,array['grass','ghost']),('all',1013,array['grass','ghost']),('all',1014,array['poison','fighting']),('all',1015,array['poison','psychic']),
('all',1016,array['poison','fairy']),('all',1017,array['grass']),('all',1018,array['steel','dragon']),('all',1019,array['grass','dragon']),('all',1020,array['fire','dragon']),('all',1021,array['electric','dragon']),
('all',1022,array['rock','psychic']),('all',1023,array['steel','psychic']),('all',1024,array['normal']),('all',1025,array['poison','ghost']);

analyze public.g151_ratings;
analyze public.g151_pokemon;
