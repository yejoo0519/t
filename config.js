// Supabase 대시보드 > Project Settings > API 에서 복사해서 붙여넣기
// anon key 는 공개돼도 괜찮은 키야 (권한은 setup.sql 의 보안 규칙이 막아줌).
// service_role key 는 절대 여기 넣지 마!
window.KUJI_CONFIG = {
  url: "https://yevbwmznscqqtcdpqaol.supabase.co",
  anonKey: "sb_publishable_tyVCPEuerIPDBFFv2WAecA_D0pIsDgf",
  openAt: "2026-11-25T00:10:00+09:00",   // 이벤트 시작 시각 (DB 설정이 있으면 그게 우선)
  fn: "clever-service"   // Edge Function 주소(slug). 대시보드에서 이름만 kuji-draw로 바꿔서 주소는 이대로
};
