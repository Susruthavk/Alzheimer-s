#!/usr/bin/env python3
"""
Simulate the ALZ-301 multicenter early Alzheimer's disease trial.

ALZ-301 is fictional. It is a 52-week, randomized, double-blind,
placebo-controlled study of an investigational drug at two dose levels,
running at 8 sites. The numbers are loosely shaped like published early-AD
trials, but none of it is real data.

The script writes one CSV per database table into data/simulated/, plus
injected_issues.csv: the ground-truth list of data problems that were planted
on purpose, so that the R edit checks can later be tested against it.

Planted problems:
  OUT_OF_WINDOW       visit date moved outside its protocol window
  MISSING_ECRF        an expected eCRF form never entered (visit >30 days old)
  IMPLAUSIBLE_CHANGE  a cognitive score jumps far more than disease allows
  INCONSISTENT_DATE   visit before consent, randomization date != baseline,
                      visit after discontinuation, assessment date != visit
                      date, data entered before the visit happened

Usage:
    python python/simulate_data.py                 # default seed 301
    python python/simulate_data.py --seed 7 --out data/simulated
"""

from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np
import pandas as pd

# =============================================================================
# Study design (assumptions are marked ASSUMPTION so they are easy to find)
# =============================================================================

STUDY = {
    "study_id": "ALZ-301",
    "study_title": ("A 52-Week Randomized, Double-Blind, Placebo-Controlled "
                    "Study of ALZ-301 in Early Alzheimer's Disease (simulated)"),
    "phase": "2",
    "target_enrollment": 240,
    "study_start_date": pd.Timestamp("2025-02-03"),
    # ASSUMPTION: the plan is to randomize 240 at a steady rate by this date
    "planned_enrollment_end_date": pd.Timestamp("2026-09-30"),
    "data_cutoff_date": pd.Timestamp("2026-10-31"),  # ASSUMPTION: "today" for the data
}
CUTOFF = STUDY["data_cutoff_date"]

ARMS = [
    {"arm_code": "PBO", "arm_name": "Placebo", "arm_order": 1},
    {"arm_code": "LOW", "arm_name": "ALZ-301 Low Dose", "arm_order": 2},
    {"arm_code": "HIGH", "arm_name": "ALZ-301 High Dose", "arm_order": 3},
]
# ASSUMPTION: how much each arm slows decline (0.30 = 30% slower than placebo).
ARM_SLOWING = {"PBO": 0.0, "LOW": 0.15, "HIGH": 0.30}

# Per-site behaviour knobs (not loaded into the database):
#   screen_rate : subjects screened per week
#   entry_lag   : mean days from visit to eCRF entry
#   quality     : multiplier on the planted-issue rates (2.0 = twice as messy)
SITES = [
    # id,    name,                              country,    city,        PI,               start day, target, rate, lag, quality
    ("101", "Northbridge Memory Clinic",        "USA",       "Boston",     "Dr. Anita Rao",       0, 40, 0.80, 3, 0.6),
    ("102", "Lakeshore Neurology Research",     "USA",       "Chicago",    "Dr. Marcus Hale",    14, 35, 0.65, 4, 1.0),
    ("103", "Pacific Cognitive Health Center",  "USA",       "San Diego",  "Dr. Elena Ortiz",    30, 35, 0.55, 6, 1.4),
    ("104", "Maple Leaf Brain Institute",       "Canada",    "Toronto",    "Dr. Owen Fraser",    45, 30, 0.50, 5, 0.8),
    ("201", "Rhine Valley Memory Unit",         "Germany",   "Cologne",    "Dr. Katrin Vogel",   60, 30, 0.45, 4, 0.7),
    ("202", "Clinique des Neurosciences",       "France",    "Lyon",       "Dr. Julien Morel",   75, 25, 0.40, 8, 1.8),
    ("203", "Iberia Neuro Trials",              "Spain",     "Madrid",     "Dr. Lucia Navarro",  90, 25, 0.35, 7, 2.5),
    ("301", "Southern Cross Dementia Research", "Australia", "Melbourne",  "Dr. Priya Shah",    120, 20, 0.30, 5, 1.0),
]

