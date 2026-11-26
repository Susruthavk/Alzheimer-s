# ALZ-301 Progress Report Specification

Version 0.1. Template: `reports/progress_report.Rmd`. Renderer: `reports/render_reports.R`.
Metrics come from `R/metrics.R` and findings from `R/edit_checks/checks.R`, the same code the dashboard uses,
so a report and the dashboard with the same filter show the same numbers.

## Parameters

| Parameter | Values | Default | Effect |
|---|---|---|---|
| `site` | a site ID (`101` … `301`) or `ALL` | `ALL` | restricts every section to that site; unknown IDs stop the render |
| `arm` | `PBO`, `LOW`, `HIGH` or `ALL` | `ALL` | restricts to randomized subjects in that arm (target scaled by 1/3) |
| `grace_days` | whole number of days | `14` | how long after a visit a form may stay unentered before it counts as missing |

## Output

`reports/output/ALZ-301_progress_<scope>_<cutoff>.html`, where scope is `all_sites` or `site_<id>`
(plus `_<arm>` when filtered). The output folder is git-ignored. Reports are rebuilt from code and data, not stored.

## Sections

| # | Section | Content | Source |
|---|---|---|---|
| 1 | Summary | screened; randomized vs target; % of completed visits in window; missed visits; missing eCRFs; open and answered queries; number of edit check findings | `headline_metrics()`, `run_all_checks()` |
| 2 | Screening and enrollment | cumulative screened and randomized vs plan; table by site | `enrollment_curve()`, `enrollment_by_site()` |
| 3 | Visit window compliance | outcome by visit (chart + table): in window, out of window, missed, overdue | `visit_outcomes()` |
| 4 | Missing eCRFs | listing of forms not entered after the grace period | `ecrf_status()` |
| 5 | Queries | open queries by site and age; counts by source and status | `query_status_summary()` |
| 6 | Edit check findings | count by check; full listing with query text | `run_all_checks()` |
| 7 | Traceability | parameters, data source, data cutoff, git commit, render time, R version | |

## Definitions

- **Target:** the sum of the selected sites' targets, times the share of arms selected.
- **Planned enrollment:** each site enrolls its target at a steady rate from its activation date to `study.planned_enrollment_end_date` (2026-09-30). **Assumption.**
- **Visit due:** a scheduled visit from Baseline onward that has a record, or whose window closed before the cutoff while the subject was still on study.
- **% in window:** completed visits whose study day is inside the protocol window, divided by all completed visits (missed visits are excluded and reported separately).
- **Query age:** data cutoff minus opened date. Buckets: 0-14, 15-30, 31-60, over 60 days.

## Validation

The functions behind every number are unit-tested in `tests/testthat/`. CI renders the study-wide report on every pull request.
