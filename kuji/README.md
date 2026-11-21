# 길드 쿠지 뽑기

길드원은 계정 없이 **닉네임 선택 → 비밀번호 4자리 → 인증 사진 → 뽑기**로 끝.
관리자만 이메일로 로그인해서 GP, 상품, 라스트원을 관리해.

- 뽑기 화면: `https://yejoo0519.github.io/t/kuji/`
- 관리자: `https://yejoo0519.github.io/t/kuji/admin.html`

## 처음 한 번만 하는 설정 (10분)

### 1. Supabase 프로젝트 만들기 (무료)
1. https://supabase.com 가입 → **New project** (지역은 Northeast Asia (Seoul) 추천)
2. 만들어지면 왼쪽 **SQL Editor** → `setup.sql` 내용 통째로 붙여넣기
3. 맨 아래 `YOUR_EMAIL@example.com` 을 **관리자로 쓸 내 이메일**로 바꾸고 **Run**

### 2. 관리자 계정 만들기
1. 왼쪽 **Authentication → Users → Add user → Create new user**
2. 위에서 적은 이메일 + 비밀번호 입력, **Auto Confirm User** 체크
3. **Authentication → Sign In / Providers** 에서 **Allow new users to sign up** 끄기
   (다른 사람이 가입 못 하게)

### 3. 사이트에 연결
1. **Project Settings → API** (또는 Data API) 에서 `Project URL` 과 `anon public` 키 복사
2. 이 저장소 `kuji/config.js` 에 붙여넣고 커밋
   - `service_role` 키는 절대 넣지 마!

### 4. GitHub Pages 켜기 (이미 켜져 있으면 생략)
저장소 **Settings → Pages → Source: Deploy from a branch → main / (root)** → Save

## 운영
- **GP 갱신**: 관리자 → GP 일괄 입력에 `닉네임 GP` 줄로 붙여넣기 (있는 닉은 덮어씀)
- **상품**: 등급 추가 → 상품명/수량 → 상품 저장
- **비밀번호 잊은 길드원**: 길드원 목록에서 `초기화` → 다음 뽑기 때 새로 정함
- **판 새로 시작**: 판 초기화 (남은 수량 원복, 라스트원 당첨 해제, GP는 그대로)

## 안전장치
- 확률 계산, GP 차감, 수량 감소는 전부 **서버(DB 함수)** 에서 처리 → 브라우저 조작으로 결과 못 바꿈
- 동시에 여러 명이 뽑아도 순서대로 처리돼서 같은 티켓 중복 없음
- 사진 한 장은 한 번만 쓸 수 있음
- 비밀번호는 해시로 저장, 다른 사람은 못 봄
