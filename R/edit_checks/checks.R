# =============================================================================
# ALZ-301 edit checks and post-entry checks
#
# Each check is a plain function of data frames (no database access), so it can
# be unit-tested with small hand-made examples. Every check returns findings in
# the same shape (see FINDING_COLS). The specification for each check ID is in
# docs/edit_check_specification.md; keep the two in step.
# =============================================================================

suppressPackageStartupMessages(library(dplyr))

FINDING_COLS <- c("check_id", "check_name", "site_id", "subject_id", "visit_id",
                  "visit_code", "form_code", "query_text")

# Score change thresholds between consecutive assessments (absolute change).
SCORE_CHANGE_THRESHOLDS <- c(MMSE = 5, CDRSB = 3, ADAS13 = 12)
INSTRUMENT_CHECK_ID     <- c(MMSE = "EC_SC01", CDRSB = "EC_SC02", ADAS13 = "EC_SC03")
INSTRUMENT_FORM         <- c(MMSE = "MMSE", CDRSB = "CDRSB", ADAS13 = "ADAS")

# CDISC study day: baseline = Day 1, the day before = Day -1, no Day 0.
study_day <- function(date, baseline) {
  d <- as.integer(date - baseline)
  ifelse(d >= 0, d + 1L, d)
}

fmt_date <- function(x) format(as.Date(x), "%Y-%m-%d")

empty_findings <- function() {
  tibble::tibble(check_id = character(), check_name = character(), site_id = character(),
                 subject_id = character(), visit_id = integer(), visit_code = character(),
                 form_code = character(), query_text = character())
}

as_findings <- function(df) {
  if (!nrow(df)) return(empty_findings())
  df |>
    mutate(visit_id = as.integer(visit_id), form_code = as.character(form_code)) |>
    select(all_of(FINDING_COLS))
}

with_site <- function(df, subjects) {
  df |> inner_join(select(subjects, subject_id, site_id), by = "subject_id")
}

baseline_dates <- function(visits) {
  visits |>
    filter(visit_code == "BL", visit_status == "Completed") |>
    select(subject_id, baseline_date = visit_date)
}

# -----------------------------------------------------------------------------
# EC_VW01 / EC_VW02  Visit outside its protocol window
# -----------------------------------------------------------------------------
check_visit_windows <- function(visits, subjects, visit_schedule) {
  visits |>
    filter(visit_status == "Completed", visit_code != "BL") |>
    inner_join(baseline_dates(visits), by = "subject_id") |>
    inner_join(visit_schedule, by = "visit_code") |>
    mutate(sday = study_day(visit_date, baseline_date)) |>
    filter(sday < window_start_day | sday > window_end_day) |>
    with_site(subjects) |>
    mutate(
      check_id = if_else(visit_code == "SCR", "EC_VW02", "EC_VW01"),
      check_name = if_else(visit_code == "SCR", "Screening outside Day -28 to -1",
                           "Visit out of window"),
      form_code = NA_character_,
      query_text = sprintf(
        "%s visit on %s is study day %d (%d days %s window Day %d to %d). Please confirm the visit date or record a protocol deviation.",
        visit_code, fmt_date(visit_date), sday,
        if_else(sday < window_start_day, window_start_day - sday, sday - window_end_day),
        if_else(sday < window_start_day, "before", "after"),
        window_start_day, window_end_day)
    ) |>
    as_findings()
}

# -----------------------------------------------------------------------------
# EC_MF01  Expected eCRF form not entered
# -----------------------------------------------------------------------------
check_missing_ecrfs <- function(visits, subjects, form_schedule, ecrf_forms, cutoff,
                                grace_days = 14) {
  cutoff <- as.Date(cutoff)
  visits |>
    filter(visit_status == "Completed", visit_date <= cutoff - grace_days) |>
    inner_join(form_schedule, by = "visit_code", relationship = "many-to-many") |>
    anti_join(ecrf_forms, by = c("visit_id", "form_code")) |>
    with_site(subjects) |>
    mutate(
      check_id = "EC_MF01",
      check_name = "Missing eCRF",
      query_text = sprintf(
        "%s form has not been entered for the %s visit on %s (%d days before data cutoff). Please enter the data or confirm the assessment was not done.",
        form_code, visit_code, fmt_date(visit_date), as.integer(cutoff - visit_date))
    ) |>
    as_findings()
}

