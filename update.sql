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

-- ---------- 뽑기 (서버에서 처리: 확률/포인트 조작 불가) ----------
-- ---------- 뽑기 (서버에서 처리: 확률/GP 계산 조작 불가) ----------
-- 뽑기 가능 GP = 지금 인증한 GP - 기준 GP - 이미 쓴 GP
drop function if exists public.draw_kuji(uuid, text, int, text);
create or replace function public.draw_kuji(p_member uuid, p_pin text, p_count int, p_photo text, p_gp int)
returns jsonb
language plpgsql security definer set search_path = public, extensions as $$
declare
  s public.settings;
  m public.members;
  v_hash text;
  k int;
  avail int;
  left_total int;
  r int;
  p record;
  results jsonb := '[]'::jsonb;
begin
  if p_pin is null or p_pin !~ '^[0-9]{4}$' then
    raise exception '비밀번호는 숫자 4자리로 입력해 주세요';
  end if;
  if p_gp is null or p_gp < 0 then
    raise exception '지금 GP를 입력해 주세요';
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
    raise exception '전에 인증한 GP(%)보다 작아요. 숫자를 다시 확인해 주세요', m.last_gp;
  end if;

  avail := p_gp - m.base_gp - m.used_gp;
  select coalesce(sum(remaining), 0) into left_total from public.prizes;
  k := least(greatest(coalesce(p_count, 0), 0), left_total, greatest(avail, 0) / s.cost);
  if k < 1 then
    raise exception '늘어난 GP가 부족하거나 남은 쿠지가 없어요 (사용 가능 GP: %)', greatest(avail, 0);
  end if;

  for i in 1..k loop
    r := floor(random() * left_total)::int;
    for p in select * from public.prizes where remaining > 0 order by sort, id loop
      r := r - p.remaining;
      if r < 0 then
        update public.prizes set remaining = remaining - 1 where id = p.id;
        results := results || jsonb_build_object('grade', p.grade, 'name', p.name, 'color', p.color, 'image', p.image);
        exit;
      end if;
    end loop;
    left_total := left_total - 1;
  end loop;

  if left_total = 0 and s.last_one_name <> '' and s.last_one_winner is null then
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

notify pgrst, 'reload schema';
