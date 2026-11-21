# 길드 쿠지 뽑기

길드원은 계정 없이:
1. **길포 등록** — 닉네임 + 비밀번호 4자리 + GP 스샷 → 서버가 스샷 GP를 읽고 늘어난 만큼 **뽑기권** 지급 (결과창에 표시)
2. **쿠지 고르기** — 접힌 쿠지가 든 박스에서 뽑기권 수만큼 직접 골라서 뜯기 (어느 쿠지에 뭐가 들었는지는 서버만 앎)
3. **판에 붙이기** — 뜯은 결과가 일번쿠지 POP판 등급 줄에 붙음
뽑기권은 남겨뒀다가 나중에 닉네임+비번으로 이어서 뽑아도 됨.
GP는 서버가 스샷에서 직접 읽어서(Claude API) 계산해. 브라우저에서 숫자를 보낼 방법이 없어서 조작이 안 돼.

받는 뽑기권 = (스샷 GP − 기준 GP − 이미 쓴 GP) ÷ 1장 GP. 남는 GP는 이월.

- 뽑기: `https://yejoo0519.github.io/t/`
- 관리자: `https://yejoo0519.github.io/t/admin.html`

## 설정

### 1. DB (Supabase SQL Editor)
- 새 프로젝트: `setup.sql` 한 번 Run (맨 아래 관리자 이메일 바꾸기)
- 이미 setup.sql 을 돌린 프로젝트: `update.sql` 하나만 Run (상태 상관없이 최신으로 맞춰줌, 여러 번 돌려도 OK)

### 2. 관리자 계정
- **Authentication → Users → Add user** (setup.sql 에 적은 이메일, Auto Confirm 체크)
- **Authentication → Sign In / Providers** 에서 "Allow new users to sign up" 끄기

### 3. Claude API 키
- https://console.anthropic.com → **Billing** 에서 크레딧 충전 (최소 금액이면 충분)
- **API Keys → Create Key** → 복사
- 비용: 스샷 1장 인식에 약 $0.005 (Sonnet 기준)

### 4. 서버 함수 (Supabase 대시보드)
1. 왼쪽 **Edge Functions → Deploy a new function → Via Editor**
2. 함수 이름: `kuji-draw` (정확히)
3. 기본 코드를 지우고 `supabase/functions/kuji-draw/index.ts` 내용 붙여넣기 → **Deploy**
4. 그 함수 **Details/Settings** 에서 **Verify JWT (Enforce JWT verification) 끄기** → Save
   (publishable 키는 JWT가 아니라서 이게 켜져 있으면 401 에러)
5. **Edge Functions → Secrets** 에 추가
   - `ANTHROPIC_API_KEY` = 3번에서 복사한 키
   - (선택) `CLAUDE_MODEL` = 기본 `claude-sonnet-5-5`. 더 싸게 하려면 `claude-haiku-5-5`

### 5. 사이트
- `config.js` 에 Project URL + publishable(anon) 키 (이미 넣어둠)
- 저장소 **Settings → Pages → main / (root)**

## 운영
- **새 이벤트 시작**: 관리자 → 기준 GP 일괄 입력 (`닉네임 GP` 한 줄씩). 그 닉의 사용 GP도 0으로
- **상품/판**: 등급 추가 → 상품명(드래곤 이름이면 이미지 자동)/수량 → **상품 저장 + 판 새로 만들기**
- **비밀번호 잊은 길드원**: 길드원 목록에서 `초기화`
- **판 새로 시작**: 같은 상품으로 다시 섞기 (판 비우고 라스트원 해제)
- **인식이 틀렸을 때**: 최근 결과에 스샷 + 읽은 GP가 같이 뜸. 관리자에서 최근 인증 GP 수정

## 안전장치
- 스샷 읽기·확률·GP 계산 전부 서버에서. 뽑기 DB 함수는 서버 함수만 호출 가능
- 비밀번호 먼저 확인하고 나서 스샷을 읽음
- 전에 인증한 GP보다 작은 스샷은 거절, 같은 사진 재사용 불가
- 실패한 스샷은 자동 삭제
- 한계: 포토샵으로 숫자를 고친 스샷까지는 못 걸러. 최근 결과의 스샷을 가끔 눈으로 확인해줘
