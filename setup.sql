-- =========================================================
-- 길드 쿠지 — Supabase 설정 SQL
-- Supabase 대시보드 > SQL Editor 에 통째로 붙여넣고 Run.
-- 맨 아래 관리자 이메일만 본인 걸로 바꿔줘.
-- =========================================================

create extension if not exists pgcrypto with schema extensions;

-- ---------- 테이블 ----------
create table if not exists public.settings (
  id int primary key default 1 check (id = 1),
  title text not null default '길드 쿠지',
  cost int not null default 5000 check (cost > 0),
  last_one_name text not null default '',
  last_one_winner uuid,
  last_one_winner_name text
);
insert into public.settings (id) values (1) on conflict do nothing;

create table if not exists public.prizes (
  id uuid primary key default gen_random_uuid(),
  grade text not null,
  name text not null default '',
  total int not null default 1 check (total >= 0),
  remaining int not null default 1 check (remaining >= 0),
  color text not null default '#e2312f',
  image text,
  sort int not null default 0
);

create table if not exists public.members (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  base_gp int not null default 0,   -- 이벤트 시작 시점 GP
  last_gp int not null default 0,   -- 마지막으로 인증한 GP
  used_gp int not null default 0,   -- 뽑기에 쓴 GP
  has_pin boolean not null default false,
  created_at timestamptz not null default now()
);

-- 비밀번호 해시는 따로 보관 (일반 방문자는 못 읽음)
create table if not exists public.member_pins (
  member_id uuid primary key references public.members(id) on delete cascade,
  pin_hash text not null
);

create table if not exists public.draws (
  id uuid primary key default gen_random_uuid(),
  member_id uuid references public.members(id) on delete set null,
  name text not null,
  photo text not null unique,
  reported_gp int,
  results jsonb not null,
  count int not null,
  spent int not null,
  created_at timestamptz not null default now()
);

create table if not exists public.admins (email text primary key);

-- ---------- 관리자 판별 ----------
create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where email = auth.jwt() ->> 'email');
$$;

-- ---------- 보안 규칙 (RLS) ----------
alter table public.settings    enable row level security;
alter table public.prizes      enable row level security;
alter table public.members     enable row level security;
alter table public.member_pins enable row level security;
alter table public.draws       enable row level security;
alter table public.admins      enable row level security;

drop policy if exists "read" on public.settings;
drop policy if exists "read" on public.prizes;
drop policy if exists "read" on public.members;
drop policy if exists "read" on public.draws;
create policy "read" on public.settings for select using (true);
create policy "read" on public.prizes   for select using (true);
create policy "read" on public.members  for select using (true);
create policy "read" on public.draws    for select using (true);

drop policy if exists "admin" on public.settings;
drop policy if exists "admin" on public.prizes;
drop policy if exists "admin" on public.members;
drop policy if exists "admin" on public.member_pins;
drop policy if exists "admin" on public.draws;
create policy "admin" on public.settings    for all using (public.is_admin()) with check (public.is_admin());
create policy "admin" on public.prizes      for all using (public.is_admin()) with check (public.is_admin());
create policy "admin" on public.members     for all using (public.is_admin()) with check (public.is_admin());
create policy "admin" on public.member_pins for all using (public.is_admin()) with check (public.is_admin());
create policy "admin" on public.draws       for all using (public.is_admin()) with check (public.is_admin());
-- admins 테이블은 정책 없음 = SQL Editor 에서만 수정 가능

-- ---------- 쿠지판 칸 (어느 칸에 뭐가 있는지는 뜯기 전까지 비공개) ----------
alter table public.settings add column if not exists board_size int not null default 0;

create table if not exists public.slots (
  no int primary key,
  prize_id uuid references public.prizes(id) on delete cascade,
  opened boolean not null default false,
  opened_by uuid,
  opened_name text,
  opened_at timestamptz,
  grade text,
  name text,
  color text,
  image text
);
alter table public.slots enable row level security;
drop policy if exists "read opened" on public.slots;
drop policy if exists "admin" on public.slots;
create policy "read opened" on public.slots for select using (opened);
create policy "admin" on public.slots for all using (public.is_admin()) with check (public.is_admin());

