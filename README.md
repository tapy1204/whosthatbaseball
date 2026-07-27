# Who's That Baseball ⚾

KBO(한국야구위원회) 선수 데이터를 기반으로 만든 야구 팬 미니게임 모음입니다.

## 게임 소개

### 🎯 Missing9
유명 경기의 라인업에서 빠진 각 포지션의 선수를 맞추는 게임입니다.

### ❓ Who Are Ya
힌트를 보고 어떤 야구선수인지 맞추는 게임입니다.

## 폴더 구조

```
.
├── data/                                  # 전체 원본 데이터 (선수 크롤링 결과 + DB 스키마)
│   ├── kbo_all_players_parsed.json        # 크롤링된 선수 전체 데이터
│   └── kbo_player_schema.sql              # DB 스키마
│
├── missing9/
│   └── public/
│       ├── data/
│       │   └── missing9.json        # 라인업/정답 데이터
│       ├── games/
│       │   ├── missing9.html
│       │   └── missing9-style.css
│       └── image/                    # 도루, 배트 등 게임에 쓰이는 이미지
│
└── whoareya/
    └── public/
        ├── data/
        │   └── players.json          # 게임용으로 가공된 선수 데이터
        ├── games/
        │   ├── whoareya.html
        │   └── whoareya-style.css
        └── image/
            ├── map/                  # 출신 지역 등 지도 관련 이미지
            ├── position/             # 포지션 아이콘
            └── team/                 # 구단 엠블럼
```

## 데이터 출처

선수 데이터는 [KBO 공식 홈페이지](https://www.koreabaseball.com)에서 수집했습니다.
- 기본 프로필(생년월일, 포지션, 신장/체중, 출신교 등)
- 소속 구단 이력, 드래프트 정보, 연봉
- 수상 기록(MVP, 신인상, 골든글러브, 수비상, 올스타전/한국시리즈 MVP 등)
- 특이 기록(20-20, 30-30, 사이클링히트, 한국시리즈 우승, 국가대표 출전 등)

`whoareya/public/data/kbo_player_schema.sql`에 전체 DB 스키마가 정의되어 있습니다.

> KBO 공식 사이트의 robots.txt 정책을 확인한 후 수집했으며, 개인 프로젝트/팬 콘텐츠 목적으로만 사용합니다.

## 실행 방법

정적 페이지라 별도 서버 설정 없이 바로 열어도 되지만, 로컬 fetch(json) 제약 때문에 간단한 로컬 서버로 여는 걸 추천합니다.

```bash
# 예: missing9 실행
cd missing9/public
python3 -m http.server 8000
# 브라우저에서 http://localhost:8000/games/missing9.html 접속

# whoareya 실행
cd whoareya/public
python3 -m http.server 8001
# 브라우저에서 http://localhost:8001/games/whoareya.html 접속
```

## 기술 스택

- HTML / CSS / JavaScript
- 정적 JSON 데이터 파일 (별도 백엔드 없음)
- 데이터 수집: Python (requests, BeautifulSoup, Selenium)
- 데이터 저장/가공: PostgreSQL

## 기여

이슈나 개선 제안은 언제든 환영합니다 🙌
