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
    throwing_hand       hand_type,                -- 투구 방향
    batting_hand        hand_type,                -- 타격 방향
    school_id           INT REFERENCES schools(school_id),
    current_team_id     INT REFERENCES teams(team_id),  -- 현재(혹은 마지막) 소속 팀 캐시
    last_jersey_number   INT,                      -- 마지막 등번호 (캐시, 실제 이력은 아래 테이블)

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

    source_url      TEXT,
    crawled_at      TIMESTAMPTZ
);

CREATE INDEX idx_draft_player ON draft_records(player_id);

-- ---------------------------------------------------------
-- 6. 구단별 연도별 감독 이력
-- ---------------------------------------------------------
CREATE TABLE team_managers (
    id              SERIAL PRIMARY KEY,
    team_id         INT NOT NULL REFERENCES teams(team_id),
    manager_name    VARCHAR(30) NOT NULL,
    start_year      INT NOT NULL,
    end_year        INT,
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
    crawled_at      TIMESTAMPTZ,

    CONSTRAINT uq_player_award UNIQUE (player_id, award_type_id, year, detail)
);

CREATE INDEX idx_award_player ON player_awards(player_id);
CREATE INDEX idx_award_type_year ON player_awards(award_type_id, year);

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
