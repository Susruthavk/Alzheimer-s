# Integrity of the simulated data itself.

test_that("all tables load and keys are unique", {
  t <- sim_tables()
  expect_false(any(duplicated(t$subjects$subject_id)))
  expect_false(any(duplicated(t$visits$visit_id)))
  expect_false(any(duplicated(t$visits[c("subject_id", "visit_code")])))
  expect_false(any(duplicated(t$ecrf_forms[c("visit_id", "form_code")])))
  expect_true(all(t$subjects$site_id %in% t$sites$site_id))
  expect_true(all(t$visits$subject_id %in% t$subjects$subject_id))
  expect_true(all(t$ecrf_forms$visit_id %in% t$visits$visit_id))
})

test_that("scores are within instrument ranges and steps", {
  a <- sim_tables()$cognitive_assessments
  mmse <- a$total_score[a$instrument == "MMSE"]
  cdr <- a$total_score[a$instrument == "CDRSB"]
  adas <- a$total_score[a$instrument == "ADAS13"]
  expect_true(all(mmse >= 0 & mmse <= 30 & mmse == round(mmse)))
  expect_true(all(cdr >= 0 & cdr <= 18 & (cdr * 2) == round(cdr * 2)))
  expect_true(all(adas >= 0 & adas <= 85))
})

test_that("enrolled subjects met the screening MMSE inclusion range", {
  t <- sim_tables()
  scr <- t$cognitive_assessments |>
    filter(instrument == "MMSE") |>
    inner_join(t$visits, by = "visit_id") |>
    filter(visit_code == "SCR") |>
    inner_join(t$subjects, by = "subject_id") |>
    filter(!is.na(arm_code))
  expect_true(all(scr$total_score >= 20 & scr$total_score <= 26))
})

test_that("randomization is balanced within each site (blocks of 6)", {
  per_site <- sim_tables()$subjects |> filter(!is.na(arm_code)) |> count(site_id, arm_code) |>
    group_by(site_id) |> summarise(spread = max(n) - min(n))
  expect_true(all(per_site$spread <= 2))
})

test_that("screen failures have a reason and no arm", {
  s <- sim_tables()$subjects |> filter(subject_status == "Screen Failed")
  expect_true(all(!is.na(s$screen_fail_reason)))
  expect_true(all(is.na(s$arm_code)))
})

test_that("placebo declines faster than high dose on average (treatment effect is simulated)", {
  t <- sim_tables()
  chg <- t$cognitive_assessments |>
    filter(instrument == "ADAS13") |>
    inner_join(t$visits, by = "visit_id") |>
    inner_join(t$subjects, by = "subject_id") |>
    filter(visit_code %in% c("BL", "W52")) |>
    select(subject_id, arm_code, visit_code, total_score) |>
    tidyr::pivot_wider(names_from = visit_code, values_from = total_score) |>
    filter(!is.na(BL), !is.na(W52)) |>
    group_by(arm_code) |> summarise(mean_change = mean(W52 - BL))
  expect_gt(chg$mean_change[chg$arm_code == "PBO"], chg$mean_change[chg$arm_code == "HIGH"])
})
