# Dashboard and report metrics.

test_that("enrollment counts add up", {
  e <- enrollment_by_site(sim_tables())
  s <- sim_tables()$subjects
  expect_equal(sum(e$screened), nrow(s))
  expect_equal(sum(e$randomized), sum(!is.na(s$arm_code)))
  expect_equal(sum(e$target), 240)
  expect_equal(e$pct_of_target, round(100 * e$randomized / e$target, 1))
})

test_that("headline metrics for the full study match known values", {
  h <- headline_metrics(sim_tables())
  expect_equal(h$screened, 313)
  expect_equal(h$randomized, 196)
  expect_equal(h$missing_ecrfs, 67)
})

test_that("site and arm filters subset every table consistently", {
  f <- filter_trial(sim_tables(), sites = "203", arms = "HIGH")
  expect_true(all(f$subjects$site_id == "203"))
  expect_true(all(f$subjects$arm_code == "HIGH"))
  expect_true(all(f$visits$subject_id %in% f$subjects$subject_id))
  expect_true(all(f$queries$subject_id %in% f$subjects$subject_id))
  expect_equal(current_target(f), 25 / 3)
})

test_that("visit outcomes classify the mini study correctly", {
  t <- mini_tables()
  t$visits$visit_date[3] <- d("2025-02-15")                     # subject 1 W4 late
  t$visits$visit_status[8] <- "Missed"; t$visits$visit_date[8] <- NA
  vo <- visit_outcomes(t)
  get <- function(s, v) as.character(vo$outcome[vo$subject_id == s & vo$visit_code == v])
  expect_equal(get("101-0001", "BL"), "In window")
  expect_equal(get("101-0001", "W4"), "Out of window")
  expect_equal(get("101-0002", "W12"), "Missed")
})

test_that("visits whose window closed with no record count as overdue", {
  t <- mini_tables()
  t$visits <- t$visits[t$visits$visit_id != 4, ]                  # subject 1 W12 never recorded
  vo <- visit_outcomes(t)
  expect_equal(as.character(vo$outcome[vo$subject_id == "101-0001" & vo$visit_code == "W12"]),
               "Overdue, not recorded")
})

test_that("planned enrollment reaches the target at the planned end date", {
  e <- enrollment_curve(sim_tables())
  expect_equal(max(e$Planned), 240)
  expect_equal(e$Planned[1], 0)
  expect_true(all(diff(e$Randomized) >= 0))
})

test_that("query age buckets are assigned from the data cutoff", {
  t <- mini_tables()
  t$queries <- tibble::tibble(query_id = 1:4, site_id = "101", subject_id = "101-0001",
                              visit_id = 2L, form_code = "MMSE", check_id = NA, query_source = "Manual",
                              query_text = "x", query_status = "Open",
                              opened_date = t$study$data_cutoff_date - c(0, 15, 31, 61))
  expect_equal(as.character(query_status_summary(t)$age_bucket), AGE_BUCKETS)
})
