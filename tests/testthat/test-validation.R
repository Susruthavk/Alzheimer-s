# Validation of the edit checks against the full simulated study and the
# issues the simulator planted on purpose (data/simulated/injected_issues.csv).

test_that("every planted issue is detected by its expected check", {
  m <- match_planted_issues(run_all_checks(sim_tables()), injected_issues())
  expect_gt(nrow(m), 100)
  expect_false(anyNA(m$expected_check))
  missed <- m[!m$detected, c("issue_type", "subtype", "subject_id", "visit_code", "form_code")]
  expect_equal(nrow(missed), 0, info = paste(capture.output(print(missed)), collapse = "\n"))
})

test_that("visit window and missing eCRF checks raise nothing that was not planted", {
  f <- run_all_checks(sim_tables())
  inj <- injected_issues()
  oow <- f |> filter(check_id == "EC_VW01")
  expect_setequal(paste(oow$subject_id, oow$visit_code),
                  with(inj[inj$issue_type == "OUT_OF_WINDOW", ], paste(subject_id, visit_code)))
  # Missing eCRFs: all planted ones, plus at most a few forms entered late but within 30 days.
  mf <- f |> filter(check_id == "EC_MF01")
  expect_lte(nrow(mf) - sum(inj$issue_type == "MISSING_ECRF"), 5)
})

test_that("date consistency checks raise nothing that was not planted", {
  f <- run_all_checks(sim_tables()) |> filter(category == "Date consistency")
  m <- match_planted_issues(f, injected_issues())
  expect_equal(nrow(f), sum(m$issue_type == "INCONSISTENT_DATE"))
})

test_that("check results for the default seed are stable (regression)", {
  counts <- run_all_checks(sim_tables()) |> count(check_id)
  expect_equal(sum(counts$n), 175)
  expect_equal(counts$n[counts$check_id == "EC_VW01"], 35)
})
