-- =============================================================================
-- ALZ-301 simulated multicenter early Alzheimer's disease trial
-- PostgreSQL schema (PostgreSQL 14+)
--
-- Two schemas:
--   trial : the "clinical database" (what an EDC export would give you)
--   sim   : simulation ground truth (which data issues were planted on purpose).
--           Only the validation tests read it. The dashboard and edit checks
--           must never use it, or they would be cheating.
--
-- Design note: single-table rules (score ranges, allowed status values) are
-- enforced with CHECK constraints, like range checks at data entry in an EDC.
-- Cross-table date logic (visit before consent, visit outside its window,
-- visit after discontinuation) is deliberately NOT enforced here. Those are
-- the post-entry edit checks written in R, which raise queries for a data
-- manager instead of rejecting the data.
--
-- Running this file drops and recreates both schemas (all data is lost).
-- =============================================================================

DROP SCHEMA IF EXISTS trial CASCADE;
DROP SCHEMA IF EXISTS sim CASCADE;
CREATE SCHEMA trial;
CREATE SCHEMA sim;

SET search_path TO trial;

-- ---------------------------------------------------------------------------
-- Reference / study design tables
-- ---------------------------------------------------------------------------

CREATE TABLE study (
    study_id            varchar(20) PRIMARY KEY,
    study_title         text        NOT NULL,
    phase               varchar(10) NOT NULL,
    target_enrollment   integer     NOT NULL CHECK (target_enrollment > 0),
    study_start_date    date        NOT NULL,
    planned_enrollment_end_date date NOT NULL,   -- plan: enrollment linear from start to here
    data_cutoff_date    date        NOT NULL,
    CHECK (data_cutoff_date > study_start_date),
    CHECK (planned_enrollment_end_date > study_start_date)
);

CREATE TABLE study_arms (
    arm_code    varchar(10) PRIMARY KEY,
    arm_name    text        NOT NULL,
    arm_order   integer     NOT NULL UNIQUE
);

CREATE TABLE sites (
    site_id                 varchar(5)  PRIMARY KEY,
    site_name               text        NOT NULL,
    country                 varchar(40) NOT NULL,
    city                    varchar(60) NOT NULL,
    principal_investigator  text        NOT NULL,
    activation_date         date        NOT NULL,
    target_enrollment       integer     NOT NULL CHECK (target_enrollment > 0)
);

-- Protocol visit schedule. Study day convention (CDISC): baseline = Day 1,
-- the day before baseline = Day -1 (there is no Day 0).
-- A visit is in window when window_start_day <= study day <= window_end_day.
CREATE TABLE visit_schedule (
    visit_code          varchar(10) PRIMARY KEY,
    visit_name          text        NOT NULL,
    visit_order         integer     NOT NULL UNIQUE,
    target_day          integer     NOT NULL,
    window_start_day    integer     NOT NULL,
    window_end_day      integer     NOT NULL,
    CHECK (window_start_day <= target_day AND target_day <= window_end_day)
);

CREATE TABLE forms (
    form_code       varchar(10) PRIMARY KEY,
    form_name       text        NOT NULL,
    form_category   varchar(20) NOT NULL
        CHECK (form_category IN ('Administrative', 'Safety', 'Efficacy'))
);

-- Which eCRF forms are expected at which visit (the "schedule of assessments").
CREATE TABLE form_schedule (
    visit_code  varchar(10) NOT NULL REFERENCES visit_schedule (visit_code),
    form_code   varchar(10) NOT NULL REFERENCES forms (form_code),
    PRIMARY KEY (visit_code, form_code)
);

-- ---------------------------------------------------------------------------
-- Subject-level and visit-level data
-- ---------------------------------------------------------------------------

CREATE TABLE subjects (
    subject_id              varchar(12) PRIMARY KEY,         -- e.g. 104-0012
    site_id                 varchar(5)  NOT NULL REFERENCES sites (site_id),
    consent_date            date        NOT NULL,
    screening_date          date        NOT NULL,
    sex                     char(1)     NOT NULL CHECK (sex IN ('F', 'M')),
    age_at_consent          integer     NOT NULL CHECK (age_at_consent BETWEEN 50 AND 90),
    education_years         integer     CHECK (education_years BETWEEN 0 AND 25),
    apoe4_carrier           boolean,
    subject_status          varchar(20) NOT NULL
        CHECK (subject_status IN ('Screening', 'Screen Failed', 'Ongoing',
                                  'Discontinued', 'Completed')),
    screen_fail_reason      text,
    randomization_date      date,
    arm_code                varchar(10) REFERENCES study_arms (arm_code),
    discontinuation_date    date,
    discontinuation_reason  text,
    CHECK ((subject_status = 'Screen Failed') = (screen_fail_reason IS NOT NULL)),
    CHECK ((arm_code IS NULL) = (randomization_date IS NULL)),
    CHECK ((subject_status = 'Discontinued') = (discontinuation_date IS NOT NULL))
);

