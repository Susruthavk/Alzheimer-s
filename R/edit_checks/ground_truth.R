# Compare edit-check findings with the issues the simulator planted
# (sim.injected_issues). Used by the validation tests only: the checks
# themselves never look at the ground truth.

suppressPackageStartupMessages(library(dplyr))

# Which check is expected to catch each planted issue, and which fields must match.
EXPECTED_CHECK <- tibble::tribble(
  ~issue_type,          ~subtype,                       ~expected_check, ~match_form,
  "OUT_OF_WINDOW",      "EARLY",                        "EC_VW01",       FALSE,
  "OUT_OF_WINDOW",      "LATE",                         "EC_VW01",       FALSE,
  "MISSING_ECRF",       NA,                             "EC_MF01",       TRUE,
  "IMPLAUSIBLE_CHANGE", "MMSE",                         "EC_SC01",       TRUE,
  "IMPLAUSIBLE_CHANGE", "CDRSB",                        "EC_SC02",       TRUE,
  "IMPLAUSIBLE_CHANGE", "ADAS13",                       "EC_SC03",       TRUE,
  "INCONSISTENT_DATE",  "VISIT_BEFORE_CONSENT",         "EC_DT01",       FALSE,
  "INCONSISTENT_DATE",  "RANDOMIZATION_MISMATCH",       "EC_DT02",       FALSE,
  "INCONSISTENT_DATE",  "VISIT_AFTER_DISCONTINUATION",  "EC_DT03",       FALSE,
  "INCONSISTENT_DATE",  "ASSESSMENT_DATE_MISMATCH",     "EC_DT04",       TRUE,
  "INCONSISTENT_DATE",  "ENTRY_BEFORE_VISIT",           "EC_DT05",       TRUE
)

# Returns one row per planted issue with detected = TRUE/FALSE.
match_planted_issues <- function(findings, injected) {
  planted <- injected |>
    mutate(subtype = if_else(is.na(subtype) | subtype == "", NA_character_, subtype)) |>
    left_join(EXPECTED_CHECK, by = c("issue_type", "subtype"))
  hits <- findings |> distinct(check_id, subject_id, visit_code, form_code)
  planted |>
    rowwise() |>
    mutate(detected = any(
      hits$check_id == expected_check & hits$subject_id == subject_id &
        hits$visit_code == visit_code &
        (!match_form | (!is.na(hits$form_code) & hits$form_code == form_code)),
      na.rm = TRUE)) |>
    ungroup()
}
