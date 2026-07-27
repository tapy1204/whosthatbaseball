-- =========================================================
-- KBO 선수 정보 크롤링 DB 스키마 (PostgreSQL 기준)
-- 설계 원칙:
--  1) "여러 개 존재 가능한 정보"(소속 구단, 감독, 수상)는 반드시 별도 테이블로 분리 (1:N)
--  2) 팀 개명/연고 이전(현대->히어로즈->넥센->키움 등)은 franchise_id로 묶어서 추적
--  3) 아직 정제 전인 값(드래프트 정보 등)은 raw_text 컬럼에 그대로 저장 -> 나중에 파싱
--  4) CHECK / UNIQUE 제약으로 "종료일 < 시작일" 같은 데이터 오류를 DB 단에서 원천 차단
--  5) 크롤링 출처(source_url) / 수집시각(crawled_at)을 모든 원본성 테이블에 남겨 재크롤링·검증 가능하게 함
-- =========================================================

-- ---------------------------------------------------------
-- 0. 공통 ENUM 타입
-- ---------------------------------------------------------
CREATE TYPE hand_type AS ENUM ('R', 'L', 'S');          -- 우/좌/양(스위치)
CREATE TYPE position_type AS ENUM (
    'P','C','1B','2B','3B','SS','LF','CF','RF','DH','UTIL'
);

-- ---------------------------------------------------------
-- 1. 구단 마스터 (개명/연고이전 대응)
-- ---------------------------------------------------------
CREATE TABLE franchises (
    franchise_id    SERIAL PRIMARY KEY,
    franchise_name  VARCHAR(50) NOT NULL UNIQUE  -- 예: '넥센/키움 계열'처럼 식별용 대표명
);

CREATE TABLE teams (
    team_id         SERIAL PRIMARY KEY,
    franchise_id    INT NOT NULL REFERENCES franchises(franchise_id),
    team_name       VARCHAR(50) NOT NULL,   -- 예: '현대 유니콘스', '넥센 히어로즈', '키움 히어로즈'
    start_year      INT NOT NULL,           -- 해당 팀명 사용 시작 연도
    end_year        INT,                    -- NULL이면 현재도 사용 중인 팀명
    CONSTRAINT uq_team_name UNIQUE (team_name),
    CONSTRAINT ck_team_year CHECK (end_year IS NULL OR end_year >= start_year)
);

-- ---------------------------------------------------------
-- 2. 고교 마스터 (출신고교)
-- ---------------------------------------------------------
CREATE TABLE schools (
    school_id       SERIAL PRIMARY KEY,
    school_name     VARCHAR(50) NOT NULL UNIQUE
);

-- ---------------------------------------------------------
-- 3. 선수 기본 정보
-- ---------------------------------------------------------
CREATE TABLE players (
    player_id           SERIAL PRIMARY KEY,
    name                VARCHAR(30) NOT NULL,
    birth_date          DATE,
    debut_year           INT,                     -- 입단년도
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,  -- 현역여부 O/X
    position_primary    position_type,            -- 주 포지션 (여러 포지션 소화 시 player_positions 참고)
    position_detail_raw VARCHAR(30),               -- 크롤링 원문 (예: "내야수", "포수(우투우타)") -- UTIL로 뭉개지는 세부 정보 보존용
    throwing_hand       hand_type,                -- 투구 방향
    batting_hand        hand_type,                -- 타격 방향
    school_id           INT REFERENCES schools(school_id),
    current_team_id     INT REFERENCES teams(team_id),  -- 현재(혹은 마지막) 소속 팀 캐시
    last_jersey_number   INT,                      -- 마지막 등번호 (캐시, 실제 이력은 아래 테이블)
    height_cm           INT,                       -- 신장 (크롤링 시 "178cm/81kg"에서 파싱)
    weight_kg           INT,                       -- 체중

    -- 크롤링 메타데이터
    source_url          TEXT,
    crawled_at          TIMESTAMPTZ,
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT now(),

    CONSTRAINT uq_player UNIQUE (name, birth_date)  -- 동명이인 방지용 (이름+생년월일로 유일성 확보)
);

