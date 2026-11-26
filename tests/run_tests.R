# Run all validation tests from the project root:
#   Rscript tests/run_tests.R
# or in RStudio: testthat::test_dir("tests/testthat")
# Tests use the committed CSVs, so no database is needed. A JUnit XML copy of
# the results is written to tests/results.xml for CI.
library(testthat)
reporter <- MultiReporter$new(list(SummaryReporter$new(),
                                   JunitReporter$new(file = file.path(normalizePath("tests"), "results.xml"))))
res <- as.data.frame(test_dir("tests/testthat", reporter = reporter, stop_on_failure = FALSE))
cat(sprintf("\n%d tests, %d expectations, %d failed, %d errors\n",
            nrow(res), sum(res$nb), sum(res$failed), sum(res$error)))
if (sum(res$failed) > 0 || any(res$error)) quit(status = 1)
