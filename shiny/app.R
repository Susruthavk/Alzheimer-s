# =============================================================================
# ALZ-301 Clinical Trial Monitoring Dashboard (R Shiny)
#
# Run from RStudio: open alz-trial-monitoring.Rproj, then
#   shiny::runApp("shiny")
# Data comes from PostgreSQL (DATABASE_URL / .env). If the database cannot be
# reached, the app falls back to the CSVs in data/simulated, so it also runs
# with no database at all (for example on shinyapps.io).
# =============================================================================

suppressPackageStartupMessages({
  library(shiny)
  library(bslib)
  library(dplyr)
  library(ggplot2)
  library(DT)
})

# Work from the project root whether the app was started from the root or shiny/.
ROOT <- if (file.exists("R/db.R")) "." else ".."
source(file.path(ROOT, "R/db.R"))
source(file.path(ROOT, "R/edit_checks/checks.R"))
source(file.path(ROOT, "R/metrics.R"))

old_wd <- setwd(ROOT)
DATA <- load_trial_data()
setwd(old_wd)
TBLS <- DATA$tables
CUTOFF <- TBLS$study$data_cutoff_date[1]

# ---- Colors (validated categorical slots + reserved status colors) ----------
ARM_COLORS <- c(PBO = "#257de0", LOW = "#f47230", HIGH = "#00b894")
ARM_LABELS <- setNames(TBLS$study_arms$arm_name, TBLS$study_arms$arm_code)
OUTCOME_COLORS <- c("In window" = "#0aac23", "Out of window" = "#f18a59",
                    "Missed" = "#dc3c3d", "Overdue, not recorded" = "#fbb315")
AGE_COLORS <- setNames(c("#84b9f3", "#338ced", "#1b64be", "#0e3d7e"), AGE_BUCKETS)
SERIES_COLORS <- c(Randomized = "#257de0", Screened = "#f47230", Planned = "#8a8a8a")
INK <- "#191919"; INK_2 <- "#666666"; GRID <- "#e6e6e6"

theme_monitor <- function() {
  theme_minimal(base_size = 15) +
    theme(panel.grid.major.x = element_blank(), panel.grid.minor = element_blank(),
          panel.grid.major.y = element_line(color = GRID, linewidth = 0.4),
          axis.text = element_text(color = INK_2), axis.title = element_text(color = INK_2),
          legend.position = "top", legend.justification = "left",
          legend.title = element_blank(), legend.text = element_text(color = INK),
          plot.title.position = "plot")
}

site_choices <- setNames(TBLS$sites$site_id,
                         paste(TBLS$sites$site_id, TBLS$sites$city, sep = " - "))
arm_choices <- setNames(TBLS$study_arms$arm_code, TBLS$study_arms$arm_name)

dt <- function(df, ...) {
  datatable(df, rownames = FALSE, filter = "top", extensions = "Buttons",
            options = list(pageLength = 15, scrollX = TRUE, dom = "Bfrtip",
                           buttons = c("csv", "excel")), ...)
}

# =============================================================================
# UI
# =============================================================================
ui <- page_navbar(
  title = paste(TBLS$study$study_id[1], "Trial Monitoring"),
  theme = bs_theme(version = 5, primary = "#257de0", base_font = font_collection("system-ui", "sans-serif")),
  fillable = FALSE,
  sidebar = sidebar(
    width = 280,
    selectizeInput("sites", "Site", choices = site_choices, multiple = TRUE,
                   options = list(placeholder = "All sites")),
    selectizeInput("arms", "Study arm", choices = arm_choices, multiple = TRUE,
                   options = list(placeholder = "All arms")),
    helpText("Choosing an arm shows randomized subjects only, since screen failures have no arm."),
    hr(),
    tags$small(
      tags$b("Data cutoff: "), format(CUTOFF, "%d %b %Y"), tags$br(),
      tags$b("Source: "), DATA$source, tags$br(),
      "Simulated data. ALZ-301 is fictional."
    )
  ),

  nav_panel(
    "Overview",
    layout_column_wrap(
      width = 1 / 5, fill = FALSE,
      value_box("Randomized vs target", textOutput("vb_rand"), uiOutput("vb_rand_sub")),
      value_box("Screened", textOutput("vb_scr"), uiOutput("vb_scr_sub")),
      value_box("Visits in window", textOutput("vb_win"), uiOutput("vb_win_sub")),
      value_box("Missing eCRFs", textOutput("vb_mis"), "not entered 14+ days after the visit"),
      value_box("Open queries", textOutput("vb_q"), uiOutput("vb_q_sub"))
    ),
    layout_columns(
      col_widths = c(7, 5),
      card(card_header("Screening and enrollment against plan"),
           plotOutput("plot_enroll_curve", height = 340)),
      card(card_header("Randomized by site (tick = target)"),
           plotOutput("plot_enroll_site", height = 340))
    ),
    card(card_header("Enrollment by site"), DTOutput("tbl_enroll"))
  ),

  nav_panel(
    "Visit windows",
    layout_columns(
      col_widths = c(6, 6),
      card(card_header("Visit outcome by visit"), plotOutput("plot_visit_by_visit", height = 340)),
      card(card_header("Visit outcome by site"), plotOutput("plot_visit_by_site", height = 340))
    ),
    card(card_header("Visits out of window, missed, or overdue"), DTOutput("tbl_visits"))
  ),

  nav_panel(
    "Missing eCRFs",
    layout_columns(
      col_widths = c(6, 6),
      card(card_header("Missing eCRFs by site and form"), plotOutput("plot_missing", height = 340)),
      card(card_header("eCRF entry status (all expected forms)"), DTOutput("tbl_ecrf_status"))
    ),
    card(card_header("Missing eCRF listing"), DTOutput("tbl_missing"))
  ),

  nav_panel(
    "Queries",
    layout_columns(
      col_widths = c(7, 5),
      card(card_header("Open queries by site and age"), plotOutput("plot_queries", height = 340)),
      card(card_header("Queries by status and source"), DTOutput("tbl_query_counts"))
    ),
    card(card_header("Open and answered queries"), DTOutput("tbl_queries"))
  ),

  nav_panel(
    "Edit check findings",
    card(
      card_header("Live edit check results at data cutoff (see docs/edit_check_specification.md)"),
      DTOutput("tbl_findings")
    )
  )
)

