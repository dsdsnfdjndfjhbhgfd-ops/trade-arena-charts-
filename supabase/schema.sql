-- =====================================================================
--  Трейд Арена — схема базы данных для Supabase
--  Как применить: Supabase → SQL Editor → New query → вставить весь файл → Run.
--  Скрипт можно запускать повторно: он пересоздаёт функции и политики.
-- =====================================================================

-- ---------- Профили игроков ----------
create table if not exists public.profiles (
  id          uuid primary key references auth.users(id) on delete cascade,
  username    text not null check (char_length(username) between 3 and 20
                                   and username ~ '^[A-Za-z0-9_А-Яа-яЁё]+$'),
  created_at  timestamptz not null default now()
);
create unique index if not exists profiles_username_lower on public.profiles (lower(username));

-- Профиль создаётся автоматически при регистрации; ник берётся из метаданных.
create or replace function public.handle_new_user()
returns trigger language plpgsql security definer set search_path = public as $$
declare
  base text;
  candidate text;
  n int := 0;
begin
  base := regexp_replace(coalesce(new.raw_user_meta_data->>'username', ''), '[^A-Za-z0-9_А-Яа-яЁё]', '', 'g');
  base := left(base, 16);
  if char_length(base) < 3 then base := 'trader'; end if;
  candidate := base;
  while exists (select 1 from public.profiles where lower(username) = lower(candidate)) loop
    n := n + 1;
    candidate := base || n;
  end loop;
  insert into public.profiles (id, username) values (new.id, candidate);
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- Соревнования ----------
create table if not exists public.competitions (
  id             uuid primary key default gen_random_uuid(),
  title          text not null check (char_length(title) between 3 and 60),
  created_by     uuid not null references public.profiles(id) on delete cascade,
  symbols        text[] not null check (cardinality(symbols) between 1 and 8),
  start_balance  numeric not null check (start_balance between 100 and 1000000),
  starts_at      timestamptz not null,
  ends_at        timestamptz not null,
  created_at     timestamptz not null default now(),
  check (ends_at > starts_at and ends_at - starts_at <= interval '30 days')
);
create index if not exists competitions_ends_at on public.competitions (ends_at desc);
-- тип: обычное соревнование или схватка 1 на 1
alter table public.competitions add column if not exists kind text not null default 'tournament';
do $$ begin
  alter table public.competitions add constraint competitions_kind_check check (kind in ('tournament','duel'));
exception when duplicate_object then null; end $$;

create table if not exists public.participants (
  competition_id uuid not null references public.competitions(id) on delete cascade,
  user_id        uuid not null references public.profiles(id) on delete cascade,
  cash           numeric not null check (cash >= 0),
  joined_at      timestamptz not null default now(),
  primary key (competition_id, user_id)
);
create index if not exists participants_user on public.participants (user_id);

create table if not exists public.positions (
  competition_id uuid not null,
  user_id        uuid not null,
  symbol         text not null,
  qty            numeric not null check (qty > 0),
  avg_price      numeric not null check (avg_price > 0),
  primary key (competition_id, user_id, symbol),
  foreign key (competition_id, user_id) references public.participants(competition_id, user_id) on delete cascade
);

create table if not exists public.trades (
  id             bigint generated always as identity primary key,
  competition_id uuid not null,
  user_id        uuid not null,
  symbol         text not null,
  side           text not null check (side in ('buy','sell')),
  qty            numeric not null check (qty > 0),
  price          numeric not null check (price > 0),
  fee            numeric not null default 0,
  created_at     timestamptz not null default now(),
  foreign key (competition_id, user_id) references public.participants(competition_id, user_id) on delete cascade
);
create index if not exists trades_comp_user on public.trades (competition_id, user_id, created_at desc);
create index if not exists trades_symbol_time on public.trades (symbol, created_at desc);

-- ---------- Боты ----------
-- Бот подключается, если игрок ждёт соперников дольше 3 минут.
-- Сделки бота не хранятся: его стратегия детерминированно считается в браузере
-- по общедоступным свечам Binance, поэтому у всех зрителей результат одинаковый.
create table if not exists public.competition_bots (
  competition_id uuid primary key references public.competitions(id) on delete cascade,
  name           text not null,
  strategy       text not null check (strategy in ('trend','momentum','contrarian','hodl')),
  joined_at      timestamptz not null default now()
);

