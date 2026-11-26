# Alzheimer's Disease Clinical Trial Monitoring Dashboard

A portfolio project that simulates the data-management side of a multicenter early
Alzheimer's disease trial (fictional study ALZ-301):

- **PostgreSQL** clinical database of sites, subjects, visits, eCRF forms and cognitive assessments (MMSE, CDR-SB, ADAS-Cog 13), loaded with **Python (Pandas)**
- **R edit checks** for out-of-window visits, implausible score changes, inconsistent dates and missing eCRFs, producing site-by-site query listings
- **R Shiny dashboard** for screening and enrollment against target, visit window compliance, missing eCRFs and open queries, filterable by site and study arm
- **Parameterized R Markdown** progress reports
- **testthat** validation and GitHub Actions CI so every output can be traced and reproduced

All data is simulated. The work is added step by step through pull requests.
