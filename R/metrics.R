# =============================================================================
# Monitoring metrics shared by the Shiny dashboard and the R Markdown reports.
# Plain functions of the table list from load_trial_tables(); no database code.
# Needs R/edit_checks/checks.R (study_day, check_missing_ecrfs) sourced first.
# =============================================================================

suppressPackageStartupMessages(library(dplyr))

AGE_BUCKETS <- c("0-14 days", "15-30 days", "31-60 days", "Over 60 days")
VISIT_OUTCOMES <- c("In window", "Out of window", "Missed", "Overdue, not recorded")

# Keep only the chosen sites and arms. Choosing arms keeps randomized subjects
# only (screen failures have no arm). NULL or empty means "all".
filter_trial <- function(tbls, sites = NULL, arms = NULL) {
  subj <- tbls$subjects
  if (length(sites)) subj <- filter(subj, site_id %in% sites)
  if (length(arms))  subj <- filter(subj, arm_code %in% arms)
  keep <- subj$subject_id
  out <- tbls
  out$subjects <- subj
  out$visits <- filter(tbls$visits, subject_id %in% keep)
  out$ecrf_forms <- filter(tbls$ecrf_forms, visit_id %in% out$visits$visit_id)
  out$cognitive_assessments <- filter(tbls$cognitive_assessments, visit_id %in% out$visits$visit_id)
  out$queries <- filter(tbls$queries, subject_id %in% keep)
  out$sites <- if (length(sites)) filter(tbls$sites, site_id %in% sites) else tbls$sites
  out$arm_filter <- arms
  out
}

# Enrollment target for the current filter: sum of site targets, scaled by the
# share of arms selected (1:1:1 randomization).
current_target <- function(tbls) {
  n_arms <- nrow(tbls$study_arms)
  share <- if (length(tbls$arm_filter)) length(tbls$arm_filter) / n_arms else 1
  sum(tbls$sites$target_enrollment) * share
}

enrollment_by_site <- function(tbls) {
  n_arms <- nrow(tbls$study_arms)
  share <- if (length(tbls$arm_filter)) length(tbls$arm_filter) / n_arms else 1
  counts <- tbls$subjects |>
    group_by(site_id) |>
    summarise(screened = n(),
              screen_failed = sum(subject_status == "Screen Failed"),
              in_screening = sum(subject_status == "Screening"),
              randomized = sum(!is.na(randomization_date)),
              discontinued = sum(subject_status == "Discontinued"),
              completed = sum(subject_status == "Completed"),
              .groups = "drop")
  tbls$sites |>
    select(site_id, site_name, country, target_enrollment) |>
    mutate(target = target_enrollment * share) |>
    select(-target_enrollment) |>
    left_join(counts, by = "site_id") |>
    mutate(across(c(screened:completed), ~ coalesce(.x, 0L)),
           pct_of_target = round(100 * randomized / target, 1),
           screen_fail_rate = round(100 * screen_failed / pmax(screened - in_screening, 1), 1)) |>
    arrange(site_id)
}

# Cumulative screened and randomized by date, with the planned (linear) curve.
enrollment_curve <- function(tbls) {
  study <- tbls$study[1, ]
  dates <- seq(study$study_start_date, study$data_cutoff_date, by = "week")
  dates <- unique(c(dates, study$data_cutoff_date))
  scr <- sort(tbls$subjects$screening_date)
  rnd <- sort(tbls$subjects$randomization_date[!is.na(tbls$subjects$randomization_date)])
  plan_days <- as.numeric(study$planned_enrollment_end_date - study$study_start_date)
  target <- current_target(tbls)
  tibble::tibble(
    date = dates,
    Screened = findInterval(as.numeric(dates), as.numeric(scr)),
    Randomized = findInterval(as.numeric(dates), as.numeric(rnd)),
    Planned = pmin(target, target * as.numeric(dates - study$study_start_date) / plan_days)
  )
}