# Visit schedule. Study day: baseline = Day 1, no Day 0.
VISITS = [
    # code,  name,                order, target, window start, window end
    ("SCR", "Screening",            1,  -14, -28,  -1),
    ("BL",  "Baseline (Day 1)",     2,    1,   1,   1),
    ("W4",  "Week 4",               3,   29,  26,  32),
    ("W12", "Week 12",              4,   85,  78,  92),
    ("W24", "Week 24",              5,  169, 162, 176),
    ("W36", "Week 36",              6,  253, 239, 267),
    ("W52", "Week 52 (End of Study)", 7, 365, 351, 379),
]
POST_BL = ["W4", "W12", "W24", "W36", "W52"]

FORMS = [
    ("DM",    "Demographics",                      "Administrative"),
    ("ELIG",  "Inclusion/Exclusion Criteria",      "Administrative"),
    ("VS",    "Vital Signs",                       "Safety"),
    ("AE",    "Adverse Event Review",              "Safety"),
    ("MMSE",  "Mini-Mental State Examination",     "Efficacy"),
    ("CDRSB", "Clinical Dementia Rating - Sum of Boxes", "Efficacy"),
    ("ADAS",  "ADAS-Cog 13",                       "Efficacy"),
]
FORM_TO_INSTRUMENT = {"MMSE": "MMSE", "CDRSB": "CDRSB", "ADAS": "ADAS13"}

# Schedule of assessments: which forms are expected at each visit.
FORM_SCHEDULE = {
    "SCR": ["DM", "ELIG", "VS", "MMSE", "CDRSB"],
    "BL":  ["VS", "MMSE", "CDRSB", "ADAS"],
    "W4":  ["VS", "AE"],
    "W12": ["VS", "AE", "MMSE", "ADAS"],
    "W24": ["VS", "AE", "MMSE", "CDRSB", "ADAS"],
    "W36": ["VS", "AE", "MMSE", "ADAS"],
    "W52": ["VS", "AE", "MMSE", "CDRSB", "ADAS"],
}

SCREEN_FAIL_RATE = 0.38   # ASSUMPTION: amyloid PET makes early-AD screen failure high
SCREEN_FAIL_REASONS = (
    ["MMSE outside 20-26", "Amyloid PET negative", "Other inclusion/exclusion criterion",
     "Consent withdrawn"],
    [0.25, 0.45, 0.20, 0.10],
)
DISCONTINUE_PER_VISIT = 0.03
DISCONTINUE_REASONS = (["Adverse event", "Withdrawal by subject", "Lost to follow-up",
                        "Physician decision"], [0.35, 0.35, 0.15, 0.15])
MISSED_VISIT_RATE = 0.02

# Base rates for planted issues (multiplied by the site's quality factor).
ISSUE_RATES = {
    "OUT_OF_WINDOW": 0.035,          # per completed post-baseline visit
    "MISSING_ECRF": 0.015,           # per entered form on a visit >30 days old
    "IMPLAUSIBLE_CHANGE": 0.012,     # per assessment that has a prior one
    "VISIT_BEFORE_CONSENT": 0.015,   # per subject
    "RANDOMIZATION_MISMATCH": 0.015, # per randomized subject
    "VISIT_AFTER_DISCONTINUATION": 0.25,  # per discontinued subject
    "ASSESSMENT_DATE_MISMATCH": 0.008,    # per post-screening assessment
    "ENTRY_BEFORE_VISIT": 0.002,     # per entered form
}

# Planted implausible changes are much bigger than these (see step 2 edit checks):
#   MMSE |change| >= 5, CDR-SB |change| >= 3, ADAS-Cog13 |change| >= 12
IMPLAUSIBLE_JUMP = {"MMSE": (7, 10), "CDRSB": (4.0, 6.0), "ADAS13": (15, 22)}
SCORE_RANGE = {"MMSE": (0, 30), "CDRSB": (0, 18), "ADAS13": (0, 85)}
HIGHER_IS_WORSE = {"MMSE": False, "CDRSB": True, "ADAS13": True}

