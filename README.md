# 길드 쿠지 뽑기

길드원은 계정 없이 **닉네임 선택 → 비밀번호 4자리 → GP 스샷 → 뽑기**.
GP는 서버가 스샷에서 직접 읽어서(Gemini) 계산해. 브라우저에서 숫자를 보낼 방법이 없어서 조작이 안 돼.

뽑을 수 있는 양 = (스샷 GP − 기준 GP − 이미 쓴 GP) ÷ 1회 GP. 남는 GP는 이월.

- 뽑기: `https://yejoo0519.github.io/t/`
- 관리자: `https://yejoo0519.github.io/t/admin.html`

## 설정

### 1. DB (Supabase SQL Editor)
- 새 프로젝트: `setup.sql` 한 번 Run (맨 아래 관리자 이메일 바꾸기)
- 이미 setup.sql 을 돌린 프로젝트: `migration.sql` → `migration2.sql` 순서로 Run

### 2. 관리자 계정
- **Authentication → Users → Add user** (setup.sql 에 적은 이메일, Auto Confirm 체크)
- **Authentication → Sign In / Providers** 에서 "Allow new users to sign up" 끄기

### 3. Gemini 키 (무료)
- https://aistudio.google.com/apikey → **Create API key** → 복사

### 4. 서버 함수 (Supabase 대시보드)
1. 왼쪽 **Edge Functions → Deploy a new function → Via Editor**
2. 함수 이름: `kuji-draw` (정확히)
3. 기본 코드를 지우고 `supabase/functions/kuji-draw/index.ts` 내용 붙여넣기 → **Deploy**
4. 그 함수 **Details/Settings** 에서 **Verify JWT (Enforce JWT verification) 끄기** → Save
   (publishable 키는 JWT가 아니라서 이게 켜져 있으면 401 에러)
5. **Edge Functions → Secrets** 에 추가
   - `GEMINI_API_KEY` = 3번에서 복사한 키
   - (선택) `GEMINI_MODEL` = 다른 모델 쓰고 싶을 때. 기본 `gemini-3.8-flash`

### 5. 사이트
- `config.js` 에 Project URL + publishable(anon) 키 (이미 넣어둠)
- 저장소 **Settings → Pages → main / (root)**

## 운영
- **새 이벤트 시작**: 관리자 → 기준 GP 일괄 입력 (`닉네임 GP` 한 줄씩). 그 닉의 사용 GP도 0으로
- **상품**: 등급 추가 → 상품명/수량 → 상품 저장
- **비밀번호 잊은 길드원**: 길드원 목록에서 `초기화`
- **판 새로 시작**: 판 초기화 (남은 수량 원복, 라스트원 해제)
- **인식이 틀렸을 때**: 최근 결과에 스샷 + 읽은 GP가 같이 뜸. 관리자에서 최근 인증 GP 수정

## 안전장치
- 스샷 읽기·확률·GP 계산 전부 서버에서. 뽑기 DB 함수는 서버 함수만 호출 가능
- 비밀번호 먼저 확인하고 나서 스샷을 읽음
- 전에 인증한 GP보다 작은 스샷은 거절, 같은 사진 재사용 불가
- 실패한 스샷은 자동 삭제
- 한계: 포토샵으로 숫자를 고친 스샷까지는 못 걸러. 최근 결과의 스샷을 가끔 눈으로 확인해줘
