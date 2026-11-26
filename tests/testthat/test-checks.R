# Unit tests for each edit check on a tiny hand-made study (see helper-setup.R).

test_that("study day follows the CDISC convention (no Day 0)", {
  bl <- d("2025-01-01")
  expect_equal(study_day(d("2025-01-01"), bl), 1)
  expect_equal(study_day(d("2025-01-02"), bl), 2)
  expect_equal(study_day(d("2024-12-31"), bl), -1)
  expect_equal(study_day(d("2024-12-04"), bl), -28)
})

test_that("clean data raises no findings", {
  expect_equal(nrow(run_all_checks(mini_tables())), 0)
})

test_that("findings always have the standard columns", {
  expect_named(run_all_checks(mini_tables()), c(FINDING_COLS, "category"))
})

test_that("EC_VW01 fires outside the window and not on its edges", {
  t <- mini_tables()
  t$visits$visit_date[3] <- d("2025-01-26")            # W4 study day 26 = window start
  t$ecrf_forms$entered_date[3] <- d("2025-01-26")
  expect_equal(nrow(check_visit_windows(t$visits, t$subjects, t$visit_schedule)), 0)
  t$visits$visit_date[3] <- d("2025-01-25")            # study day 25 = 1 day early
  f <- check_visit_windows(t$visits, t$subjects, t$visit_schedule)
  expect_equal(f$check_id, "EC_VW01")
  expect_equal(f$visit_code, "W4")
  expect_match(f$query_text, "study day 25")
  expect_match(f$query_text, "1 days before")
})

test_that("EC_VW02 fires when screening is more than 28 days before baseline", {
  t <- mini_tables()
  t$visits$visit_date[1] <- d("2024-12-03")            # Day -29
  t$subjects$consent_date[1] <- d("2024-12-03")
  f <- check_visit_windows(t$visits, t$subjects, t$visit_schedule)
  expect_equal(f$check_id, "EC_VW02")
})

test_that("EC_MF01 respects the grace period", {
  t <- mini_tables()
  t$ecrf_forms <- t$ecrf_forms[t$ecrf_forms$ecrf_id != 4, ]       # W12 MMSE missing, visit 2025-03-26
  cutoff_close <- d("2025-04-08")                                  # 13 days after the visit
  expect_equal(nrow(check_missing_ecrfs(t$visits, t$subjects, t$form_schedule, t$ecrf_forms,
                                        cutoff_close, grace_days = 14)), 0)
  f <- check_missing_ecrfs(t$visits, t$subjects, t$form_schedule, t$ecrf_forms,
                           d("2025-04-09"), grace_days = 14)
  expect_equal(nrow(f), 1)
  expect_equal(f$form_code, "MMSE")
  expect_equal(f$visit_code, "W12")
})

test_that("EC_MF01 ignores missed visits", {
  t <- mini_tables()
  t$visits$visit_status[4] <- "Missed"
  t$visits$visit_date[4] <- NA
  t$ecrf_forms <- t$ecrf_forms[t$ecrf_forms$visit_id != 4, ]
  expect_equal(nrow(check_missing_ecrfs(t$visits, t$subjects, t$form_schedule, t$ecrf_forms,
                                        d("2025-06-30"))), 0)
})

test_that("score change checks use the threshold as inclusive", {
  t <- mini_tables()
  t$cognitive_assessments$total_score[2] <- 20        # 24 -> 20: change of 4, below 5
  expect_equal(nrow(check_score_changes(t$cognitive_assessments, t$visits, t$subjects, t$visit_schedule)), 0)
  t$cognitive_assessments$total_score[2] <- 19        # change of 5 = threshold
  f <- check_score_changes(t$cognitive_assessments, t$visits, t$subjects, t$visit_schedule)
  expect_equal(f$check_id, "EC_SC01")
  expect_equal(f$form_code, "MMSE")
  expect_match(f$query_text, "from 24 at BL to 19 at W12")
  t$cognitive_assessments$total_score[2] <- 29        # improvement also counts
  expect_equal(nrow(check_score_changes(t$cognitive_assessments, t$visits, t$subjects, t$visit_schedule)), 1)
})

test_that("score changes are ordered by visit, not by (possibly wrong) date", {
  t <- mini_tables()
  t$cognitive_assessments$assessment_date[2] <- d("2024-01-01")
  t$cognitive_assessments$total_score[2] <- 15
  f <- check_score_changes(t$cognitive_assessments, t$visits, t$subjects, t$visit_schedule)
  expect_equal(f$visit_code, "W12")
})

test_that("CDR-SB and ADAS-Cog 13 thresholds are 3 and 12", {
  a <- tibble::tibble(assessment_id = 1:4, visit_id = c(2L, 4L, 2L, 4L),
                      instrument = c("CDRSB", "CDRSB", "ADAS13", "ADAS13"),
                      total_score = c(3, 5.5, 30, 41))
  t <- mini_tables()
  expect_equal(nrow(check_score_changes(a, t$visits, t$subjects, t$visit_schedule)), 0)
  a$total_score <- c(3, 6, 30, 42)
  f <- check_score_changes(a, t$visits, t$subjects, t$visit_schedule)
  expect_setequal(f$check_id, c("EC_SC02", "EC_SC03"))
})

test_that("EC_DT01 flags a visit before consent", {
  t <- mini_tables()
  t$subjects$consent_date[1] <- d("2024-12-15")
  f <- check_visit_before_consent(t$visits, t$subjects)
  expect_equal(f$check_id, "EC_DT01")
  expect_equal(f$visit_code, "SCR")
})

test_that("EC_DT02 flags randomization not on the baseline date", {
  t <- mini_tables()
  t$subjects$randomization_date[2] <- d("2025-01-05")
  f <- check_randomization_date(t$visits, t$subjects)
  expect_equal(f$subject_id, "101-0002")
})

test_that("EC_DT03 flags a visit after discontinuation", {
  t <- mini_tables()
  t$subjects$discontinuation_date[2] <- d("2025-03-01")
  f <- check_visit_after_discontinuation(t$visits, t$subjects)
  expect_equal(f$visit_code, "W12")
  expect_equal(f$subject_id, "101-0002")
})

test_that("EC_DT04 flags an assessment dated differently from its visit", {
  t <- mini_tables()
  t$cognitive_assessments$assessment_date[3] <- d("2024-12-20")
  f <- check_assessment_dates(t$cognitive_assessments, t$visits, t$subjects)
  expect_equal(f$check_id, "EC_DT04")
  expect_equal(f$visit_code, "BL")
})

test_that("EC_DT05 flags an eCRF entered before the visit", {
  t <- mini_tables()
  t$ecrf_forms$entered_date[7] <- d("2025-01-20")
  f <- check_entry_before_visit(t$ecrf_forms, t$visits, t$subjects)
  expect_equal(f$form_code, "VS")
  expect_equal(f$visit_code, "W4")
})

test_that("existing edit-check queries are matched so they are not raised twice", {
  t <- mini_tables()
  t$subjects$randomization_date[2] <- d("2025-01-05")
  f <- run_all_checks(t)
  expect_equal(attach_query_status(f, t$queries)$query_status, "New")
  t$queries <- tibble::tibble(query_id = 1, site_id = "101", subject_id = "101-0002", visit_id = 6L,
                              form_code = NA_character_, check_id = "EC_DT02",
                              query_source = "Edit check", query_text = "x", query_status = "Answered",
                              opened_date = d("2025-06-30"))
  expect_equal(attach_query_status(f, t$queries)$query_status, "Answered")
})