# -----------------------------------------------------------------------------
# EC_SC01-03  Implausible change between consecutive assessments
# Consecutive = by protocol visit order, not by date (dates may be wrong).
# -----------------------------------------------------------------------------
check_score_changes <- function(assessments, visits, subjects, visit_schedule,
                                thresholds = SCORE_CHANGE_THRESHOLDS) {
  assessments |>
    inner_join(select(visits, visit_id, subject_id, visit_code), by = "visit_id") |>
    inner_join(select(visit_schedule, visit_code, visit_order), by = "visit_code") |>
    arrange(subject_id, instrument, visit_order) |>
    group_by(subject_id, instrument) |>
    mutate(prev_score = lag(total_score), prev_visit = lag(visit_code)) |>
    ungroup() |>
    mutate(change = total_score - prev_score,
           limit = unname(thresholds[instrument])) |>
    filter(!is.na(change), abs(change) >= limit) |>
    with_site(subjects) |>
    mutate(
      check_id = unname(INSTRUMENT_CHECK_ID[instrument]),
      check_name = paste(instrument, "implausible change"),
      form_code = unname(INSTRUMENT_FORM[instrument]),
      query_text = sprintf(
        "%s total changed from %s at %s to %s at %s (%+g; check limit %g). Please verify both scores against source.",
        instrument, format(prev_score), prev_visit, format(total_score), visit_code, change, limit)
    ) |>
    as_findings()
}

# -----------------------------------------------------------------------------
# EC_DT01  Visit before informed consent
# -----------------------------------------------------------------------------
check_visit_before_consent <- function(visits, subjects) {
  visits |>
    filter(visit_status == "Completed") |>
    inner_join(select(subjects, subject_id, site_id, consent_date), by = "subject_id") |>
    filter(visit_date < consent_date) |>
    mutate(check_id = "EC_DT01", check_name = "Visit before informed consent",
           form_code = NA_character_,
           query_text = sprintf(
             "%s visit on %s is before the informed consent date %s. Please verify the consent and visit dates.",
             visit_code, fmt_date(visit_date), fmt_date(consent_date))) |>
    as_findings()
}

# -----------------------------------------------------------------------------
# EC_DT02  Randomization date differs from the baseline visit date
# -----------------------------------------------------------------------------
check_randomization_date <- function(visits, subjects) {
  subjects |>
    filter(!is.na(randomization_date)) |>
    inner_join(filter(visits, visit_code == "BL", visit_status == "Completed"),
               by = "subject_id") |>
    filter(randomization_date != visit_date) |>
    mutate(check_id = "EC_DT02", check_name = "Randomization date not equal to baseline",
           form_code = NA_character_,
           query_text = sprintf(
             "Randomization date %s does not match the Baseline visit date %s. Per protocol they should be the same day. Please verify.",
             fmt_date(randomization_date), fmt_date(visit_date))) |>
    as_findings()
}

# -----------------------------------------------------------------------------
# EC_DT03  Visit after discontinuation
# -----------------------------------------------------------------------------
check_visit_after_discontinuation <- function(visits, subjects) {
  visits |>
    filter(visit_status == "Completed") |>
    inner_join(select(subjects, subject_id, site_id, discontinuation_date), by = "subject_id") |>
    filter(!is.na(discontinuation_date), visit_date > discontinuation_date) |>
    mutate(check_id = "EC_DT03", check_name = "Visit after discontinuation",
           form_code = NA_character_,
           query_text = sprintf(
             "%s visit on %s is after the discontinuation date %s. Please verify the discontinuation date or the visit.",
             visit_code, fmt_date(visit_date), fmt_date(discontinuation_date))) |>
    as_findings()
}

