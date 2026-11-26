# =============================================================================
# Run all ALZ-301 edit checks and produce query listings.
#
# From the project root (open alz-trial-monitoring.Rproj in RStudio first):
#   source("R/edit_checks/run_edit_checks.R")                       # listings only
# Or from a terminal:
#   Rscript R/edit_checks/run_edit_checks.R                          # listings only
#   Rscript R/edit_checks/run_edit_checks.R --raise-queries          # also insert queries
#
# Output (overwritten each run):
#   output/query_listings/query_listing_all_sites.csv
#   output/query_listings/query_listing_site_<id>.csv   one per site, for the CRA
#   output/query_listings/check_summary.csv             counts by site and check
#
# --raise-queries inserts each NEW finding into trial.queries as an Open
# "Edit check" query dated at the data cutoff. Findings that already have a
# query (any status) are not raised twice, so the run is safe to repeat.
# =============================================================================

source("R/db.R")
source("R/edit_checks/checks.R")

raise_queries <- function(con, listing, opened_date) {
  new <- listing |>
    filter(query_status == "New") |>
    transmute(site_id, subject_id, visit_id, form_code, check_id,
              query_source = "Edit check", query_text, query_status = "Open",
              opened_date = as.Date(opened_date))
  if (nrow(new)) {
    # RPostgres takes a DBI::Id for schema-qualified tables; RPostgreSQL takes c(schema, table)
    target <- if (inherits(con, "PqConnection")) DBI::Id(schema = "trial", table = "queries") else
      c("trial", "queries")
    DBI::dbWriteTable(con, target, as.data.frame(new), append = TRUE, row.names = FALSE)
  }
  nrow(new)
}

main <- function(args = commandArgs(trailingOnly = TRUE), out_dir = "output/query_listings") {
  con <- db_connect()
  on.exit(DBI::dbDisconnect(con))
  tbls <- load_trial_tables(con)
  cutoff <- tbls$study$data_cutoff_date[1]

  listing <- run_all_checks(tbls, cutoff) |>
    attach_query_status(tbls$queries) |>
    left_join(select(tbls$sites, site_id, site_name), by = "site_id") |>
    relocate(site_id, site_name, subject_id, visit_code, form_code, category, check_id,
             check_name, query_status, query_text)

  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  unlink(file.path(out_dir, "query_listing_site_*.csv"))
  utils::write.csv(listing, file.path(out_dir, "query_listing_all_sites.csv"),
                   row.names = FALSE, na = "")
  for (s in sort(unique(listing$site_id))) {
    utils::write.csv(filter(listing, site_id == s),
                     file.path(out_dir, sprintf("query_listing_site_%s.csv", s)),
                     row.names = FALSE, na = "")
  }
  summary <- listing |> count(site_id, check_id, name = "findings") |>
    tidyr::pivot_wider(names_from = check_id, values_from = findings, values_fill = 0) |>
    mutate(total = rowSums(across(-site_id)))
  utils::write.csv(summary, file.path(out_dir, "check_summary.csv"), row.names = FALSE)

  cat(sprintf("Data cutoff %s: %d findings across %d sites.\n",
              fmt_date(cutoff), nrow(listing), length(unique(listing$site_id))))
  print(as.data.frame(summary), row.names = FALSE)
  cat("Listings written to", out_dir, "\n")

  if ("--raise-queries" %in% args) {
    n <- raise_queries(con, listing, cutoff)
    cat(sprintf("Raised %d new edit-check queries in trial.queries.\n", n))
  }
  invisible(listing)
}

if (sys.nframe() == 0 || identical(environment(), globalenv())) main()