-- 판 새로 만들기: 상품 수량만큼 칸을 만들고 무작위로 섞음 (관리자만)
create or replace function public.shuffle_board()
returns int
language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.is_admin() then raise exception '관리자만 할 수 있어요'; end if;
  perform 1 from public.settings where id = 1 for update;
  delete from public.slots where true;
  update public.prizes set remaining = total where true;
  insert into public.slots (no, prize_id)
    select row_number() over (order by random()), t.id
    from (select p.id from public.prizes p cross join lateral generate_series(1, p.total)) t;
  select count(*) into n from public.slots;
  update public.settings set board_size = n, last_one_winner = null, last_one_winner_name = null where id = 1;
  return n;
end $$;
revoke all on function public.shuffle_board() from public, anon;
grant execute on function public.shuffle_board() to authenticated;

-- ---------- 뽑기권 (GP 인증 → 뽑기권 → 판에서 직접 골라 뽑기) ----------
alter table public.members add column if not exists credits int not null default 0;

drop function if exists public.draw_kuji(uuid, text, int, text);
drop function if exists public.draw_kuji(uuid, text, int, text, int);
drop function if exists public.draw_kuji(uuid, text, int[], text, int);

-- 1) GP 인증: 스샷에서 읽은 GP로 뽑기권 지급 (서버 함수 kuji-draw 만 호출 가능)
--    지급 장수 = (인증 GP - 기준 GP - 이미 쓴 GP) ÷ 1장 GP, 남은 쿠지 수까지만
create or replace function public.grant_credits(p_member uuid, p_pin text, p_photo text, p_gp int)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  s public.settings;
  m public.members;
  v_hash text;
  avail int;
  add int;
  unopened int;
begin
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then
    raise exception '비밀번호는 숫자 4자리로 입력해 주세요';
  end if;
  if p_gp is null or p_gp < 0 then
    raise exception 'GP를 읽지 못했어요';
  end if;
  if p_photo is null or not exists (select 1 from storage.objects where bucket_id = 'proofs' and name = p_photo) then
    raise exception '인증 사진이 업로드되지 않았어요';
  end if;
  if exists (select 1 from public.draws where photo = p_photo) then
    raise exception '이미 사용한 사진이에요';
  end if;

  select * into s from public.settings where id = 1 for update;
  select * into m from public.members where id = p_member for update;
  if not found then raise exception '길드원을 찾을 수 없어요'; end if;

  select pin_hash into v_hash from public.member_pins where member_id = p_member;
  if v_hash is null then
    insert into public.member_pins (member_id, pin_hash) values (p_member, crypt(p_pin, gen_salt('bf')));
    update public.members set has_pin = true where id = p_member;
  elsif v_hash <> crypt(p_pin, v_hash) then
    raise exception '비밀번호가 틀렸어요';
  end if;

  if p_gp < m.last_gp then
    raise exception '전에 인증한 GP(%)보다 작아요. 최신 스샷인지 확인해 주세요', m.last_gp;
  end if;

  avail := greatest(p_gp - m.base_gp - m.used_gp, 0);
  select count(*) into unopened from public.slots where not opened;
  add := least(avail / s.cost, greatest(unopened - m.credits, 0));
  if unopened = 0 then
    raise exception '쿠지가 전부 소진됐어요';
  end if;
  if add < 1 then
    raise exception '늘어난 GP가 부족해요 (사용 가능 GP: %, 1장에 %)', avail, s.cost;
  end if;

  update public.members
     set last_gp = p_gp, used_gp = used_gp + add * s.cost, credits = credits + add
   where id = p_member;
  insert into public.draws (member_id, name, photo, reported_gp, results, count, spent)
    values (p_member, m.name, p_photo, p_gp, '[]'::jsonb, add, add * s.cost);

  return jsonb_build_object('granted', add, 'credits', m.credits + add, 'gp', p_gp,
                            'gained', p_gp - m.base_gp, 'carry', avail - add * s.cost);
end $$;
revoke all on function public.grant_credits(uuid, text, text, int) from public, anon, authenticated;
grant execute on function public.grant_credits(uuid, text, text, int) to service_role;

-- 2) 쿠지 고르기: 판에서 고른 칸을 뽑기권으로 뜯음 (브라우저에서 바로 호출, 비밀번호 필요)
create or replace function public.pick_slots(p_member uuid, p_pin text, p_slots int[])
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  s public.settings;
  m public.members;
  sl public.slots;
  pr public.prizes;
  v_hash text;
  v_no int;
  k int := 0;
  v_results jsonb := '[]'::jsonb;
  last_draw uuid;