# -----------------------------------------------------------------------------
# EC_DT04  Assessment date differs from its visit date
# -----------------------------------------------------------------------------
check_assessment_dates <- function(assessments, visits, subjects) {
  assessments |>
    inner_join(select(visits, visit_id, subject_id, visit_code, visit_date), by = "visit_id") |>
    filter(assessment_date != visit_date) |>
    with_site(subjects) |>
    mutate(check_id = "EC_DT04", check_name = "Assessment date not equal to visit date",
           form_code = unname(INSTRUMENT_FORM[instrument]),
           query_text = sprintf(
             "%s assessment date %s differs from the %s visit date %s. Please correct or explain.",
             instrument, fmt_date(assessment_date), visit_code, fmt_date(visit_date))) |>
    as_findings()
}

# -----------------------------------------------------------------------------
# EC_DT05  eCRF entered before the visit took place
# -----------------------------------------------------------------------------
check_entry_before_visit <- function(ecrf_forms, visits, subjects) {
  ecrf_forms |>
    inner_join(select(visits, visit_id, subject_id, visit_code, visit_date), by = "visit_id") |>
    filter(entered_date < visit_date) |>
    with_site(subjects) |>
    mutate(check_id = "EC_DT05", check_name = "eCRF entered before visit",
           query_text = sprintf(
             "%s form for the %s visit was entered on %s, before the visit date %s. Please verify the visit date.",
             form_code, visit_code, fmt_date(entered_date), fmt_date(visit_date))) |>
    as_findings()
}

# -----------------------------------------------------------------------------
# Run everything
# -----------------------------------------------------------------------------
CHECK_CATALOG <- tibble::tribble(
  ~check_id, ~category,
  "EC_VW01", "Visit window",
  "EC_VW02", "Visit window",
  "EC_MF01", "Missing eCRF",
  "EC_SC01", "Score change",
  "EC_SC02", "Score change",
  "EC_SC03", "Score change",
  "EC_DT01", "Date consistency",
  "EC_DT02", "Date consistency",
  "EC_DT03", "Date consistency",
  "EC_DT04", "Date consistency",
  "EC_DT05", "Date consistency"
)

# tbls: named list from load_trial_tables(). Returns findings sorted site by site.
run_all_checks <- function(tbls, cutoff = tbls$study$data_cutoff_date[1], grace_days = 14) {
  bind_rows(
    check_visit_windows(tbls$visits, tbls$subjects, tbls$visit_schedule),
    check_missing_ecrfs(tbls$visits, tbls$subjects, tbls$form_schedule, tbls$ecrf_forms,
                        cutoff, grace_days),
    check_score_changes(tbls$cognitive_assessments, tbls$visits, tbls$subjects,
                        tbls$visit_schedule),
    check_visit_before_consent(tbls$visits, tbls$subjects),
    check_randomization_date(tbls$visits, tbls$subjects),
    check_visit_after_discontinuation(tbls$visits, tbls$subjects),
    check_assessment_dates(tbls$cognitive_assessments, tbls$visits, tbls$subjects),
    check_entry_before_visit(tbls$ecrf_forms, tbls$visits, tbls$subjects)
  ) |>
    left_join(CHECK_CATALOG, by = "check_id") |>
    left_join(select(tbls$visit_schedule, visit_code, visit_order), by = "visit_code") |>
    arrange(site_id, subject_id, visit_order, check_id, form_code) |>
    select(-visit_order)
}

# Attach the status of any query already raised for the same finding, so a data
# manager sees which items are new. Key: check + subject + visit + form.
attach_query_status <- function(findings, queries) {
  existing <- queries |>
    filter(query_source == "Edit check") |>
    select(check_id, subject_id, visit_id, form_code, query_id, query_status) |>
    mutate(visit_id = as.integer(visit_id))
  findings |>
    left_join(existing, by = c("check_id", "subject_id", "visit_id", "form_code")) |>
    mutate(query_status = coalesce(query_status, "New"))
}
