# Loaded automatically by testthat before the tests.
suppressPackageStartupMessages(library(dplyr))
ROOT <- rprojroot::find_root("alz-trial-monitoring.Rproj")
source(file.path(ROOT, "R/db.R"))
source(file.path(ROOT, "R/edit_checks/checks.R"))
source(file.path(ROOT, "R/edit_checks/ground_truth.R"))
source(file.path(ROOT, "R/metrics.R"))

# Full simulated study from the committed CSVs (cached for all tests).
sim_tables <- local({
  cache <- NULL
  function() {
    if (is.null(cache)) cache <<- load_trial_tables_csv(file.path(ROOT, "data/simulated"))
    cache
  }
})
injected_issues <- function() {
  read.csv(file.path(ROOT, "data/simulated/injected_issues.csv"), stringsAsFactors = FALSE,
           na.strings = "", colClasses = c(site_id = "character"))
}

# A tiny hand-made study: one site, two subjects, baseline 2025-01-01.
d <- function(x) as.Date(x)
mini_tables <- function() {
  list(
    study = tibble::tibble(study_id = "T", target_enrollment = 10L, study_start_date = d("2024-12-01"),
                           planned_enrollment_end_date = d("2025-12-01"), data_cutoff_date = d("2025-06-30")),
    study_arms = tibble::tibble(arm_code = c("PBO", "LOW", "HIGH"), arm_name = c("P", "L", "H"), arm_order = 1:3),
    sites = tibble::tibble(site_id = "101", site_name = "S", country = "X", city = "C",
                           activation_date = d("2024-12-01"), target_enrollment = 10L),
    visit_schedule = tibble::tribble(
      ~visit_code, ~visit_order, ~target_day, ~window_start_day, ~window_end_day,
      "SCR", 1L, -14L, -28L, -1L,
      "BL",  2L,   1L,   1L,  1L,
      "W4",  3L,  29L,  26L, 32L,
      "W12", 4L,  85L,  78L, 92L),
    form_schedule = tibble::tribble(~visit_code, ~form_code,
                                    "SCR", "DM", "BL", "MMSE", "W4", "VS", "W12", "MMSE"),
    subjects = tibble::tibble(
      subject_id = c("101-0001", "101-0002"), site_id = "101",
      consent_date = d(c("2024-12-10", "2024-12-12")), screening_date = d(c("2024-12-10", "2024-12-12")),
      subject_status = c("Ongoing", "Discontinued"), randomization_date = d(c("2025-01-01", "2025-01-01")),
      arm_code = c("PBO", "HIGH"), discontinuation_date = d(c(NA, "2025-05-01"))),
    visits = tibble::tibble(
      visit_id = 1:8,
      subject_id = rep(c("101-0001", "101-0002"), each = 4),
      visit_code = rep(c("SCR", "BL", "W4", "W12"), 2),
      visit_date = d(c("2024-12-10", "2025-01-01", "2025-01-29", "2025-03-26",
                       "2024-12-12", "2025-01-01", "2025-01-30", "2025-03-27")),
      visit_status = "Completed"),
    ecrf_forms = tibble::tibble(
      ecrf_id = 1:8, visit_id = 1:8, form_code = rep(c("DM", "MMSE", "VS", "MMSE"), 2),
      form_status = "Entered", entered_date = d(c("2024-12-11", "2025-01-02", "2025-01-30", "2025-03-27",
                                                   "2024-12-13", "2025-01-02", "2025-01-31", "2025-03-28"))),
    cognitive_assessments = tibble::tibble(
      assessment_id = 1:4, ecrf_id = c(2L, 4L, 6L, 8L), visit_id = c(2L, 4L, 6L, 8L), instrument = "MMSE",
      assessment_date = d(c("2025-01-01", "2025-03-26", "2025-01-01", "2025-03-27")),
      total_score = c(24, 23, 22, 21)),
    queries = tibble::tibble(query_id = numeric(), site_id = character(), subject_id = character(),
                             visit_id = integer(), form_code = character(), check_id = character(),
                             query_source = character(), query_text = character(),
                             query_status = character(), opened_date = as.Date(character()))
  )
}
