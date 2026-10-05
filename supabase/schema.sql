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

-- ---------- Фьючерсы и рейтинг Эло ----------
alter table public.profiles add column if not exists elo    int not null default 1000;
alter table public.profiles add column if not exists games  int not null default 0;
alter table public.profiles add column if not exists wins   int not null default 0;
alter table public.profiles add column if not exists losses int not null default 0;
create index if not exists profiles_elo on public.profiles (elo desc);

-- рынок соревнования: спот (только покупка) или фьючерсы (лонг/шорт с плечом)
alter table public.competitions add column if not exists market text not null default 'spot';
do $$ begin
  alter table public.competitions add constraint competitions_market_check check (market in ('spot','futures'));
exception when duplicate_object then null; end $$;
alter table public.competitions add column if not exists finalized_at timestamptz;

-- фьючерсная позиция: направление, плечо и маржа (у спотовой позиции margin = null)
alter table public.positions add column if not exists side     text not null default 'long';
alter table public.positions add column if not exists leverage int  not null default 1;
alter table public.positions add column if not exists margin   numeric;
do $$ begin
  alter table public.positions add constraint positions_side_check check (side in ('long','short'));
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.positions add constraint positions_leverage_check check (leverage between 1 and 20);
exception when duplicate_object then null; end $$;

alter table public.trades drop constraint if exists trades_side_check;
alter table public.trades add constraint trades_side_check check (side in ('buy','sell','long','short','close','liq'));
alter table public.trades add column if not exists leverage int;
alter table public.trades add column if not exists pnl numeric;

alter table public.competition_bots drop constraint if exists competition_bots_strategy_check;
alter table public.competition_bots add constraint competition_bots_strategy_check
  check (strategy in ('trend','scalper','contrarian','breakout','momentum','hodl'));
alter table public.competition_bots add column if not exists rating int not null default 1100;

-- итоги соревнований и изменение рейтинга
create table if not exists public.competition_results (
  competition_id uuid not null references public.competitions(id) on delete cascade,
  slot           text not null,              -- id игрока или 'bot'
  user_id        uuid references public.profiles(id) on delete cascade,
  is_bot         boolean not null default false,
  name           text not null,
  equity         numeric not null,
  place          int not null,
  elo_before     int not null,
  elo_after      int not null,
  primary key (competition_id, slot)
);
create index if not exists competition_results_user on public.competition_results (user_id);

-- ---------- Доступ: читать могут все, менять — только через функции ниже ----------
alter table public.profiles     enable row level security;
alter table public.competitions enable row level security;
alter table public.participants enable row level security;
alter table public.positions    enable row level security;
alter table public.trades       enable row level security;
alter table public.competition_bots enable row level security;
alter table public.competition_results enable row level security;

drop policy if exists "read all" on public.profiles;
drop policy if exists "read all" on public.competitions;
drop policy if exists "read all" on public.participants;
drop policy if exists "read all" on public.positions;
drop policy if exists "read all" on public.trades;
drop policy if exists "read all" on public.competition_bots;
drop policy if exists "read all" on public.competition_results;
create policy "read all" on public.profiles     for select using (true);
create policy "read all" on public.competitions for select using (true);
create policy "read all" on public.participants for select using (true);
create policy "read all" on public.positions    for select using (true);
create policy "read all" on public.trades       for select using (true);
create policy "read all" on public.competition_bots for select using (true);
create policy "read all" on public.competition_results for select using (true);

