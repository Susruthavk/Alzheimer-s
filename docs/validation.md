# ALZ-301 Validation and Traceability

How each output can be traced to a specification and shown to be correct.

## Traceability matrix

| Requirement | Specification | Code | Tests (`tests/testthat/`) | Evidence in CI |
|---|---|---|---|---|
| Simulated data is reproducible | data_specification.md | `python/simulate_data.py` (seed 301) | | regenerated CSVs must equal the committed ones (`git diff --exit-code`) |
| Data is internally valid (keys, score ranges, MMSE inclusion, balanced randomization) | data_specification.md, `sql/01_schema.sql` CHECK constraints | `python/load_data.py` | `test-data.R` | load into PostgreSQL 16 succeeds with every constraint enforced |
| Each edit check fires exactly on its rule, including boundaries | edit_check_specification.md | `R/edit_checks/checks.R` | `test-checks.R` | |
| Edit checks find every planted issue | edit_check_specification.md, "Validation" | `R/edit_checks/ground_truth.R` | `test-validation.R` | separate CI step against PostgreSQL |
| Queries are not raised twice | edit_check_specification.md, "Outputs" | `attach_query_status()`, `run_edit_checks.R --raise-queries` | `test-checks.R` (last test) | |
| Dashboard and report metrics are correct | report_specification.md, "Definitions" | `R/metrics.R` | `test-metrics.R` | dashboard smoke test; reports rendered and uploaded |
| Every report states how it was produced | report_specification.md, section 7 | `reports/progress_report.Rmd` | | rendered reports include parameters, data cutoff and git commit |

## Test approach

- **Unit tests** use a tiny hand-made study (`mini_tables()` in `helper-setup.R`): two subjects with clean data, which each test breaks in exactly one way, so a failure points to one rule.
- **Validation tests** run the checks on the full simulated study and compare them with `data/simulated/injected_issues.csv`, the simulator's record of what it planted. Recall must be 100%. Window, missing-form and date checks must not raise anything that was not planted, apart from a small allowance for forms entered late (see the edit check spec).
- **Regression tests** pin the headline numbers for seed 301 (313 screened, 196 randomized, 67 missing eCRFs, 175 findings). If a change moves them, the test fails and the change has to be explained.
- Tests read the committed CSVs, so they run without a database: `Rscript tests/run_tests.R`.

## Change control

Every change goes through a pull request. CI must pass: data regeneration, PostgreSQL load, edit checks, the planted-issue check, the dashboard smoke test, report rendering and testthat. The query listings, rendered reports and JUnit test results are kept as artifacts of each CI run.