CREATE INDEX idx_players_active ON players(is_active);
CREATE INDEX idx_players_team ON players(current_team_id);

-- ---------------------------------------------------------
-- 4. 선수 - 소속 구단 이력 (핵심: 1명 선수가 여러 팀을 거침)
-- ---------------------------------------------------------
CREATE TABLE player_team_history (
    id              SERIAL PRIMARY KEY,
    player_id       INT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    team_id         INT NOT NULL REFERENCES teams(team_id),
    start_year      INT NOT NULL,
    end_year        INT,             -- NULL = 현재 소속 중
    jersey_number   INT,             -- 해당 기간 동안의 등번호
    note            VARCHAR(100),     -- 트레이드/방출/은퇴 등 사유 (있으면 크롤링해서 채움)

    CONSTRAINT ck_history_year CHECK (end_year IS NULL OR end_year >= start_year),
    CONSTRAINT uq_player_team_start UNIQUE (player_id, team_id, start_year)
);

CREATE INDEX idx_pth_player ON player_team_history(player_id);
CREATE INDEX idx_pth_team ON player_team_history(team_id);

-- 같은 선수가 동일 기간에 두 팀에 동시 소속되는 오류 방지 (기간 겹침 방지, PostgreSQL만 가능)
-- daterange로 변환해 겹침을 막고 싶다면 아래처럼 EXCLUDE 제약 사용 가능 (선택사항):
-- ALTER TABLE player_team_history ADD COLUMN period daterange
--   GENERATED ALWAYS AS (daterange(make_date(start_year,1,1), COALESCE(make_date(end_year,12,31), 'infinity'::date), '[]')) STORED;
-- CREATE EXTENSION IF NOT EXISTS btree_gist;
-- ALTER TABLE player_team_history ADD CONSTRAINT no_overlap
--   EXCLUDE USING gist (player_id WITH =, period WITH &&);

-- ---------------------------------------------------------
-- 5. 드래프트 정보 (정제 X, 원본 그대로 저장 후 추후 파싱)
-- ---------------------------------------------------------
CREATE TABLE draft_records (
    id              SERIAL PRIMARY KEY,
    player_id       INT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    draft_year      INT,             -- 파악 가능하면 채우고, 안되면 NULL
    raw_text        TEXT NOT NULL,    -- 크롤링한 원문 그대로 (예: "2015 2차 3라운드 25순위 SK")
    -- 아래는 나중에 raw_text를 파싱해서 채울 정제 컬럼 (지금은 전부 NULL 허용)
    parsed_round     INT,
    parsed_pick      INT,
    parsed_team_id   INT REFERENCES teams(team_id),
    signing_bonus_10k_won  INT,   -- 입단 계약금 (단위: 만원). 드래프트/입단 시 1회성 금액이라 여기 같이 저장

    source_url      TEXT,
    crawled_at      TIMESTAMPTZ
);

CREATE INDEX idx_draft_player ON draft_records(player_id);

-- ---------------------------------------------------------
-- 5b. 선수 연봉 이력 (연도별로 바뀌는 값이라 별도 테이블로 분리)
-- ---------------------------------------------------------
CREATE TABLE player_salaries (
    id              SERIAL PRIMARY KEY,
    player_id       INT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    year            INT NOT NULL,           -- 크롤링 시점 기준 연도 (예: 2026년에 크롤링했으면 2026)
    salary_10k_won  INT,                    -- 연봉 (단위: 만원)
    source_url      TEXT,
    crawled_at      TIMESTAMPTZ,

    CONSTRAINT uq_player_salary_year UNIQUE (player_id, year)  -- 같은 해 연봉 중복 저장 방지
);

CREATE INDEX idx_salary_player ON player_salaries(player_id);

