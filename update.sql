-- =========================================================
-- 업데이트 SQL — 지금 DB가 어떤 상태든 이것 하나만 Run 하면 최신 구조가 돼.
-- (여러 번 돌려도 괜찮아)
-- =========================================================

do $$ begin
  if exists (select 1 from information_schema.columns
             where table_schema = 'public' and table_name = 'members' and column_name = 'points') then
    alter table public.members rename column points to base_gp;
  end if;
end $$;
alter table public.members add column if not exists base_gp int not null default 0;
alter table public.members add column if not exists last_gp int not null default 0;
alter table public.members add column if not exists used_gp int not null default 0;
update public.members set last_gp = base_gp where last_gp < base_gp;
alter table public.draws add column if not exists reported_gp int;
alter table public.prizes add column if not exists image text;

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

notify pgrst, 'reload schema';