-- ---------- Создать соревнование (создатель сразу становится участником) ----------
drop function if exists public.create_competition(text, text[], numeric, int, int);
create or replace function public.create_competition(
  p_title text, p_symbols text[], p_start_balance numeric,
  p_starts_in_minutes int, p_duration_minutes int, p_market text default 'spot'
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
  if coalesce(p_market, 'spot') not in ('spot','futures') then raise exception 'Неизвестный рынок'; end if;
  if (select count(*) from competitions where created_by = uid and created_at > now() - interval '1 hour') >= 10 then
    raise exception 'Слишком много соревнований за час, попробуйте позже';
  end if;

  -- «сразу» — с текущего момента, иначе — с начала нужной минуты
  if p_starts_in_minutes = 0 then
    t0 := now();
  else
    t0 := date_trunc('minute', now()) + make_interval(mins => p_starts_in_minutes);
  end if;

  insert into competitions (title, created_by, symbols, start_balance, starts_at, ends_at, market)
  values (trim(p_title), uid, syms, p_start_balance, t0, t0 + make_interval(mins => p_duration_minutes), coalesce(p_market, 'spot'))
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
  insert into competitions (title, created_by, kind, market, symbols, start_balance, starts_at, ends_at)
  values ('Схватка 1 на 1', uid, 'duel', 'futures', array['BTCUSDT','ETHUSDT','SOLUSDT'], 10000,
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

  strat := (array['trend','scalper','contrarian','breakout'])[1 + floor(random() * 4)::int];
  insert into competition_bots (competition_id, name, strategy, rating)
  values (c.id,
          case strat when 'trend' then 'Бот Трендовик' when 'scalper' then 'Бот Скальпер'
                     when 'contrarian' then 'Бот Контрарий' else 'Бот Пробойщик' end,
          strat,
          case strat when 'scalper' then 1200 when 'contrarian' then 1100 else 1150 end)
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
  if c.market = 'futures' then raise exception 'Здесь торгуют фьючерсами — обновите страницу'; end if;
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


-- ---------- Фьючерсы: открыть лонг/шорт или закрыть позицию ----------
-- Изолированная маржа, плечо 1–20x, комиссия 0,05% от объёма позиции.
create or replace function public.place_futures(
  p_competition uuid, p_symbol text, p_action text,
  p_margin numeric, p_leverage int, p_price numeric, p_fraction numeric default 1
) returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  c competitions;
  p participants;
  pos positions;
  fee_rate constant numeric := 0.0005;
  v_notional numeric; v_fee numeric; v_qty numeric; v_pnl numeric; v_payout numeric; v_f numeric;
  ref numeric;
  last_at timestamptz;
begin
  if uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select * into c from competitions where id = p_competition;
  if not found then raise exception 'Соревнование не найдено'; end if;
  if c.market <> 'futures' then raise exception 'В этом соревновании нет фьючерсов'; end if;
  if now() < c.starts_at then raise exception 'Соревнование ещё не началось'; end if;
  if now() >= c.ends_at then raise exception 'Соревнование завершено'; end if;
  if not (p_symbol = any (c.symbols)) then raise exception 'Эта монета не участвует в соревновании'; end if;
  if p_action not in ('long','short','close') then raise exception 'Неизвестное действие'; end if;
  if p_price is null or p_price <= 0 then raise exception 'Неверная цена'; end if;

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

  select * into pos from positions where competition_id = c.id and user_id = uid and symbol = p_symbol for update;

  if p_action in ('long','short') then
    if p_leverage is null or p_leverage not in (1,2,3,5,10,20) then raise exception 'Недопустимое плечо'; end if;
    if p_margin is null or p_margin < 1 then raise exception 'Минимальная маржа — 1 $'; end if;
    v_notional := p_margin * p_leverage;
    v_fee := round(v_notional * fee_rate, 8);
    if p_margin + v_fee > p.cash + 0.000001 then raise exception 'Недостаточно средств (с учётом комиссии)'; end if;
    v_qty := v_notional / p_price;
    if pos.symbol is not null then
      if pos.margin is null then raise exception 'По этой монете открыта спотовая позиция'; end if;
      if pos.side <> p_action then raise exception 'Сначала закройте позицию в другую сторону'; end if;
      if pos.leverage <> p_leverage then raise exception 'Плечо должно совпадать с открытой позицией (x%)', pos.leverage; end if;
      update positions
         set avg_price = (qty * avg_price + v_qty * p_price) / (qty + v_qty),
             qty = qty + v_qty,
             margin = margin + p_margin
       where competition_id = c.id and user_id = uid and symbol = p_symbol;
    else
      insert into positions (competition_id, user_id, symbol, qty, avg_price, side, leverage, margin)
      values (c.id, uid, p_symbol, v_qty, p_price, p_action, p_leverage, p_margin);
    end if;
    update participants set cash = greatest(0, cash - p_margin - v_fee) where competition_id = c.id and user_id = uid;
    insert into trades (competition_id, user_id, symbol, side, qty, price, fee, leverage)
    values (c.id, uid, p_symbol, p_action, v_qty, p_price, v_fee, p_leverage);
    v_pnl := null;
  else
    if pos.symbol is null then raise exception 'Нет открытой позиции'; end if;
    if pos.margin is null then raise exception 'Это спотовая позиция'; end if;
    v_f := least(greatest(coalesce(p_fraction, 1), 0.01), 1);
    v_qty := pos.qty * v_f;
    v_pnl := (case pos.side when 'long' then 1 else -1 end) * (p_price - pos.avg_price) * v_qty;
    v_fee := round(v_qty * p_price * fee_rate, 8);
    v_payout := greatest(0, pos.margin * v_f + v_pnl - v_fee);
    update participants set cash = cash + v_payout where competition_id = c.id and user_id = uid;
    if v_f >= 0.999999 then
      delete from positions where competition_id = c.id and user_id = uid and symbol = p_symbol;
    else
      update positions set qty = qty - v_qty, margin = margin * (1 - v_f)
       where competition_id = c.id and user_id = uid and symbol = p_symbol;
    end if;
    insert into trades (competition_id, user_id, symbol, side, qty, price, fee, leverage, pnl)
    values (c.id, uid, p_symbol, 'close', v_qty, p_price, v_fee, pos.leverage, v_pnl);
  end if;

  return json_build_object('cash', (select cash from participants where competition_id = c.id and user_id = uid),
                           'qty', v_qty, 'price', p_price, 'fee', v_fee, 'pnl', v_pnl);
end $$;

-- ---------- Ликвидация: цена дошла до уровня, где убыток съел 90% маржи ----------
-- Вызвать может любой участник соревнования (браузеры участников следят за ценой).
create or replace function public.liquidate_position(
  p_competition uuid, p_user uuid, p_symbol text, p_price numeric
) returns boolean
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  c competitions;
  pos positions;
  liq numeric;
  ref numeric;
begin
  if uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select * into c from competitions where id = p_competition;
  if not found then raise exception 'Соревнование не найдено'; end if;
  if now() >= c.ends_at then return false; end if;
  if not exists (select 1 from participants where competition_id = c.id and user_id = uid) then
    raise exception 'Только для участников соревнования';
  end if;
  select * into pos from positions where competition_id = c.id and user_id = p_user and symbol = p_symbol for update;
  if not found or pos.margin is null then return false; end if;

  liq := case pos.side when 'long' then pos.avg_price * (1 - 0.9 / pos.leverage)
                       else pos.avg_price * (1 + 0.9 / pos.leverage) end;
  if (pos.side = 'long' and p_price > liq) or (pos.side = 'short' and p_price < liq) then
    raise exception 'Цена не дошла до ликвидации';
  end if;
  select percentile_cont(0.5) within group (order by price) into ref
  from (select price from trades where symbol = p_symbol and created_at > now() - interval '2 minutes'
        order by created_at desc limit 20) r
  having count(*) >= 3;
  if ref is not null and abs(p_price - ref) / ref > 0.03 then
    raise exception 'Цена сильно отличается от рынка';
  end if;

  delete from positions where competition_id = c.id and user_id = p_user and symbol = p_symbol;
  insert into trades (competition_id, user_id, symbol, side, qty, price, fee, leverage, pnl)
  values (c.id, p_user, p_symbol, 'liq', pos.qty, p_price, 0, pos.leverage, -pos.margin);
  return true;
end $$;

-- ---------- Итоги и рейтинг Эло ----------
-- После финиша любой вошедший игрок передаёт итоговые цены (закрытие минутной свечи Binance
-- в момент финиша) и результат бота. Сервер сверяет цены со сделками, считает капитал,
-- места и Эло. Итог фиксируется один раз.
create or replace function public.finalize_competition(
  p_competition uuid, p_prices jsonb, p_bot_equity numeric default null
) returns json
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  c competitions;
  bot competition_bots;
  s text;
  px numeric;
  ref numeric;
  n int;
  r record;
  delta numeric;
begin
  if uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select * into c from competitions where id = p_competition for update;
  if not found then raise exception 'Соревнование не найдено'; end if;
  if now() < c.ends_at then raise exception 'Соревнование ещё идёт'; end if;
  if c.finalized_at is not null then
    return (select json_agg(row_to_json(x) order by x.place) from competition_results x where x.competition_id = c.id);
  end if;

  foreach s in array c.symbols loop
    px := (p_prices->>s)::numeric;
    if px is null or px <= 0 then raise exception 'Нет итоговой цены для %', s; end if;
    select percentile_cont(0.5) within group (order by price) into ref
    from (select price from trades
          where symbol = s and created_at between c.ends_at - interval '30 minutes' and c.ends_at
          order by created_at desc limit 20) t
    having count(*) >= 1;
    if ref is not null and abs(px - ref) / ref > 0.05 then
      raise exception 'Итоговая цена % не совпадает с рынком', s;
    end if;
  end loop;

  select * into bot from competition_bots where competition_id = c.id;
  if bot.competition_id is not null and p_bot_equity is null then raise exception 'Нужен результат бота'; end if;

  insert into competition_results (competition_id, slot, user_id, is_bot, name, equity, place, elo_before, elo_after)
  select c.id, pa.user_id::text, pa.user_id, false, pr.username,
         pa.cash + coalesce((
           select sum(case when po.margin is null then po.qty * (p_prices->>po.symbol)::numeric
                           else greatest(0, po.margin + (case po.side when 'long' then 1 else -1 end)
                                            * ((p_prices->>po.symbol)::numeric - po.avg_price) * po.qty) end)
           from positions po where po.competition_id = c.id and po.user_id = pa.user_id), 0),
         0, pr.elo, pr.elo
  from participants pa join profiles pr on pr.id = pa.user_id
  where pa.competition_id = c.id;

  if bot.competition_id is not null then
    insert into competition_results (competition_id, slot, user_id, is_bot, name, equity, place, elo_before, elo_after)
    values (c.id, 'bot', null, true, bot.name, least(greatest(p_bot_equity, 0), c.start_balance * 5), 0, bot.rating, bot.rating);
  end if;

  update competition_results cr set place = x.pl
  from (select slot, rank() over (order by equity desc) as pl from competition_results where competition_id = c.id) x
  where cr.competition_id = c.id and cr.slot = x.slot;

  select count(*) into n from competition_results where competition_id = c.id;
  if n >= 2 then
    for r in select * from competition_results where competition_id = c.id and not is_bot loop
      -- попарное Эло: K = 32 против людей, 16 против бота; в турнирах делится на число соперников
      select coalesce(sum(
               (case when o.is_bot then 16 else 32 end)::numeric / (n - 1) *
               ((case when r.equity > o.equity * 1.000001 then 1
                      when o.equity > r.equity * 1.000001 then 0 else 0.5 end)
                - 1 / (1 + power(10, (o.elo_before - r.elo_before) / 400.0)))), 0)
        into delta
      from competition_results o where o.competition_id = c.id and o.slot <> r.slot;
      update competition_results set elo_after = greatest(100, round(r.elo_before + delta))
       where competition_id = c.id and slot = r.slot;
      update profiles set elo = greatest(100, elo + round(delta)::int),
                          games = games + 1,
                          wins = wins + (r.place = 1)::int,
                          losses = losses + (r.place > 1)::int
       where id = r.user_id;
    end loop;
  end if;

  update competitions set finalized_at = now() where id = c.id;
  return (select json_agg(row_to_json(x) order by x.place) from competition_results x where x.competition_id = c.id);
end $$;

-- ---------- Отменить схватку, пока соперник не найден ----------
create or replace function public.cancel_duel(p_competition uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid();
  c competitions;
begin
  if uid is null then raise exception 'Нужно войти в аккаунт'; end if;
  select * into c from competitions where id = p_competition for update;
  if not found then raise exception 'Схватка не найдена'; end if;
  if c.kind <> 'duel' then raise exception 'Отменить можно только схватку'; end if;
  if c.created_by <> uid then raise exception 'Отменить схватку может только тот, кто её начал'; end if;
  if now() >= c.ends_at then raise exception 'Схватка уже завершилась'; end if;
  if exists (select 1 from competition_bots where competition_id = c.id)
     or (select count(*) from participants where competition_id = c.id) > 1 then
    raise exception 'Соперник уже найден — схватку нельзя отменить';
  end if;
  delete from competitions where id = c.id;
end $$;

revoke all on function public.cancel_duel(uuid) from public, anon;
grant execute on function public.cancel_duel(uuid) to authenticated;

-- ---------- Время сервера (для точных таймеров в браузере) ----------
create or replace function public.server_time()
returns timestamptz language sql stable set search_path = '' as $$ select now() $$;

-- ---------- Права на функции ----------
grant execute on function public.server_time() to anon, authenticated;
revoke all on function public.create_competition(text, text[], numeric, int, int, text) from public, anon;
revoke all on function public.place_futures(uuid, text, text, numeric, int, numeric, numeric) from public, anon;
revoke all on function public.liquidate_position(uuid, uuid, text, numeric) from public, anon;
revoke all on function public.finalize_competition(uuid, jsonb, numeric) from public, anon;
grant execute on function public.place_futures(uuid, text, text, numeric, int, numeric, numeric) to authenticated;
grant execute on function public.liquidate_position(uuid, uuid, text, numeric) to authenticated;
grant execute on function public.finalize_competition(uuid, jsonb, numeric) to authenticated;
revoke all on function public.join_competition(uuid) from public, anon;
revoke all on function public.place_order(uuid, text, text, numeric, numeric) from public, anon;
revoke all on function public.find_duel(int) from public, anon;
revoke all on function public.summon_bot(uuid) from public, anon;
grant execute on function public.find_duel(int) to authenticated;
grant execute on function public.summon_bot(uuid) to authenticated;
grant execute on function public.create_competition(text, text[], numeric, int, int, text) to authenticated;
grant execute on function public.join_competition(uuid) to authenticated;
grant execute on function public.place_order(uuid, text, text, numeric, numeric) to authenticated;
revoke all on function public.handle_new_user() from public, anon, authenticated;