-- ---------- Доступ: читать могут все, менять — только через функции ниже ----------
alter table public.profiles     enable row level security;
alter table public.competitions enable row level security;
alter table public.participants enable row level security;
alter table public.positions    enable row level security;
alter table public.trades       enable row level security;
alter table public.competition_bots enable row level security;

drop policy if exists "read all" on public.profiles;
drop policy if exists "read all" on public.competitions;
drop policy if exists "read all" on public.participants;
drop policy if exists "read all" on public.positions;
drop policy if exists "read all" on public.trades;
drop policy if exists "read all" on public.competition_bots;
create policy "read all" on public.profiles     for select using (true);
create policy "read all" on public.competitions for select using (true);
create policy "read all" on public.participants for select using (true);
create policy "read all" on public.positions    for select using (true);
create policy "read all" on public.trades       for select using (true);
create policy "read all" on public.competition_bots for select using (true);

-- ---------- Создать соревнование (создатель сразу становится участником) ----------
create or replace function public.create_competition(
  p_title text, p_symbols text[], p_start_balance numeric,
  p_starts_in_minutes int, p_duration_minutes int
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  allowed text[] := array['BTCUSDT','ETHUSDT','SOLUSDT','BNBUSDT','XRPUSDT','TONUSDT','DOGEUSDT','ADAUSDT'];
  syms text[];
  t0 timestamptz;
  cid uuid;
begin
  if uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if not exists (select 1 from profiles where id = uid) then raise exception 'Профиль не найден'; end if;
  select array_agg(distinct s order by s) into syms from unnest(p_symbols) s;
  if syms is null or not (syms <@ allowed) then raise exception 'Недопустимый список монет'; end if;
  if p_starts_in_minutes not between 0 and 10080 then raise exception 'Старт — не позже чем через неделю'; end if;
  if p_duration_minutes not between 1 and 43200 then raise exception 'Длительность — от 1 минуты до 30 дней'; end if;
  if (select count(*) from competitions where created_by = uid and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'Слишком много соревнований за час, попробуйте позже';
  end if;

  -- «сразу» — с текущего момента, иначе — с начала нужной минуты
  if p_starts_in_minutes = 0 then
    t0 := now();
  else
    t0 := date_trunc('minute', now()) + make_interval(mins => p_starts_in_minutes);
  end if;

  insert into competitions (title, created_by, symbols, start_balance, starts_at, ends_at)
  values (trim(p_title), uid, syms, p_start_balance, t0, t0 + make_interval(mins => p_duration_minutes))
  returning id into cid;

  insert into participants (competition_id, user_id, cash) values (cid, uid, p_start_balance);
  return cid;
end $$;

-- ---------- Вступить в соревнование ----------
create or replace function public.join_competition(p_competition uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  c competitions;
begin
  if uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select * into c from competitions where id = p_competition for update;
  if not found then raise exception 'Соревнование не найдено'; end if;
  if now() >= c.ends_at then raise exception 'Соревнование уже завершилось'; end if;
  if exists (select 1 from participants where competition_id = c.id and user_id = uid) then return; end if;

  if c.kind = 'duel' then
    if (select count(*) from participants where competition_id = c.id)
       + (select count(*) from competition_bots where competition_id = c.id) >= 2 then
      raise exception 'В этой схватке уже два игрока';
    end if;
    -- второй игрок найден — схватка начинается сразу
    if c.starts_at > now() then
      update competitions set ends_at = now() + (ends_at - starts_at), starts_at = now() where id = c.id;
    end if;
  end if;

  insert into participants (competition_id, user_id, cash) values (c.id, uid, c.start_balance);
end $$;

-- ---------- Быстрая схватка 1 на 1: найти соперника или встать в ожидание ----------
create or replace function public.find_duel(p_duration_minutes int)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  cid uuid;
  dur interval;
begin
  if uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  if p_duration_minutes not in (3, 5, 10, 15, 30, 60) then raise exception 'Недопустимая длительность схватки'; end if;
  dur := make_interval(mins => p_duration_minutes);

  -- уже жду соперника — возвращаю свою схватку
  select c.id into cid from competitions c
  where c.kind = 'duel' and c.created_by = uid and c.starts_at > now()
    and (select count(*) from participants p where p.competition_id = c.id) = 1
    and not exists (select 1 from competition_bots b where b.competition_id = c.id)
  order by c.created_at desc limit 1;
  if cid is not null then return cid; end if;

  -- кто-то ждёт схватку такой же длительности — присоединяюсь
  select c.id into cid from competitions c
  where c.kind = 'duel' and c.created_by <> uid and c.starts_at > now() and c.ends_at - c.starts_at = dur
    and (select count(*) from participants p where p.competition_id = c.id) = 1
    and not exists (select 1 from competition_bots b where b.competition_id = c.id)
  order by c.created_at
  limit 1
  for update of c skip locked;
  if cid is not null then
    update competitions set starts_at = now(), ends_at = now() + dur where id = cid;
    insert into participants (competition_id, user_id, cash)
      select cid, uid, start_balance from competitions where id = cid;
    return cid;
  end if;

  if (select count(*) from competitions where created_by = uid and kind = 'duel' and created_at > now() - interval '1 hour') >= 30 then
    raise exception 'Слишком много схваток за час, попробуйте позже';
  end if;

  -- никого нет — создаю схватку; через 3 минуты без соперника подключится бот
  insert into competitions (title, created_by, kind, symbols, start_balance, starts_at, ends_at)
  values ('Схватка 1 на 1', uid, 'duel', array['BTCUSDT','ETHUSDT','SOLUSDT'], 10000,
          now() + interval '3 minutes', now() + interval '3 minutes' + dur)
  returning id into cid;
  insert into participants (competition_id, user_id, cash) values (cid, uid, 10000);
  return cid;
end $$;

-- ---------- Позвать бота: игрок один и ждёт дольше 3 минут ----------
create or replace function public.summon_bot(p_competition uuid)
returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  c competitions;
  n int;
  j timestamptz;
  strat text;
  bot competition_bots;
begin
  if uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select * into c from competitions where id = p_competition for update;
  if not found then raise exception 'Соревнование не найдено'; end if;
  select * into bot from competition_bots where competition_id = c.id;
  if found then return row_to_json(bot); end if;
  if now() >= c.ends_at then raise exception 'Соревнование завершено'; end if;
  if not exists (select 1 from participants where competition_id = c.id and user_id = uid) then
    raise exception 'Сначала вступите в соревнование';
  end if;
  select count(*), max(joined_at) into n, j from participants where competition_id = c.id;
  if n <> 1 then raise exception 'Соперник уже есть'; end if;
  if now() < j + interval '3 minutes' then raise exception 'Бот подключится через 3 минуты ожидания'; end if;

  strat := (array['trend','momentum','contrarian','hodl'])[1 + floor(random() * 4)::int];
  insert into competition_bots (competition_id, name, strategy)
  values (c.id, case strat when 'trend' then 'Бот Трендовик' when 'momentum' then 'Бот Импульс'
                           when 'contrarian' then 'Бот Контрарий' else 'Бот Ходлер' end, strat)
  returning * into bot;

  if c.kind = 'duel' and c.starts_at > now() then
    update competitions set ends_at = now() + (ends_at - starts_at), starts_at = now() where id = c.id;
  end if;
  return row_to_json(bot);
end $$;

-- ---------- Сделка по рыночной цене ----------
-- Цена приходит из браузера (живая цена Binance). Сервер проверяет время, баланс, позицию
-- и что цена не уходит больше чем на 3% от медианы недавних сделок других игроков.
create or replace function public.place_order(
  p_competition uuid, p_symbol text, p_side text, p_qty numeric, p_price numeric
) returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  c competitions;
  p participants;
  pos positions;
  fee_rate constant numeric := 0.001;   -- комиссия 0,1%
  notional numeric;
  fee numeric;
  ref numeric;
  last_at timestamptz;
begin
  if uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select * into c from competitions where id = p_competition;
  if not found then raise exception 'Соревнование не найдено'; end if;
  if now() < c.starts_at then raise exception 'Соревнование ещё не началось'; end if;
  if now() >= c.ends_at then raise exception 'Соревнование завершено'; end if;
  if not (p_symbol = any (c.symbols)) then raise exception 'Эта монета не участвует в соревновании'; end if;
  if p_side not in ('buy','sell') then raise exception 'Неизвестная сторона сделки'; end if;
  if p_qty is null or p_qty <= 0 or p_price is null or p_price <= 0 then raise exception 'Неверное количество или цена'; end if;

  select * into p from participants where competition_id = c.id and user_id = uid for update;
  if not found then raise exception 'Сначала вступите в соревнование'; end if;

  select max(created_at) into last_at from trades where competition_id = c.id and user_id = uid;
  if last_at is not null and now() - last_at < interval '300 milliseconds' then
    raise exception 'Слишком часто, подождите секунду';
  end if;

  select percentile_cont(0.5) within group (order by price) into ref
  from (select price from trades
        where symbol = p_symbol and user_id <> uid and created_at > now() - interval '2 minutes'
        order by created_at desc limit 20) r
  having count(*) >= 3;
  if ref is not null and abs(p_price - ref) / ref > 0.03 then
    raise exception 'Цена сильно отличается от рынка, обновите страницу';
  end if;

  notional := p_qty * p_price;
  fee := round(notional * fee_rate, 8);
  select * into pos from positions where competition_id = c.id and user_id = uid and symbol = p_symbol;

  if p_side = 'buy' then
    if notional + fee > p.cash + 0.000001 then raise exception 'Недостаточно средств'; end if;
    update participants set cash = greatest(0, cash - notional - fee)
      where competition_id = c.id and user_id = uid;
    insert into positions (competition_id, user_id, symbol, qty, avg_price)
    values (c.id, uid, p_symbol, p_qty, p_price)
    on conflict (competition_id, user_id, symbol) do update
      set avg_price = (positions.qty * positions.avg_price + excluded.qty * excluded.avg_price) / (positions.qty + excluded.qty),
          qty = positions.qty + excluded.qty;
  else
    if pos.qty is null or p_qty > pos.qty * 1.000001 then raise exception 'Недостаточно монет для продажи'; end if;
    if p_qty > pos.qty then p_qty := pos.qty; notional := p_qty * p_price; fee := round(notional * fee_rate, 8); end if;
    update participants set cash = cash + notional - fee
      where competition_id = c.id and user_id = uid;
    if pos.qty - p_qty <= pos.qty * 0.000001 then
      delete from positions where competition_id = c.id and user_id = uid and symbol = p_symbol;
    else
      update positions set qty = qty - p_qty
        where competition_id = c.id and user_id = uid and symbol = p_symbol;
    end if;
  end if;

  insert into trades (competition_id, user_id, symbol, side, qty, price, fee)
  values (c.id, uid, p_symbol, p_side, p_qty, p_price, fee);

  return json_build_object('cash', (select cash from participants where competition_id = c.id and user_id = uid),
                           'qty', p_qty, 'price', p_price, 'fee', fee);
end $$;

-- ---------- Время сервера (для точных таймеров в браузере) ----------
create or replace function public.server_time()
returns timestamptz language sql stable as $$ select now() $$;

-- ---------- Права на функции ----------
grant execute on function public.server_time() to anon, authenticated;
revoke all on function public.create_competition(text, text[], numeric, int, int) from public, anon;
revoke all on function public.join_competition(uuid) from public, anon;
revoke all on function public.place_order(uuid, text, text, numeric, numeric) from public, anon;
revoke all on function public.find_duel(int) from public, anon;
revoke all on function public.summon_bot(uuid) from public, anon;
grant execute on function public.find_duel(int) to authenticated;
grant execute on function public.summon_bot(uuid) to authenticated;
grant execute on function public.create_competition(text, text[], numeric, int, int) to authenticated;
grant execute on function public.join_competition(uuid) to authenticated;
grant execute on function public.place_order(uuid, text, text, numeric, numeric) to authenticated;
revoke all on function public.handle_new_user() from public, anon, authenticated;
