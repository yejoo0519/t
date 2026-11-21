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

-- ---------- 뽑기 (서버에서 처리: 확률/GP 계산 조작 불가) ----------
-- 안 뜯은 티켓 중에서 무작위로, 늘어난 GP로 되는 만큼만 뽑음
-- 뽑기 가능 GP = 지금 인증한 GP - 기준 GP - 이미 쓴 GP
drop function if exists public.draw_kuji(uuid, text, int, text);
drop function if exists public.draw_kuji(uuid, text, int[], text, int);
create or replace function public.draw_kuji(p_member uuid, p_pin text, p_count int, p_photo text, p_gp int)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  s public.settings;
  m public.members;
  sl public.slots;
  pr public.prizes;
  v_hash text;
  k int := 0;
  can int;
  avail int;
  results jsonb := '[]'::jsonb;
begin
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then
    raise exception '비밀번호는 숫자 4자리로 입력해 주세요';
  end if;
  if p_gp is null or p_gp < 0 then
    raise exception 'GP를 읽지 못했어요';
  end if;
  if p_count is null or p_count < 1 or p_count > 50 then
    raise exception '1~50장 사이로 골라 주세요';
  end if;
  if p_photo is null or not exists (select 1 from storage.objects where bucket_id = 'proofs' and name = p_photo) then
    raise exception '인증 사진이 업로드되지 않았어요';
  end if;
  if exists (select 1 from public.draws where photo = p_photo) then
    raise exception '이미 사용한 사진이에요';
  end if;

  -- 이 줄이 동시 뽑기를 한 줄로 세워줌
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

  avail := p_gp - m.base_gp - m.used_gp;
  can := greatest(avail, 0) / s.cost;
  if can < 1 then
    raise exception '늘어난 GP가 부족해요 (사용 가능 GP: %, 1칸에 %)', greatest(avail, 0), s.cost;
  end if;

  if not exists (select 1 from public.slots where not opened) then
    raise exception '쿠지가 전부 소진됐어요';
  end if;

  for sl in select * from public.slots where not opened order by random() limit least(p_count, can) for update loop
    select * into pr from public.prizes where id = sl.prize_id;
    update public.slots
      set opened = true, opened_by = p_member, opened_name = m.name, opened_at = now(),
          grade = pr.grade, name = pr.name, color = pr.color, image = pr.image
      where no = sl.no;
    update public.prizes set remaining = remaining - 1 where id = pr.id;
    results := results || jsonb_build_object('no', sl.no, 'grade', pr.grade, 'name', pr.name, 'color', pr.color, 'image', pr.image);
    k := k + 1;
  end loop;

  if s.last_one_name <> '' and s.last_one_winner is null
     and not exists (select 1 from public.slots where not opened) then
    update public.settings set last_one_winner = p_member, last_one_winner_name = m.name where id = 1;
    results := results || jsonb_build_object('grade', '라스트원', 'name', s.last_one_name, 'color', '#1b1416', 'last', true);
  end if;

  update public.members set last_gp = p_gp, used_gp = used_gp + k * s.cost where id = p_member;
  insert into public.draws (member_id, name, photo, reported_gp, results, count, spent)
    values (p_member, m.name, p_photo, p_gp, results, k, k * s.cost);

  return jsonb_build_object('results', results, 'count', k, 'spent', k * s.cost);
end $$;

-- 뽑기는 서버 함수(kuji-draw)만 호출 가능
revoke all on function public.draw_kuji(uuid, text, int, text, int) from public, anon, authenticated;
grant execute on function public.draw_kuji(uuid, text, int, text, int) to service_role;

-- AI 호출 전에 비밀번호부터 확인 (비번 없으면 true = 첫 뽑기)
create or replace function public.verify_pin(p_member uuid, p_pin text)
returns boolean
language sql stable security definer set search_path = public, extensions as $$
  select coalesce((select pin_hash = crypt(p_pin, pin_hash) from public.member_pins where member_id = p_member), true);
$$;
revoke all on function public.verify_pin(uuid, text) from public, anon, authenticated;
grant execute on function public.verify_pin(uuid, text) to service_role;

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
  foreach t in array array['settings','prizes','members','draws','slots'] loop
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