MANUAL_QUERY_RATE = 0.04
MANUAL_QUERY_TEXT = {
    "DM": "Year of birth on DM does not match source. Please verify.",
    "ELIG": "Inclusion criterion 4 marked 'Yes' but no supporting source note. Please confirm.",
    "VS": "Systolic BP recorded as 210 mmHg. Please confirm or correct.",
    "AE": "AE start date is missing. Please provide.",
    "MMSE": "MMSE item scores do not sum to recorded total. Please review.",
    "CDRSB": "CDR box score missing for 'Community affairs'. Please complete.",
    "ADAS": "ADAS-Cog word recall trial 3 left blank. Please complete or mark not done.",
}


def days(n) -> pd.Timedelta:
    return pd.Timedelta(days=int(n))


def study_day(date: pd.Timestamp, baseline: pd.Timestamp) -> int:
    diff = (date - baseline).days
    return diff + 1 if diff >= 0 else diff


# =============================================================================
# Clean data generation
# =============================================================================

class Simulator:
    def __init__(self, seed: int):
        self.rng = np.random.default_rng(seed)
        self.subjects, self.visits, self.ecrfs, self.assessments, self.queries = [], [], [], [], []
        self.visit_id = self.ecrf_id = self.assessment_id = 0
        self.site_info = {s[0]: s for s in SITES}
        self.schedule = {v[0]: v for v in VISITS}

    # -- helpers ------------------------------------------------------------
    def choice(self, options_probs):
        options, probs = options_probs
        return options[self.rng.choice(len(options), p=probs)]

    def randomization_list(self, n_blocks=40):
        """Permuted blocks of 6 (2 per arm), one list per site."""
        out = []
        for _ in range(n_blocks):
            block = ["PBO", "LOW", "HIGH"] * 2
            self.rng.shuffle(block)
            out.extend(block)
        return out

    def score(self, instrument, subj, years, screening=False):
        base, slope = subj["true"][instrument]
        if instrument == "MMSE":
            val = round(base + slope * years + self.rng.normal(0, 1.2))
            if screening and subj["enrolled"]:
                val = min(max(val, 20), 26)          # enrolled subjects met MMSE 20-26
        elif instrument == "CDRSB":
            val = round((base + slope * years + self.rng.normal(0, 0.5)) * 2) / 2
        else:
            val = round(base + slope * years + self.rng.normal(0, 2.0))
        lo, hi = SCORE_RANGE[instrument]
        return float(min(max(val, lo), hi))

    # -- subject ------------------------------------------------------------
    def run(self):
        start = STUDY["study_start_date"]
        for site in SITES:
            site_id, *_, act_offset, _target, rate, _lag, _q = site
            rand_list = self.randomization_list()
            t = start + days(act_offset)
            seq = 0
            while True:
                t = t + days(max(1, round(self.rng.exponential(7 / rate))))
                if t.dayofweek >= 5:                   # no weekend clinic visits
                    t = t + days(7 - t.dayofweek)
                if t > CUTOFF:
                    break
                seq += 1
                self.make_subject(site_id, f"{site_id}-{seq:04d}", t, rand_list)
        return self

    def make_subject(self, site_id, subject_id, scr_date, rand_list):
        rng = self.rng
        screen_fail = rng.random() < SCREEN_FAIL_RATE
        sf_reason = self.choice(SCREEN_FAIL_REASONS) if screen_fail else None

        mmse0 = rng.normal(23.5, 2.0)
        if sf_reason == "MMSE outside 20-26":
            mmse0 = rng.choice([rng.uniform(15, 19), rng.uniform(27.5, 29.5)])
        apoe4 = bool(rng.random() < 0.6)
        speed = 1.2 if apoe4 else 1.0            # ASSUMPTION: APOE4 carriers decline faster
        subj = {
            "enrolled": not screen_fail,
            "true": {
                # (baseline level, slope per year on placebo)
                "MMSE": (mmse0, -2.4 * speed * rng.lognormal(0, 0.4)),
                "CDRSB": (min(max(3.0 + 0.35 * (24 - mmse0) + rng.normal(0, 1.0), 0.5), 9.0),
                          1.5 * speed * rng.lognormal(0, 0.4)),
                "ADAS13": (min(max(27 + 1.6 * (24 - mmse0) + rng.normal(0, 5), 10), 60),
                           5.5 * speed * rng.lognormal(0, 0.4)),
            },
        }
        row = {
            "subject_id": subject_id,
            "site_id": site_id,
            "consent_date": scr_date - days(rng.integers(0, 4)),
            "screening_date": scr_date,
            "sex": "F" if rng.random() < 0.55 else "M",
            "age_at_consent": int(np.clip(round(rng.normal(71, 7)), 55, 85)),
            "education_years": int(np.clip(round(rng.normal(14, 3)), 6, 22)),
            "apoe4_carrier": apoe4,
            "subject_status": "Screen Failed" if screen_fail else "Screening",
            "screen_fail_reason": sf_reason,
            "randomization_date": pd.NaT,
            "arm_code": None,
            "discontinuation_date": pd.NaT,
            "discontinuation_reason": None,
        }
        self.subjects.append(row)

        baseline = scr_date + days(rng.integers(7, 29))      # screening is Day -28..-1
        self.add_visit(row, subj, "SCR", scr_date, baseline)
        if screen_fail or baseline > CUTOFF:
            return                                            # still in screening, or failed

        arm = rand_list.pop(0)
        row.update(randomization_date=baseline, arm_code=arm, subject_status="Ongoing")
        slowing = 1 - ARM_SLOWING[arm]
        subj["true"] = {k: (b, s * slowing) for k, (b, s) in subj["true"].items()}
        self.add_visit(row, subj, "BL", baseline, baseline)

        prev_date = baseline
        for code in POST_BL:
            _, _, _, target, w_start, w_end = self.schedule[code]
            target_date = baseline + days(target - 1)
            if rng.random() < DISCONTINUE_PER_VISIT:
                disc = prev_date + days(rng.integers(5, max(6, (target_date - prev_date).days)))
                if disc <= CUTOFF:
                    row.update(subject_status="Discontinued", discontinuation_date=disc,
                               discontinuation_reason=self.choice(DISCONTINUE_REASONS))
                    return
            half = (w_end - w_start) / 2
            jitter = int(np.clip(round(rng.normal(0, max(half, 1) / 2.5)), w_start - target, w_end - target))
            visit_date = target_date + days(jitter)
            window_closed = baseline + days(w_end - 1) < CUTOFF
            if window_closed and rng.random() < MISSED_VISIT_RATE:
                self.add_missed_visit(row, code)
                continue
            if visit_date > CUTOFF:
                return                                        # not happened yet
            self.add_visit(row, subj, code, visit_date, baseline)
            prev_date = visit_date
        row["subject_status"] = "Completed"

    def add_missed_visit(self, row, code):
        self.visit_id += 1
        self.visits.append({"visit_id": self.visit_id, "subject_id": row["subject_id"],
                            "visit_code": code, "visit_date": pd.NaT, "visit_status": "Missed"})

    def add_visit(self, row, subj, code, visit_date, baseline):
        rng = self.rng
        site = self.site_info[row["site_id"]]
        lag_mean = site[8]
        self.visit_id += 1
        vid = self.visit_id
        self.visits.append({"visit_id": vid, "subject_id": row["subject_id"], "visit_code": code,
                            "visit_date": visit_date, "visit_status": "Completed"})
        years = max(study_day(visit_date, baseline), 0) / 365.25
        rater = f"R{row['site_id']}{rng.integers(1, 4)}"
        for form in FORM_SCHEDULE[code]:
            entered = visit_date + days(rng.geometric(1 / lag_mean) - 1)
            if entered > CUTOFF:
                continue                                      # not entered yet (entry lag)
            sdv_date = entered + days(rng.integers(20, 90))
            sdv = sdv_date <= CUTOFF and rng.random() < 0.85
            self.ecrf_id += 1
            self.ecrfs.append({"ecrf_id": self.ecrf_id, "visit_id": vid, "form_code": form,
                               "form_status": "SDV Complete" if sdv else "Entered",
                               "entered_date": entered, "sdv_date": sdv_date if sdv else pd.NaT})
            if form in FORM_TO_INSTRUMENT:
                inst = FORM_TO_INSTRUMENT[form]
                self.assessment_id += 1
                self.assessments.append({
                    "assessment_id": self.assessment_id, "ecrf_id": self.ecrf_id, "visit_id": vid,
                    "instrument": inst, "assessment_date": visit_date,
                    "total_score": self.score(inst, subj, years, screening=(code == "SCR")),
                    "rater_id": rater})
            if rng.random() < MANUAL_QUERY_RATE:
                self.add_manual_query(row, vid, form, entered)

    def add_manual_query(self, row, vid, form, entered):
        rng = self.rng
        opened = entered + days(rng.integers(1, 60))
        if opened > CUTOFF:
            return
        answered = opened + days(rng.integers(1, 21)) if rng.random() < 0.8 else pd.NaT
        if pd.notna(answered) and answered > CUTOFF:
            answered = pd.NaT
        closed = pd.NaT
        if pd.notna(answered) and rng.random() < 0.85:
            closed = answered + days(rng.integers(1, 14))
            if closed > CUTOFF:
                closed = pd.NaT
        status = "Closed" if pd.notna(closed) else "Answered" if pd.notna(answered) else "Open"
        self.queries.append({"site_id": row["site_id"], "subject_id": row["subject_id"],
                             "visit_id": vid, "form_code": form, "check_id": None,
                             "query_source": "Manual", "query_text": MANUAL_QUERY_TEXT[form],
                             "query_status": status, "opened_date": opened,
                             "answered_date": answered, "closed_date": closed})


