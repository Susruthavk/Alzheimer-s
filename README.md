# ALZ-301 Clinical Trial Monitoring (simulated)

A portfolio project that mimics the data-management side of a multicenter early
Alzheimer's disease trial: a PostgreSQL clinical database, edit checks that raise
data queries, an R Shiny monitoring dashboard, and reproducible R Markdown reports.

**All data is simulated.** ALZ-301, its sites, investigators and subjects are fictional.

![Dashboard overview](docs/img/dashboard_overview.png)

## Build plan

| Step | What | Folder | Status |
|---|---|---|---|
| 1 | PostgreSQL schema + Python (Pandas) simulator and loader | `sql/`, `python/`, `data/` | done |
| 2 | Edit checks in R → query listings by site | `R/edit_checks/`, `output/` | done |
| 3 | R Shiny dashboard: enrollment vs target, visit window compliance, missing eCRFs, open queries; filter by site and arm | `shiny/`, `R/metrics.R` | done |
| 4 | Parameterized R Markdown progress reports (one per site, or study-wide) | `reports/` | next |
| 5 | testthat validation + report specs and docs | `tests/testthat/`, `docs/` | |

## The simulated study

- 52-week, randomized 1:1:1 (Placebo, Low Dose, High Dose), 8 sites in 6 countries
- Target enrollment 240; by the data cutoff (2026-10-31) 313 screened and 196 randomized, so enrollment is behind target
- Visits: Screening (Day -28 to -1), Baseline (Day 1), Weeks 4, 12, 24, 36, 52 with protocol windows
- eCRF forms: Demographics, Eligibility, Vital Signs, AE review, MMSE, CDR-SB, ADAS-Cog 13
- Cognitive scores decline over time, slower on active drug, faster in APOE4 carriers

Full details and every assumption: [docs/data_specification.md](docs/data_specification.md).

### Planted data problems

The simulator deliberately plants problems for the edit checks to find, and records each one
in `sim.injected_issues` (ground truth used only by tests). Sites differ in data quality, so
site 203 (Madrid) and 202 (Lyon) are messier than 101 (Boston).

| Problem | Examples |
|---|---|
| Out-of-window visits | Week 12 on study day 59 (window 78 to 92) |
| Missing eCRFs | Visit done over 30 days ago, MMSE form never entered |
| Implausible score changes | MMSE 24 at Week 12, then 15 at Week 24 |
| Inconsistent dates | Screening before consent, randomization date not equal to baseline, visit after discontinuation, assessment dated before its visit, eCRF entered before the visit |

With the default seed (301) you get 35 out-of-window visits, 65 missing eCRFs, 15 implausible changes
and 42 inconsistent dates.

## Database tables (schema `trial`)

```
study ── study_arms        visit_schedule ── form_schedule ── forms
sites ── subjects ── visits ── ecrf_forms ── cognitive_assessments
              └──────────── queries (manual CRA queries now; edit-check queries in step 2)
```

A "missing eCRF" has no row: it is a `form_schedule` row for a completed visit with no matching `ecrf_forms` row.

## Run it locally

### 1. Install the tools (once)

- **PostgreSQL 14+**: https://www.postgresql.org/download/ . The installer asks for a password for the `postgres` user; remember it. It also installs **pgAdmin**, a point-and-click tool for browsing tables.
- **Python 3.10+**: https://www.python.org/downloads/
- **R and RStudio** (needed from step 2): https://posit.co/download/rstudio-desktop/

### 2. Create the database

In pgAdmin: right-click *Databases* → *Create* → *Database*, name it `alz_trial`.
Or in a terminal: `createdb -U postgres alz_trial`

### 3. Set your connection

Copy `config/.env.example` to `.env` in the project root and put in your password:

```
DATABASE_URL=postgresql://postgres:YOUR_PASSWORD@localhost:5432/alz_trial
```

### 4. Simulate and load

From the project folder, in a terminal (RStudio has one: *Tools → Terminal → New Terminal*):

```bash
python -m venv .venv
source .venv/bin/activate          # Windows: .venv\Scripts\activate
pip install -r requirements.txt

python python/simulate_data.py     # writes CSVs to data/simulated/ (already included)
python python/load_data.py --reset # creates the schema and loads everything
```

`--reset` drops and recreates the `trial` and `sim` schemas, so run it whenever you regenerate data.
The same `--seed` always gives the same data.

### 5. Run the edit checks (RStudio)

Open `alz-trial-monitoring.Rproj` in RStudio so the working folder is the project root, then:

```r
install.packages(c("DBI", "RPostgres", "dplyr", "tidyr", "tibble"))
source("R/edit_checks/run_edit_checks.R")      # writes listings to output/query_listings/
```

To also raise the findings as open queries in the database, run in the Terminal:
`Rscript R/edit_checks/run_edit_checks.R --raise-queries`.
The checks are described in [docs/edit_check_specification.md](docs/edit_check_specification.md).
With the default data they find all 157 planted problems (175 findings in total).

### 6. Open the dashboard

```r
install.packages(c("shiny", "bslib", "ggplot2", "DT"))
shiny::runApp("shiny")
```

Tabs: **Overview** (screened and randomized against the enrollment plan and site targets),
**Visit windows** (in window, out of window, missed, by visit and site), **Missing eCRFs**,
**Queries** (open queries by site and age) and **Edit check findings** (checks run live).
The sidebar filters every tab by site and study arm; tables export to CSV or Excel.

If PostgreSQL is not running, the app reads `data/simulated/*.csv` instead and says so in the sidebar,
so it also works on a free hosting service such as shinyapps.io with no database.
Edit-check queries only appear on the Queries tab after you run the checks with `--raise-queries`.

### 7. Look at the data from RStudio

```r
install.packages(c("DBI", "RPostgres", "dplyr", "dbplyr"))
library(DBI); library(dplyr)

con <- dbConnect(RPostgres::Postgres(), dbname = "alz_trial", host = "localhost",
                 user = "postgres", password = Sys.getenv("PGPASSWORD"))

tbl(con, I("trial.subjects")) |> count(site_id, subject_status) |> collect()
dbDisconnect(con)
```

(Set the password with `Sys.setenv(PGPASSWORD = "...")` in your session, or add `PGPASSWORD=...` to a `~/.Renviron` file, so it never sits in your code.)

## Project layout

```
sql/01_schema.sql          PostgreSQL DDL (trial + sim schemas)
python/simulate_data.py    simulated trial data with planted issues -> data/simulated/*.csv
python/load_data.py        loads CSVs into PostgreSQL with pandas
data/simulated/            generated CSVs (committed so the project works without Python)
R/db.R                     database connection helpers (reads DATABASE_URL / .env; CSV fallback)
R/metrics.R                enrollment, visit window, eCRF and query metrics (dashboard + reports)
R/edit_checks/checks.R     the edit check functions
R/edit_checks/run_edit_checks.R   runs them, writes listings, raises queries
R/edit_checks/ground_truth.R      compares findings with planted issues (validation)
output/query_listings/     site-by-site query listings (sample output committed)
shiny/app.R                the monitoring dashboard
reports/                   step 4
tests/testthat/            step 5
docs/                      specifications
```