CREATE TABLE visits (
    visit_id        integer     PRIMARY KEY,
    subject_id      varchar(12) NOT NULL REFERENCES subjects (subject_id),
    visit_code      varchar(10) NOT NULL REFERENCES visit_schedule (visit_code),
    visit_date      date,                                    -- NULL when missed
    visit_status    varchar(10) NOT NULL CHECK (visit_status IN ('Completed', 'Missed')),
    UNIQUE (subject_id, visit_code),
    CHECK ((visit_status = 'Completed') = (visit_date IS NOT NULL))
);

-- One row per eCRF form that has data entered. Expected-but-absent forms have
-- NO row: "missing eCRFs" = form_schedule rows with no matching ecrf_forms row.
CREATE TABLE ecrf_forms (
    ecrf_id         integer     PRIMARY KEY,
    visit_id        integer     NOT NULL REFERENCES visits (visit_id),
    form_code       varchar(10) NOT NULL REFERENCES forms (form_code),
    form_status     varchar(15) NOT NULL CHECK (form_status IN ('Entered', 'SDV Complete')),
    entered_date    date        NOT NULL,
    sdv_date        date,                                    -- source data verification
    UNIQUE (visit_id, form_code),
    CHECK ((form_status = 'SDV Complete') = (sdv_date IS NOT NULL)),
    CHECK (sdv_date IS NULL OR sdv_date >= entered_date)
);

-- Cognitive assessment totals.
--   MMSE      0-30, integer,          lower = worse
--   CDRSB     0-18, 0.5 increments,   higher = worse
--   ADAS13    0-85, integer here,     higher = worse
CREATE TABLE cognitive_assessments (
    assessment_id   integer      PRIMARY KEY,
    ecrf_id         integer      NOT NULL UNIQUE REFERENCES ecrf_forms (ecrf_id),
    visit_id        integer      NOT NULL REFERENCES visits (visit_id),
    instrument      varchar(10)  NOT NULL CHECK (instrument IN ('MMSE', 'CDRSB', 'ADAS13')),
    assessment_date date         NOT NULL,
    total_score     numeric(4,1) NOT NULL,
    rater_id        varchar(10),
    UNIQUE (visit_id, instrument),
    CHECK (
        (instrument = 'MMSE'   AND total_score BETWEEN 0 AND 30 AND total_score = trunc(total_score)) OR
        (instrument = 'CDRSB'  AND total_score BETWEEN 0 AND 18 AND total_score * 2 = trunc(total_score * 2)) OR
        (instrument = 'ADAS13' AND total_score BETWEEN 0 AND 85)
    )
);

-- ---------------------------------------------------------------------------
-- Data queries (manual CRA queries are simulated; edit checks add their own)
-- ---------------------------------------------------------------------------

CREATE TABLE queries (
    query_id        bigint      GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
    site_id         varchar(5)  NOT NULL REFERENCES sites (site_id),
    subject_id      varchar(12) NOT NULL REFERENCES subjects (subject_id),
    visit_id        integer     REFERENCES visits (visit_id),
    form_code       varchar(10) REFERENCES forms (form_code),
    check_id        varchar(20),                             -- edit check that raised it
    query_source    varchar(12) NOT NULL CHECK (query_source IN ('Manual', 'Edit check')),
    query_text      text        NOT NULL,
    query_status    varchar(10) NOT NULL CHECK (query_status IN ('Open', 'Answered', 'Closed')),
    opened_date     date        NOT NULL,
    answered_date   date,
    closed_date     date,
    CHECK (answered_date IS NULL OR answered_date >= opened_date),
    CHECK (closed_date   IS NULL OR closed_date   >= opened_date),
    CHECK (
        (query_status = 'Open'     AND answered_date IS NULL AND closed_date IS NULL) OR
        (query_status = 'Answered' AND answered_date IS NOT NULL AND closed_date IS NULL) OR
        (query_status = 'Closed'   AND closed_date IS NOT NULL)
    )
);

CREATE INDEX ix_subjects_site      ON subjects (site_id);
CREATE INDEX ix_visits_subject     ON visits (subject_id);
CREATE INDEX ix_ecrf_visit         ON ecrf_forms (visit_id);
CREATE INDEX ix_assess_visit       ON cognitive_assessments (visit_id);
CREATE INDEX ix_queries_site       ON queries (site_id, query_status);

-- ---------------------------------------------------------------------------
-- Simulation ground truth (for validation tests only)
-- ---------------------------------------------------------------------------

CREATE TABLE sim.injected_issues (
    issue_id    integer     PRIMARY KEY,
    issue_type  varchar(30) NOT NULL
        CHECK (issue_type IN ('OUT_OF_WINDOW', 'MISSING_ECRF',
                              'IMPLAUSIBLE_CHANGE', 'INCONSISTENT_DATE')),
    subtype     varchar(40),
    site_id     varchar(5)  NOT NULL,
    subject_id  varchar(12) NOT NULL,
    visit_code  varchar(10),
    form_code   varchar(10),
    detail      text
);