-- ---------------------------------------------------------
-- 6. 구단별 연도별 감독 이력
--    한 해에 감독이 여러 번 바뀌어도(시즌 중 경질 등), 같은 연도값을 가진 row가
--    여러 개 들어가는 것을 허용 -> 순서/겹침을 DB가 강제로 막지는 않음 (단순 연 단위 기록용)
-- ---------------------------------------------------------
CREATE TABLE team_managers (
    id              SERIAL PRIMARY KEY,
    team_id         INT NOT NULL REFERENCES teams(team_id),
    manager_name    VARCHAR(30) NOT NULL,
    start_year      INT NOT NULL,
    end_year        INT,             -- NULL = 현재 재임 중
    is_interim      BOOLEAN NOT NULL DEFAULT FALSE,  -- 감독대행 여부
    reason          VARCHAR(50),      -- 경질 / 사임 / 계약만료 / 시즌종료 등 (크롤링되면 채움)

    source_url      TEXT,
    crawled_at      TIMESTAMPTZ,

    CONSTRAINT ck_manager_year CHECK (end_year IS NULL OR end_year >= start_year)
);

CREATE INDEX idx_manager_team ON team_managers(team_id);

-- ---------------------------------------------------------
-- 7. 수상/기록 마스터 + 선수별 수상 이력
--    (골든글러브, 완봉, MVP, 신인상, 다승왕, 타격왕, 수비상, 20-20, 올스타 등)
-- ---------------------------------------------------------
CREATE TABLE award_types (
    award_type_id   SERIAL PRIMARY KEY,
    award_name      VARCHAR(50) NOT NULL UNIQUE,   -- '골든글러브','MVP','신인상','다승왕','타격왕','수비상','20-20','올스타','완봉' 등
    category        VARCHAR(30)                     -- '시즌기록' / '연말시상' / '올스타' 등 분류용 (선택)
);

CREATE TABLE player_awards (
    id              SERIAL PRIMARY KEY,
    player_id       INT NOT NULL REFERENCES players(player_id) ON DELETE CASCADE,
    award_type_id   INT NOT NULL REFERENCES award_types(award_type_id),
    year            INT NOT NULL,
    detail          VARCHAR(200),  -- 세부사항 (예: 골든글러브 '유격수 부문', 완봉 '3회', 20-20 '25홈런-32도루' 등)
    source_url      TEXT,
    crawled_at      TIMESTAMPTZ
);

CREATE INDEX idx_award_player ON player_awards(player_id);
CREATE INDEX idx_award_type_year ON player_awards(award_type_id, year);

-- 주의: UNIQUE 제약을 detail 컬럼에 그대로 걸면 안 됨 -> PostgreSQL은 NULL을 항상 "서로 다른 값"으로
-- 취급해서, detail이 NULL인 기록(MVP/신인상처럼 세부내용이 없는 경우)은 몇 번을 다시 넣어도
-- 중복으로 안 걸리고 계속 쌓임. COALESCE로 NULL을 빈 문자열 취급하는 표현식 인덱스를 써야 함.
CREATE UNIQUE INDEX uq_player_award_idx ON player_awards (player_id, award_type_id, year, COALESCE(detail, ''));

-- ---------------------------------------------------------
-- 8. (선택) 크롤링 원본 스테이징 테이블
--    정제되지 않은 크롤링 결과를 일단 통째로 넣어두고,
--    검수 후 위 정규화 테이블로 옮기는 용도 (크롤링 파이프라인 안정성 확보)
-- ---------------------------------------------------------
CREATE TABLE raw_crawl_staging (
    id              SERIAL PRIMARY KEY,
    source_url      TEXT NOT NULL,
    raw_json        JSONB NOT NULL,     -- 크롤링한 원본 그대로 (구조 상관없이 저장)
    is_processed    BOOLEAN NOT NULL DEFAULT FALSE,
    crawled_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    processed_at    TIMESTAMPTZ
);

CREATE INDEX idx_staging_processed ON raw_crawl_staging(is_processed);