begin
  if p_slots is null or cardinality(p_slots) = 0 then
    raise exception '뽑을 쿠지를 골라 주세요';
  end if;
  if cardinality(p_slots) <> (select count(distinct x) from unnest(p_slots) x) then
    raise exception '같은 쿠지를 두 번 고를 수 없어요';
  end if;

  select * into s from public.settings where id = 1 for update;
  select * into m from public.members where id = p_member for update;
  if not found then raise exception '길드원을 찾을 수 없어요'; end if;

  if p_pin is null or p_pin !~ '^[0-9]{4}$' then
    raise exception '비밀번호는 숫자 4자리로 입력해 주세요';
  end if;
  select pin_hash into v_hash from public.member_pins where member_id = p_member;
  if v_hash is null then
    -- 비번 없이 뽑기권만 받은 경우(관리자 지급 등): 처음 입력한 숫자를 비번으로 정함
    insert into public.member_pins (member_id, pin_hash) values (p_member, crypt(p_pin, gen_salt('bf')));
    update public.members set has_pin = true where id = p_member;
  elsif v_hash <> crypt(p_pin, v_hash) then
    raise exception '비밀번호가 틀렸어요';
  end if;
  if m.credits < cardinality(p_slots) then
    raise exception '뽑기권이 %장 남았어요', m.credits;
  end if;

  foreach v_no in array p_slots loop
    select * into sl from public.slots where no = v_no for update;
    if not found then raise exception '없는 쿠지예요'; end if;
    if sl.opened then raise exception '방금 다른 사람이 그 쿠지를 가져갔어요. 다시 골라 주세요'; end if;
    select * into pr from public.prizes where id = sl.prize_id;
    update public.slots
       set opened = true, opened_by = p_member, opened_name = m.name, opened_at = now(),
           grade = pr.grade, name = pr.name, color = pr.color, image = pr.image
     where no = v_no;
    update public.prizes set remaining = remaining - 1 where id = pr.id;
    v_results := v_results || jsonb_build_object('no', v_no, 'prize_id', pr.id, 'grade', pr.grade, 'name', pr.name, 'color', pr.color, 'image', pr.image);
    k := k + 1;
  end loop;

  if s.last_one_name <> '' and s.last_one_winner is null
     and not exists (select 1 from public.slots where not opened) then
    update public.settings set last_one_winner = p_member, last_one_winner_name = m.name where id = 1;
    v_results := v_results || jsonb_build_object('grade', '라스트원', 'name', s.last_one_name, 'color', '#1b1416', 'last', true,
      'code', (select value from public.kuji_secrets where key = 'last_one_code'));
  end if;

  update public.members set credits = credits - k where id = p_member;

  select id into last_draw from public.draws where member_id = p_member order by created_at desc limit 1;
  if last_draw is not null then
    update public.draws set results = draws.results || v_results
     where id = last_draw;
  end if;

  return jsonb_build_object('results', v_results, 'credits', m.credits - k);
end $$;
revoke all on function public.pick_slots(uuid, text, int[]) from public;
grant execute on function public.pick_slots(uuid, text, int[]) to anon, authenticated;


-- AI 호출 전에 비밀번호부터 확인 (비번 없으면 true = 첫 뽑기)
create or replace function public.verify_pin(p_member uuid, p_pin text)
returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((select pin_hash = crypt(p_pin, pin_hash) from public.member_pins where member_id = p_member), true);
$$;
revoke all on function public.verify_pin(uuid, text) from public, anon, authenticated;
grant execute on function public.verify_pin(uuid, text) to service_role;

-- ---------- 선택 경품: 같은 등급 안에서 아이템 골라 코드 받기 ----------
create table if not exists public.prize_items (
  id uuid primary key default gen_random_uuid(),
  prize_id uuid not null references public.prizes(id) on delete cascade,
  name text not null,
  image text,
  sort int not null default 0
);
-- 코드는 비공개 (받은 본인만 함수로 확인)
create table if not exists public.item_codes (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references public.prize_items(id) on delete cascade,
  code text not null,
  claimed_slot int,
  claimed_slot_uid uuid,
  claimed_by uuid,
  claimed_name text,
  claimed_at timestamptz
);
alter table public.item_codes add column if not exists claimed_slot_uid uuid;
alter table public.slots add column if not exists uid uuid not null default gen_random_uuid();
alter table public.slots add column if not exists item_id uuid;
alter table public.slots add column if not exists item_name text;

