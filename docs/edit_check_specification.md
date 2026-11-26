# ALZ-301 Edit Check Specification

Version 0.1. Implemented in `R/edit_checks/checks.R`; run with `R/edit_checks/run_edit_checks.R`.
Every check runs on the data as of the study data cutoff (`trial.study.data_cutoff_date`).

Study day: baseline = Day 1, the day before baseline = Day -1 (no Day 0).
A finding is identified by check ID + subject + visit + form, which is how repeat runs avoid raising the same query twice.

| Check ID | Name | Applies to | Fires when | Query text (summary) |
|---|---|---|---|---|
| EC_VW01 | Visit out of window | Completed W4 to W52 visits | study day < window start or > window end (see visit schedule) | visit date, study day, days outside window |
| EC_VW02 | Screening outside Day -28 to -1 | Completed SCR visits of randomized subjects | screening study day outside -28 to -1 | as above |
| EC_MF01 | Missing eCRF | Completed visits at least 14 days before cutoff | a form in `form_schedule` for that visit has no `ecrf_forms` row | form, visit, days since visit |
| EC_SC01 | MMSE implausible change | MMSE totals | absolute change from previous MMSE (by visit order) ≥ 5 points | both scores and visits |
| EC_SC02 | CDR-SB implausible change | CDR-SB totals | absolute change ≥ 3 points | as above |
| EC_SC03 | ADAS-Cog 13 implausible change | ADAS-Cog 13 totals | absolute change ≥ 12 points | as above |
| EC_DT01 | Visit before informed consent | Completed visits | visit date < consent date | visit and consent dates |
| EC_DT02 | Randomization date not equal to baseline | Randomized subjects with a completed BL visit | randomization date ≠ BL visit date | both dates |
| EC_DT03 | Visit after discontinuation | Completed visits of discontinued subjects | visit date > discontinuation date | both dates |
| EC_DT04 | Assessment date not equal to visit date | MMSE, CDR-SB, ADAS-Cog 13 | assessment date ≠ visit date | both dates |
| EC_DT05 | eCRF entered before visit | Entered forms | entry date < visit date | both dates |

## Design notes and assumptions

- **Consecutive** assessments are ordered by protocol visit order, not by date, so a wrong date cannot hide a score change.
- A single wrong score usually triggers two score-change findings (into and out of the bad value). That is expected: the data manager resolves both with one correction.
- The score thresholds are about 3 times the visit-to-visit noise in the simulation and well above a year of typical decline. **Assumption**: in a real study they would come from the Data Management Plan.
- The 14-day grace period for EC_MF01 reflects a typical site agreement to enter data within 2 weeks of the visit. **Assumption.**
- Missed visits (status Missed) are not queried by these checks; they will appear on the dashboard as missed.

## Outputs

| File | Contents |
|---|---|
| `output/query_listings/query_listing_all_sites.csv` | every finding, sorted by site, subject, visit |
| `output/query_listings/query_listing_site_<id>.csv` | one file per site for the CRA / site staff |
| `output/query_listings/check_summary.csv` | counts by site and check |

`query_status` in the listing is `New` if no edit-check query exists yet for that finding, otherwise the status of the existing query.
With `--raise-queries`, new findings are inserted into `trial.queries` as `Open`, `query_source = 'Edit check'`, opened on the cutoff date.

## Validation (default seed 301)

All 157 planted issues are detected (checked with `R/edit_checks/ground_truth.R`; automated in step 5).
The checks also return 18 findings that were not planted: 16 score changes (mostly the "out of" pair after a planted jump, plus a few genuinely large natural changes) and 2 forms entered late but not planted as missing.