# =============================================================================
# Planting data issues
# =============================================================================

class Injector:
    def __init__(self, sim: Simulator, seed: int):
        self.rng = np.random.default_rng(seed + 1)
        self.subjects = pd.DataFrame(sim.subjects)
        self.visits = pd.DataFrame(sim.visits)
        self.ecrfs = pd.DataFrame(sim.ecrfs)
        self.assess = pd.DataFrame(sim.assessments)
        self.queries = pd.DataFrame(sim.queries)
        self.quality = {s[0]: s[9] for s in SITES}
        self.schedule = {v[0]: v for v in VISITS}
        self.issues = []
        self.touched_visits = set()        # keep planted issues from overlapping

    def hit(self, kind, site_id):
        return self.rng.random() < min(1.0, ISSUE_RATES[kind] * self.quality[site_id])

    def log(self, issue_type, subtype, subject_id, visit_code=None, form_code=None, detail=""):
        self.issues.append({"issue_type": issue_type, "subtype": subtype,
                            "site_id": subject_id.split("-")[0], "subject_id": subject_id,
                            "visit_code": visit_code, "form_code": form_code, "detail": detail})

    def visit_frame(self):
        v = self.visits.merge(self.subjects[["subject_id", "site_id", "randomization_date",
                                             "discontinuation_date", "consent_date"]],
                              on="subject_id")
        return v

    def run(self):
        self.out_of_window()
        self.missing_ecrf()
        self.implausible_change()
        self.inconsistent_dates()
        issues = pd.DataFrame(self.issues)
        issues.insert(0, "issue_id", range(1, len(issues) + 1))
        self.issues_df = issues
        return self

    # ---------------------------------------------------------------------
    def out_of_window(self):
        v = self.visit_frame()
        cand = v[v.visit_code.isin(POST_BL) & (v.visit_status == "Completed")]
        for _, r in cand.iterrows():
            if not self.hit("OUT_OF_WINDOW", r.site_id):
                continue
            _, _, _, target, w_start, w_end = self.schedule[r.visit_code]
            baseline = r.randomization_date
            k = int(self.rng.integers(3, 22))
            late = baseline + days(w_end - 1 + k)
            early = baseline + days(w_start - 1 - k)
            forms = self.ecrfs[self.ecrfs.visit_id == r.visit_id]
            next_visits = v[(v.subject_id == r.subject_id) & v.visit_date.notna() &
                            (v.visit_date > r.visit_date)]
            late_ok = (late + (forms.entered_date.max() - r.visit_date if len(forms) else days(0)) <= CUTOFF
                       and (pd.isna(r.discontinuation_date) or late < r.discontinuation_date)
                       and (next_visits.empty or late < next_visits.visit_date.min()))
            new_date = late if (late_ok and self.rng.random() < 0.6) else early
            delta = new_date - r.visit_date
            self.visits.loc[self.visits.visit_id == r.visit_id, "visit_date"] = new_date
            fmask = self.ecrfs.visit_id == r.visit_id
            self.ecrfs.loc[fmask, "entered_date"] += delta
            self.ecrfs.loc[fmask, "sdv_date"] += delta
            sdv_late = fmask & (self.ecrfs.sdv_date > CUTOFF)
            self.ecrfs.loc[sdv_late, ["form_status", "sdv_date"]] = ["Entered", pd.NaT]
            self.assess.loc[self.assess.visit_id == r.visit_id, "assessment_date"] = new_date
            sday = study_day(new_date, baseline)
            self.touched_visits.add(r.visit_id)
            self.log("OUT_OF_WINDOW", "LATE" if delta > days(0) else "EARLY", r.subject_id,
                     r.visit_code, detail=f"study day {sday}, window {w_start} to {w_end}")

    def missing_ecrf(self):
        e = self.ecrfs.merge(self.visit_frame()[["visit_id", "subject_id", "site_id",
                                                 "visit_code", "visit_date"]], on="visit_id")
        cand = e[(e.visit_date <= CUTOFF - days(30)) & ~e.visit_id.isin(self.touched_visits)]
        drop = []
        for _, r in cand.iterrows():
            if self.hit("MISSING_ECRF", r.site_id):
                drop.append(r.ecrf_id)
                self.log("MISSING_ECRF", None, r.subject_id, r.visit_code, r.form_code,
                         detail=f"visit date {r.visit_date.date()}, form never entered")
        self.ecrfs = self.ecrfs[~self.ecrfs.ecrf_id.isin(drop)]
        self.assess = self.assess[~self.assess.ecrf_id.isin(drop)]
        if len(self.queries):
            q_keep = ~self.queries.set_index(["visit_id", "form_code"]).index.isin(
                list(e[e.ecrf_id.isin(drop)][["visit_id", "form_code"]].itertuples(index=False, name=None)))
            self.queries = self.queries[q_keep]

    def implausible_change(self):
        a = self.assess.merge(self.visit_frame()[["visit_id", "subject_id", "site_id",
                                                  "visit_code", "visit_date"]], on="visit_id")
        a = a.sort_values(["subject_id", "instrument", "visit_date"])
        for (_subj, inst), grp in a.groupby(["subject_id", "instrument"]):
            rows = list(grp.itertuples())
            skip_next = False
            for prev, cur in zip(rows, rows[1:]):
                if skip_next:
                    skip_next = False
                    continue
                if cur.visit_id in self.touched_visits or not self.hit("IMPLAUSIBLE_CHANGE", cur.site_id):
                    continue
                lo, hi = SCORE_RANGE[inst]
                jlo, jhi = IMPLAUSIBLE_JUMP[inst]
                jump = (self.rng.integers(jlo, jhi + 1) if inst != "CDRSB"
                        else self.rng.integers(int(jlo * 2), int(jhi * 2) + 1) / 2)
                worse = 1 if HIGHER_IS_WORSE[inst] else -1
                new = prev.total_score + worse * jump              # sudden worsening
                if not lo <= new <= hi:
                    new = prev.total_score - worse * jump          # or sudden improvement
                if not lo <= new <= hi:
                    continue
                self.assess.loc[self.assess.assessment_id == cur.assessment_id, "total_score"] = float(new)
                self.touched_visits.add(cur.visit_id)
                skip_next = True
                self.log("IMPLAUSIBLE_CHANGE", inst, cur.subject_id, cur.visit_code,
                         [f for f, i in FORM_TO_INSTRUMENT.items() if i == inst][0],
                         detail=f"{prev.visit_code} {prev.total_score:g} -> {cur.visit_code} {new:g}")

    def inconsistent_dates(self):
        rng = self.rng
        v = self.visit_frame()
        subj_touched = set()

        # a) screening visit before informed consent
        for i, s in self.subjects.iterrows():
            if self.hit("VISIT_BEFORE_CONSENT", s.site_id):
                new = s.screening_date + days(rng.integers(2, 11))
                if new > CUTOFF:
                    continue
                self.subjects.at[i, "consent_date"] = new
                subj_touched.add(s.subject_id)
                self.log("INCONSISTENT_DATE", "VISIT_BEFORE_CONSENT", s.subject_id, "SCR", None,
                         f"consent {new.date()} after screening visit {s.screening_date.date()}")

        # b) randomization date does not match the baseline visit date
        rand = self.subjects[self.subjects.randomization_date.notna()]
        for i, s in rand.iterrows():
            if s.subject_id in subj_touched or not self.hit("RANDOMIZATION_MISMATCH", s.site_id):
                continue
            shift = int(rng.integers(3, 16)) * (1 if rng.random() < 0.5 else -1)
            new = s.randomization_date + days(shift)
            if new > CUTOFF:
                continue
            self.subjects.at[i, "randomization_date"] = new
            subj_touched.add(s.subject_id)
            self.log("INCONSISTENT_DATE", "RANDOMIZATION_MISMATCH", s.subject_id, "BL", None,
                     f"randomization {new.date()} vs baseline visit {s.randomization_date.date()}")

        # c) a visit recorded after the discontinuation date
        disc = self.subjects[self.subjects.discontinuation_date.notna()]
        for i, s in disc.iterrows():
            if s.subject_id in subj_touched or not self.hit("VISIT_AFTER_DISCONTINUATION", s.site_id):
                continue
            sv = v[(v.subject_id == s.subject_id) & v.visit_date.notna()].sort_values("visit_date")
            sv = sv[sv.visit_code.isin(POST_BL)]
            if sv.empty:
                continue
            last = sv.iloc[-1]
            floor = sv.iloc[-2].visit_date if len(sv) > 1 else s.randomization_date
            gap = (last.visit_date - floor).days
            if gap < 5:
                continue
            new = last.visit_date - days(rng.integers(2, min(25, gap - 1)))
            self.subjects.at[i, "discontinuation_date"] = new
            subj_touched.add(s.subject_id)
            self.log("INCONSISTENT_DATE", "VISIT_AFTER_DISCONTINUATION", s.subject_id,
                     last.visit_code, None,
                     f"discontinued {new.date()} but {last.visit_code} on {last.visit_date.date()}")

        # d) assessment date differs from its visit date
        a = self.assess.merge(v[["visit_id", "subject_id", "site_id", "visit_code", "visit_date"]],
                              on="visit_id")
        a = a[(a.visit_code != "SCR") & ~a.visit_id.isin(self.touched_visits)]
        for _, r in a.iterrows():
            if not self.hit("ASSESSMENT_DATE_MISMATCH", r.site_id):
                continue
            new = r.visit_date - days(rng.integers(5, 41))
            self.assess.loc[self.assess.assessment_id == r.assessment_id, "assessment_date"] = new
            self.touched_visits.add(r.visit_id)
            self.log("INCONSISTENT_DATE", "ASSESSMENT_DATE_MISMATCH", r.subject_id, r.visit_code,
                     [f for f, i in FORM_TO_INSTRUMENT.items() if i == r.instrument][0],
                     f"{r.instrument} dated {new.date()}, visit on {r.visit_date.date()}")

        # e) eCRF entered before the visit took place
        e = self.ecrfs.merge(v[["visit_id", "subject_id", "site_id", "visit_code", "visit_date"]],
                             on="visit_id")
        e = e[~e.visit_id.isin(self.touched_visits)]
        for _, r in e.iterrows():
            if not self.hit("ENTRY_BEFORE_VISIT", r.site_id):
                continue
            new = r.visit_date - days(rng.integers(1, 11))
            m = self.ecrfs.ecrf_id == r.ecrf_id
            self.ecrfs.loc[m, "entered_date"] = new
            self.ecrfs.loc[m & self.ecrfs.sdv_date.notna() & (self.ecrfs.sdv_date < new),
                           "sdv_date"] = new
            self.touched_visits.add(r.visit_id)
            self.log("INCONSISTENT_DATE", "ENTRY_BEFORE_VISIT", r.subject_id, r.visit_code,
                     r.form_code, f"entered {new.date()}, visit on {r.visit_date.date()}")


