# Database helpers shared by the edit checks, Shiny app and reports.
#
# Connection settings come from DATABASE_URL (environment variable or the .env
# file in the project root), the same setting the Python loader uses:
#   DATABASE_URL=postgresql://postgres:yourpassword@localhost:5432/alz_trial

library(DBI)

read_database_url <- function(env_file = ".env") {
  url <- Sys.getenv("DATABASE_URL")
  if (!nzchar(url) && file.exists(env_file)) {
    line <- grep("^\\s*DATABASE_URL=", readLines(env_file, warn = FALSE), value = TRUE)
    if (length(line)) url <- gsub("^['\"]|['\"]$", "", trimws(sub("^\\s*DATABASE_URL=", "", line[1])))
  }
  if (!nzchar(url)) url <- "postgresql://postgres:postgres@localhost:5432/alz_trial"
  url
}

parse_database_url <- function(url) {
  m <- regmatches(url, regexec(
    "^postgres(?:ql)?(?:\\+\\w+)?://([^:@/]+)(?::([^@/]*))?@([^:/]+)(?::(\\d+))?/([^?]+)", url, perl = TRUE))[[1]]
  if (!length(m)) stop("DATABASE_URL is not in the form postgresql://user:password@host:port/dbname")
  list(user = m[2], password = utils::URLdecode(m[3]), host = m[4],
       port = if (nzchar(m[5])) as.integer(m[5]) else 5432L, dbname = m[6])
}

db_connect <- function(url = read_database_url()) {
  p <- parse_database_url(url)
  # RPostgres is the recommended driver; RPostgreSQL works as a fallback.
  drv <- if (requireNamespace("RPostgres", quietly = TRUE)) RPostgres::Postgres() else
    RPostgreSQL::PostgreSQL()
  DBI::dbConnect(drv, dbname = p$dbname, host = p$host, port = p$port,
                 user = p$user, password = p$password)
}

TRIAL_TABLES <- c("study", "study_arms", "sites", "visit_schedule", "forms", "form_schedule",
                  "subjects", "visits", "ecrf_forms", "cognitive_assessments", "queries")

# Read every trial table into a named list of data frames.
load_trial_tables <- function(con) {
  out <- lapply(TRIAL_TABLES, function(t) {
    df <- DBI::dbGetQuery(con, paste0("select * from trial.", t))
    # numeric(4,1) arrives as numeric, bigint as integer64; normalise ids
    if ("query_id" %in% names(df)) df$query_id <- as.numeric(df$query_id)
    tibble::as_tibble(df)
  })
  stats::setNames(out, TRIAL_TABLES)
}

# Same tables from the CSVs in data/simulated (no database needed). Used by the
# dashboard when PostgreSQL is not reachable, and by the tests.
DATE_COLUMNS <- c("study_start_date", "planned_enrollment_end_date", "data_cutoff_date",
                  "activation_date", "consent_date", "screening_date", "randomization_date",
                  "discontinuation_date", "visit_date", "entered_date", "sdv_date",
                  "assessment_date", "opened_date", "answered_date", "closed_date")

load_trial_tables_csv <- function(dir = "data/simulated") {
  out <- lapply(TRIAL_TABLES, function(t) {
    df <- utils::read.csv(file.path(dir, paste0(t, ".csv")), stringsAsFactors = FALSE,
                          na.strings = "")
    if ("site_id" %in% names(df)) df$site_id <- as.character(df$site_id)
    for (col in intersect(names(df), DATE_COLUMNS)) df[[col]] <- as.Date(df[[col]])
    if ("apoe4_carrier" %in% names(df)) df$apoe4_carrier <- as.logical(df$apoe4_carrier)
    if ("query_id" %in% names(df)) df$query_id <- as.numeric(df$query_id)
    if (t == "queries" && !"query_id" %in% names(df)) df$query_id <- seq_len(nrow(df))
    tibble::as_tibble(df)
  })
  stats::setNames(out, TRIAL_TABLES)
}

# Try the database first, then fall back to CSVs. Returns list(tables, source).
load_trial_data <- function(csv_dir = "data/simulated") {
  con <- tryCatch(db_connect(), error = function(e) NULL)
  if (!is.null(con)) {
    on.exit(DBI::dbDisconnect(con))
    return(list(tables = load_trial_tables(con), source = "PostgreSQL"))
  }
  list(tables = load_trial_tables_csv(csv_dir), source = "CSV files (database not reachable)")
}