# One row per scheduled visit from Baseline on, for every randomized subject,
# with its outcome. Visits whose window has not closed and have no record are
# not due yet and are left out.
visit_outcomes <- function(tbls) {
  cutoff <- tbls$study$data_cutoff_date[1]
  sched <- filter(tbls$visit_schedule, visit_code != "SCR")
  bl <- tbls$visits |>
    filter(visit_code == "BL", visit_status == "Completed") |>
    select(subject_id, baseline_date = visit_date)
  expected <- tbls$subjects |>
    filter(!is.na(randomization_date)) |>
    select(subject_id, site_id, arm_code, discontinuation_date) |>
    inner_join(bl, by = "subject_id") |>
    cross_join(sched) |>
    mutate(window_end_date = baseline_date + window_end_day - 1)
  expected |>
    left_join(select(tbls$visits, subject_id, visit_code, visit_id, visit_date, visit_status),
              by = c("subject_id", "visit_code")) |>
    mutate(sday = if_else(is.na(visit_date), NA_integer_,
                          as.integer(study_day(visit_date, baseline_date))),
           outcome = case_when(
             visit_status == "Missed" ~ "Missed",
             visit_status == "Completed" & sday >= window_start_day & sday <= window_end_day ~ "In window",
             visit_status == "Completed" ~ "Out of window",
             window_end_date < cutoff &
               (is.na(discontinuation_date) | discontinuation_date > window_end_date) ~
               "Overdue, not recorded",
             TRUE ~ NA_character_)) |>
    filter(!is.na(outcome)) |>
    mutate(outcome = factor(outcome, levels = VISIT_OUTCOMES))
}

visit_compliance_summary <- function(outcomes, by = "visit_code") {
  outcomes |>
    count(across(all_of(by)), outcome, .drop = FALSE) |>
    group_by(across(all_of(by))) |>
    mutate(due = sum(n), pct = if_else(due > 0, round(100 * n / due, 1), NA_real_)) |>
    ungroup()
}

# Expected eCRFs not entered within the grace period (same rule as EC_MF01),
# plus forms still inside the grace period ("pending").
ecrf_status <- function(tbls, grace_days = 14) {
  cutoff <- tbls$study$data_cutoff_date[1]
  expected <- tbls$visits |>
    filter(visit_status == "Completed") |>
    inner_join(tbls$form_schedule, by = "visit_code", relationship = "many-to-many") |>
    left_join(select(tbls$ecrf_forms, visit_id, form_code, form_status),
              by = c("visit_id", "form_code")) |>
    inner_join(select(tbls$subjects, subject_id, site_id), by = "subject_id") |>
    mutate(days_since_visit = as.integer(cutoff - visit_date),
           status = case_when(
             !is.na(form_status) ~ form_status,
             days_since_visit <= grace_days ~ "Pending (within grace period)",
             TRUE ~ "Missing"))
  expected
}

query_status_summary <- function(tbls) {
  cutoff <- tbls$study$data_cutoff_date[1]
  tbls$queries |>
    mutate(age_days = as.integer(cutoff - opened_date),
           age_bucket = factor(case_when(age_days <= 14 ~ AGE_BUCKETS[1],
                                         age_days <= 30 ~ AGE_BUCKETS[2],
                                         age_days <= 60 ~ AGE_BUCKETS[3],
                                         TRUE ~ AGE_BUCKETS[4]), levels = AGE_BUCKETS))
}

# Headline numbers for the value boxes and the report summary.
headline_metrics <- function(tbls, grace_days = 14) {
  enr <- enrollment_by_site(tbls)
  vo <- visit_outcomes(tbls)
  done <- filter(vo, outcome %in% c("In window", "Out of window"))
  ec <- ecrf_status(tbls, grace_days)
  q <- tbls$queries
  list(
    screened = sum(enr$screened),
    randomized = sum(enr$randomized),
    target = current_target(tbls),
    pct_of_target = round(100 * sum(enr$randomized) / current_target(tbls), 1),
    visits_due = nrow(vo),
    pct_in_window = if (nrow(done)) round(100 * mean(done$outcome == "In window"), 1) else NA,
    missed_visits = sum(vo$outcome == "Missed"),
    missing_ecrfs = sum(ec$status == "Missing"),
    open_queries = sum(q$query_status == "Open"),
    answered_queries = sum(q$query_status == "Answered")
  )
}