# =============================================================================
# Output
# =============================================================================

def reference_tables():
    return {
        "study": pd.DataFrame([STUDY]),
        "study_arms": pd.DataFrame(ARMS),
        "sites": pd.DataFrame(
            [{"site_id": s[0], "site_name": s[1], "country": s[2], "city": s[3],
              "principal_investigator": s[4],
              "activation_date": STUDY["study_start_date"] + days(s[5]),
              "target_enrollment": s[6]} for s in SITES]),
        "visit_schedule": pd.DataFrame(VISITS, columns=["visit_code", "visit_name", "visit_order",
                                                        "target_day", "window_start_day",
                                                        "window_end_day"]),
        "forms": pd.DataFrame(FORMS, columns=["form_code", "form_name", "form_category"]),
        "form_schedule": pd.DataFrame([{"visit_code": v, "form_code": f}
                                       for v, fs in FORM_SCHEDULE.items() for f in fs]),
    }


def write_csv(df: pd.DataFrame, path: Path):
    out = df.copy()
    for col in out.columns:
        if pd.api.types.is_datetime64_any_dtype(out[col]):
            out[col] = out[col].dt.strftime("%Y-%m-%d")
    out.to_csv(path, index=False)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seed", type=int, default=301, help="random seed (same seed = same data)")
    parser.add_argument("--out", type=Path,
                        default=Path(__file__).resolve().parent.parent / "data" / "simulated")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)

    sim = Simulator(args.seed).run()
    inj = Injector(sim, args.seed).run()

    tables = reference_tables()
    tables.update({
        "subjects": inj.subjects,
        "visits": inj.visits,
        "ecrf_forms": inj.ecrfs,
        "cognitive_assessments": inj.assess,
        "queries": inj.queries,
        "injected_issues": inj.issues_df,
    })
    for name, df in tables.items():
        write_csv(df, args.out / f"{name}.csv")

    s = inj.subjects
    print(f"Wrote {len(tables)} CSV files to {args.out}")
    print(f"  screened {len(s)}, randomized {s.arm_code.notna().sum()} "
          f"(target {STUDY['target_enrollment']}), screen failed {(s.subject_status == 'Screen Failed').sum()}")
    print(f"  visits {len(inj.visits)}, eCRFs {len(inj.ecrfs)}, assessments {len(inj.assess)}, "
          f"manual queries {len(inj.queries)}")
    print("  planted issues:")
    counts = inj.issues_df.fillna({"subtype": ""}).groupby(["issue_type", "subtype"]).size()
    for (t, st), n in counts.items():
        print(f"    {t:<20} {st:<28} {n}")


if __name__ == "__main__":
    main()
