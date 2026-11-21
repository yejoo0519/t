-- =========================================================
-- 업데이트 SQL 2 (11/22): 스샷 자동 인식 방식
-- migration.sql 다음에 한 번 Run.
-- 이제 뽑기는 서버 함수(kuji-draw)만 할 수 있고, 브라우저에서 GP를 직접 못 보냄.
-- =========================================================

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