alter table public.prize_items enable row level security;
alter table public.item_codes enable row level security;
drop policy if exists "read" on public.prize_items;
drop policy if exists "admin" on public.prize_items;
drop policy if exists "admin" on public.item_codes;
create policy "read" on public.prize_items for select using (true);
create policy "admin" on public.prize_items for all using (public.is_admin()) with check (public.is_admin());
create policy "admin" on public.item_codes for all using (public.is_admin()) with check (public.is_admin());

-- 같은 아이템에 같은 코드 중복 방지 (기존 중복은 하나만 남김, 지급된 건 유지)
delete from public.item_codes a
 where a.claimed_slot_uid is null
   and exists (select 1 from public.item_codes b
                where b.item_id = a.item_id and b.code = a.code and b.id <> a.id
                  and (b.claimed_slot_uid is not null or b.id < a.id));
do $$ begin
  create unique index if not exists item_codes_item_code_uq on public.item_codes (item_id, code);
exception when others then null; end $$;

-- 라스트원 코드 등 비공개 값 (관리자만 읽기/쓰기)
create table if not exists public.kuji_secrets (key text primary key, value text);
alter table public.kuji_secrets enable row level security;
drop policy if exists "admin" on public.kuji_secrets;
create policy "admin" on public.kuji_secrets for all using (public.is_admin()) with check (public.is_admin());

-- 아이템별 남은 수량 (코드가 하나도 없으면 무제한 = null)
create or replace function public.item_stock()
returns table (item_id uuid, total int, remaining int)
language sql stable security definer set search_path = public as $$
  select i.id,
         count(c.id)::int,
         case when count(c.id) = 0 then null else count(c.id) filter (where c.claimed_slot_uid is null)::int end
  from public.prize_items i left join public.item_codes c on c.item_id = i.id
  group by i.id;
$$;
grant execute on function public.item_stock() to anon, authenticated;

-- 비밀번호 확인 공용
create or replace function public.check_pin(p_member uuid, p_pin text)
returns void
language plpgsql security definer set search_path = public, extensions as $$
declare v_hash text;
begin
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then raise exception '비밀번호는 숫자 4자리로 입력해 주세요'; end if;
  select pin_hash into v_hash from public.member_pins where member_id = p_member;
  if v_hash is null or v_hash <> crypt(p_pin, v_hash) then raise exception '비밀번호가 틀렸어요'; end if;
end $$;
revoke all on function public.check_pin(uuid, text) from public, anon, authenticated;

-- 아이템 고르기 → 코드 지급
create or replace function public.choose_item(p_member uuid, p_pin text, p_slot int, p_item uuid)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  sl public.slots;
  it public.prize_items;
  v_code public.item_codes;
  has_codes boolean;
begin
  perform public.check_pin(p_member, p_pin);
  select * into sl from public.slots where no = p_slot for update;
  if not found or not sl.opened or sl.opened_by is distinct from p_member then
    raise exception '내가 뽑은 쿠폰이 아니에요';
  end if;
  if sl.item_id is not null then
    select * into v_code from public.item_codes where claimed_slot_uid = sl.uid limit 1;
    return jsonb_build_object('item_id', sl.item_id, 'item_name', sl.item_name, 'code', v_code.code, 'already', true);
  end if;
  select * into it from public.prize_items where id = p_item;
  if not found or it.prize_id <> sl.prize_id then raise exception '이 등급에서 고를 수 없는 아이템이에요'; end if;

  select exists (select 1 from public.item_codes where item_id = p_item) into has_codes;
  if has_codes then
    select * into v_code from public.item_codes
      where item_id = p_item and claimed_slot_uid is null
      order by id limit 1 for update skip locked;
    if not found then raise exception '그 아이템은 방금 다 나갔어요. 다른 걸 골라 주세요'; end if;
    update public.item_codes
       set claimed_slot = p_slot, claimed_slot_uid = sl.uid, claimed_by = p_member, claimed_at = now(),
           claimed_name = (select name from public.members where id = p_member)
     where id = v_code.id;
  end if;
  update public.slots set item_id = it.id, item_name = it.name where no = p_slot;
  return jsonb_build_object('item_id', it.id, 'item_name', it.name, 'code', case when has_codes then v_code.code end);