# =============================================================================
# Server
# =============================================================================
server <- function(input, output, session) {
  tb <- reactive(filter_trial(TBLS, input$sites, input$arms))
  hm <- reactive(headline_metrics(tb()))
  outcomes <- reactive(visit_outcomes(tb()))
  ecrf <- reactive(ecrf_status(tb()))
  qs <- reactive(query_status_summary(tb()))

  # ---- value boxes ----------------------------------------------------------
  output$vb_rand <- renderText(sprintf("%d / %s", hm()$randomized, format(round(hm()$target))))
  output$vb_rand_sub <- renderUI(sprintf("%.1f%% of target", hm()$pct_of_target))
  output$vb_scr <- renderText(hm()$screened)
  output$vb_scr_sub <- renderUI({
    e <- enrollment_by_site(tb())
    sprintf("%d screen failures", sum(e$screen_failed))
  })
  output$vb_win <- renderText(if (is.na(hm()$pct_in_window)) "-" else sprintf("%.1f%%", hm()$pct_in_window))
  output$vb_win_sub <- renderUI(sprintf("of completed visits; %d missed", hm()$missed_visits))
  output$vb_mis <- renderText(hm()$missing_ecrfs)
  output$vb_q <- renderText(hm()$open_queries)
  output$vb_q_sub <- renderUI(sprintf("%d answered, awaiting review", hm()$answered_queries))

  # ---- overview -------------------------------------------------------------
  output$plot_enroll_curve <- renderPlot({
    cur <- enrollment_curve(tb()) |>
      tidyr::pivot_longer(-date, names_to = "series", values_to = "n") |>
      mutate(series = factor(series, levels = names(SERIES_COLORS)))
    last <- cur |> group_by(series) |> slice_max(date, n = 1, with_ties = FALSE)
    ggplot(cur, aes(date, n, color = series, linetype = series)) +
      geom_line(linewidth = 1) +
      geom_text(data = last, aes(label = paste(series, round(n))), hjust = 1.05, vjust = -0.6,
                color = INK, size = 4.2, show.legend = FALSE) +
      scale_color_manual(values = SERIES_COLORS) +
      scale_linetype_manual(values = c(Randomized = "solid", Screened = "solid", Planned = "22")) +
      scale_x_date(date_labels = "%b %Y") +
      labs(x = NULL, y = "Subjects (cumulative)") +
      theme_monitor()
  })

  output$plot_enroll_site <- renderPlot({
    e <- enrollment_by_site(tb()) |> mutate(site = factor(paste(site_id, country), levels = rev(paste(site_id, country))))
    ggplot(e, aes(y = site)) +
      geom_col(aes(x = randomized), fill = "#257de0", width = 0.6) +
      geom_errorbar(aes(xmin = target, xmax = target), width = 0.8, color = INK, linewidth = 0.8) +
      geom_text(aes(x = pmax(randomized, target), label = sprintf("%d (%.0f%%)", randomized, pct_of_target)),
                hjust = -0.2, size = 4.2, color = INK) +
      scale_x_continuous(expand = expansion(mult = c(0, 0.25))) +
      labs(x = "Randomized subjects", y = NULL) +
      theme_monitor() + theme(panel.grid.major.y = element_blank(),
                              panel.grid.major.x = element_line(color = GRID, linewidth = 0.4))
  })

  output$tbl_enroll <- renderDT({
    enrollment_by_site(tb()) |>
      transmute(Site = site_id, Name = site_name, Country = country, Target = round(target, 1),
                Screened = screened, `Screen failed` = screen_failed, `In screening` = in_screening,
                Randomized = randomized, `% of target` = pct_of_target,
                `Screen fail %` = screen_fail_rate, Discontinued = discontinued,
                Completed = completed) |>
      dt()
  })

  # ---- visit windows --------------------------------------------------------
  visit_bar <- function(df, x) {
    ggplot(df, aes(x = .data[[x]], y = n, fill = outcome)) +
      geom_col(width = 0.65, color = "white", linewidth = 0.5) +
      scale_fill_manual(values = OUTCOME_COLORS, drop = FALSE) +
      labs(x = NULL, y = "Visits due") +
      theme_monitor()
  }
  output$plot_visit_by_visit <- renderPlot({
    s <- visit_compliance_summary(outcomes(), "visit_code") |>
      left_join(select(TBLS$visit_schedule, visit_code, visit_order), by = "visit_code") |>
      mutate(visit_code = reorder(visit_code, visit_order))
    visit_bar(s, "visit_code")
  })
  output$plot_visit_by_site <- renderPlot({
    visit_bar(visit_compliance_summary(outcomes(), "site_id"), "site_id")
  })
  output$tbl_visits <- renderDT({
    outcomes() |>
      filter(outcome != "In window") |>
      transmute(Site = site_id, Subject = subject_id, Arm = ARM_LABELS[arm_code],
                Visit = visit_code, `Visit date` = visit_date, `Study day` = sday,
                Window = sprintf("%d to %d", window_start_day, window_end_day),
                Outcome = as.character(outcome)) |>
      arrange(Site, Subject) |>
      dt()
  })

  # ---- missing eCRFs --------------------------------------------------------
  output$plot_missing <- renderPlot({
    m <- ecrf() |> filter(status == "Missing") |> count(site_id, form_code)
    validate(need(nrow(m) > 0, "No missing eCRFs for this selection."))
    ggplot(m, aes(x = form_code, y = site_id, fill = n)) +
      geom_tile(color = "white", linewidth = 1.5) +
      geom_text(aes(label = n), color = ifelse(m$n > max(m$n) / 2, "white", INK), size = 4) +
      scale_fill_gradient(low = "#cce3fd", high = "#1757ac", name = "Missing") +
      labs(x = "Form", y = "Site") +
      theme_monitor() + theme(panel.grid = element_blank(), legend.position = "right")
  })
  output$tbl_ecrf_status <- renderDT({
    ecrf() |> count(Status = status, name = "Forms") |>
      mutate(`%` = round(100 * Forms / sum(Forms), 1)) |>
      datatable(rownames = FALSE, options = list(dom = "t"))
  })
  output$tbl_missing <- renderDT({
    ecrf() |> filter(status == "Missing") |>
      transmute(Site = site_id, Subject = subject_id, Visit = visit_code, Form = form_code,
                `Visit date` = visit_date, `Days since visit` = days_since_visit) |>
      arrange(desc(`Days since visit`)) |>
      dt()
  })

  # ---- queries --------------------------------------------------------------
  output$plot_queries <- renderPlot({
    q <- qs() |> filter(query_status == "Open") |> count(site_id, age_bucket, .drop = FALSE)
    validate(need(sum(q$n) > 0, "No open queries for this selection."))
    ggplot(q, aes(x = site_id, y = n, fill = age_bucket)) +
      geom_col(width = 0.65, color = "white", linewidth = 0.5) +
      scale_fill_manual(values = AGE_COLORS, drop = FALSE) +
      labs(x = "Site", y = "Open queries", caption = "Age = days from query opened to data cutoff") +
      theme_monitor()
  })
  output$tbl_query_counts <- renderDT({
    qs() |> count(Source = query_source, Status = query_status, name = "Queries") |>
      datatable(rownames = FALSE, options = list(dom = "t"))
  })
  output$tbl_queries <- renderDT({
    v <- select(TBLS$visits, visit_id, visit_code)
    qs() |>
      filter(query_status != "Closed") |>
      left_join(v, by = "visit_id") |>
      transmute(Site = site_id, Subject = subject_id, Visit = visit_code, Form = form_code,
                Source = query_source, Check = check_id, Status = query_status,
                Opened = opened_date, `Age (days)` = age_days, Query = query_text) |>
      arrange(desc(`Age (days)`)) |>
      dt()
  })

  # ---- edit check findings --------------------------------------------------
  output$tbl_findings <- renderDT({
    run_all_checks(tb(), CUTOFF) |>
      transmute(Site = site_id, Subject = subject_id, Visit = visit_code, Form = form_code,
                Category = category, Check = check_id, Finding = check_name, `Query text` = query_text) |>
      dt()
  })
}

shinyApp(ui, server)
