# Render the ALZ-301 progress report: one study-wide report plus one per site.
#
# From the project root (open alz-trial-monitoring.Rproj in RStudio):
#   source("reports/render_reports.R")
# Or from a terminal:
#   Rscript reports/render_reports.R            # all sites + each site
#   Rscript reports/render_reports.R 203        # only site 203
#
# Output: reports/output/ALZ-301_progress_<scope>_<cutoff>.html

source("R/db.R")

render_progress_report <- function(site = "ALL", arm = "ALL", out_dir = "reports/output", cutoff = NULL) {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  scope <- if (site == "ALL") "all_sites" else paste0("site_", site)
  if (arm != "ALL") scope <- paste0(scope, "_", arm)
  file <- sprintf("ALZ-301_progress_%s_%s.html", scope, format(cutoff %||% Sys.Date()))
  rmarkdown::render("reports/progress_report.Rmd",
                    params = list(site = site, arm = arm),
                    output_file = file, output_dir = out_dir,
                    intermediates_dir = tempdir(), envir = new.env(), quiet = TRUE)
  file.path(out_dir, file)
}

`%||%` <- function(a, b) if (is.null(a)) b else a

main <- function(args = commandArgs(trailingOnly = TRUE)) {
  tbls <- load_trial_data()$tables
  cutoff <- tbls$study$data_cutoff_date[1]
  sites <- if (length(args)) args else c("ALL", sort(tbls$sites$site_id))
  for (s in sites) cat("Rendered", render_progress_report(s, cutoff = cutoff), "\n")
}

if (sys.nframe() == 0 || identical(environment(), globalenv())) main()