end $$;
revoke all on function public.choose_item(uuid, text, int, uuid) from public;
grant execute on function public.choose_item(uuid, text, int, uuid) to anon, authenticated;

-- 내 당첨 · 코드 보기
create or replace function public.my_wins(p_member uuid, p_pin text)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
begin
  perform public.check_pin(p_member, p_pin);
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'no', s.no, 'prize_id', s.prize_id, 'grade', s.grade, 'name', s.name, 'color', s.color, 'image', s.image,
      'item_id', s.item_id, 'item_name', s.item_name, 'opened_at', s.opened_at,
      'code', (select c.code from public.item_codes c where c.claimed_slot_uid = s.uid limit 1)
    ) order by s.opened_at desc)
    from public.slots s where s.opened and s.opened_by = p_member), '[]'::jsonb)
  -- 라스트원 당첨
  || coalesce((
    select jsonb_build_array(jsonb_build_object('last', true, 'grade', '라스트원', 'name', st.last_one_name, 'item_name', st.last_one_name,
             'color', '#1b1416', 'code', (select value from public.kuji_secrets where key = 'last_one_code')))
    from public.settings st where st.id = 1 and st.last_one_winner = p_member and st.last_one_name <> ''), '[]'::jsonb)
  -- 지난 판에서 받은 코드
  || coalesce((
    select jsonb_agg(jsonb_build_object('past', true, 'item_name', i.name, 'code', c.code, 'opened_at', c.claimed_at) order by c.claimed_at desc)
    from public.item_codes c join public.prize_items i on i.id = c.item_id
    where c.claimed_by = p_member and not exists (select 1 from public.slots s where s.uid = c.claimed_slot_uid)), '[]'::jsonb);
end $$;
revoke all on function public.my_wins(uuid, text) from public;
grant execute on function public.my_wins(uuid, text) to anon, authenticated;

-- ---------- 인증 사진 저장소 ----------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('proofs', 'proofs', true, 5242880, array['image/jpeg', 'image/png', 'image/webp'])
on conflict (id) do nothing;

drop policy if exists "kuji upload proofs" on storage.objects;
drop policy if exists "kuji admin delete proofs" on storage.objects;
create policy "kuji upload proofs" on storage.objects for insert to anon, authenticated
  with check (bucket_id = 'proofs');
create policy "kuji admin delete proofs" on storage.objects for delete
  using (bucket_id = 'proofs' and public.is_admin());

-- ---------- 실시간 반영 ----------
do $$
declare t text;
begin
  foreach t in array array['settings','prizes','members','draws','slots','prize_items'] loop
    begin
      execute format('alter publication supabase_realtime add table public.%I', t);
    exception when others then null;
    end;
  end loop;
end $$;

-- ---------- 길드원 초기 데이터 (11/22 GP 스샷 기준) ----------
insert into public.members (name, base_gp) values
('Genesis.Kyung',133518),('GENESIS.피올',84129),('Genesis.84',75369),('ㅏㅗㄴ',64017),
('[GE] SUNG',61068),('Genesis.도로롱',60866),('우주최강칡',58905),('Dowex',56463),
('Genesis.콜라',52797),('Genesis.은엘',47920),('Genesis.신성',37555),('(이름없음 12위)',28772),
('Genesis.월광',26979),('Genesis.희수',21306),('서리쨩',17045),('Genesis.RJ',16746),
('Genesis.닉스',16700),('Genesis.쾌승',15930),('김치국과 김밥',10823),('Genesis.ksyung',9510),
('디디스',9251),('Genesis.믿음',5810),('Genesis.젤리',4518),('스 파_',4164),
('죽는줄알았다',4116),('Genesis.리치',3423),('금타',3322),('야 돈',2988),
('헤이즈ℓ',2551),('즐겁게살자',1943),('Genesis.결정',1910),('MZ용 =ʚ。ʚ=',1710),
('베르나❤',1256),('이화˚',775),('Genesis.지용',696),('굴착기',625),
('Genesis.승쾌',590),('베르릉',403),('Genesis.주',136),('Genesis.샤갈',74),
('도화에요',13),('심술 독두꺼비',0),('「GE」 지용',0),('Henceforth',0)
on conflict (name) do nothing;
update public.members set last_gp = base_gp where last_gp < base_gp;

-- ---------- 관리자 등록 (본인 이메일로 바꾸기!) ----------
insert into public.admins (email) values ('YOUR_EMAIL@example.com') on conflict do nothing;
