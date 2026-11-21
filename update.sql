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

  select pin_hash into v_hash from public.member_pins where member_id = p_member;
  if v_hash is null or v_hash <> crypt(coalesce(p_pin, ''), v_hash) then
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
    v_results := v_results || jsonb_build_object('no', v_no, 'grade', pr.grade, 'name', pr.name, 'color', pr.color, 'image', pr.image);
    k := k + 1;
  end loop;

  if s.last_one_name <> '' and s.last_one_winner is null
     and not exists (select 1 from public.slots where not opened) then
    update public.settings set last_one_winner = p_member, last_one_winner_name = m.name where id = 1;
    v_results := v_results || jsonb_build_object('grade', '라스트원', 'name', s.last_one_name, 'color', '#1b1416', 'last', true);
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
