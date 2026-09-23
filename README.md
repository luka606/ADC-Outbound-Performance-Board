# ADC Outbound — Performance Board

Replaces the per-agent Google Sheet with a single web app: agents enter daily numbers,
everything saves to Supabase, and you review it in Meeting / Scorecard / Admin views.

## What's in the box
- `index.html` — the board (one self-contained file, no build step)
- `bridge.html` — the **M2 Bridge** workspace as its own page (own sign-in; opened from the brand dropdown)
- `qualification.html` — the **Team Qualification** scorecard (M4) as its own page (shares the Bridge sign-in; opened from the brand dropdown)
- `schema.sql` — core Outbound tables (agents, daily reports, bookings, settings, weekly
  history) + security policies + agent seed
- `sales_schema.sql` — tables for the **Office Sales** workspace (salespersons, daily metrics, sales log)
- `jobs_schema.sql` — tables for the **Job Assignment** workspace (technicians, job assignments)
- `adc_db_schema.sql` — the `adc_database` customer contact list behind the **Database** tab
- `crm_sync_schema.sql` — the `crm_*` columns on `bookings` that the CRM sync writes
- `coverage_schema.sql` — the **Coverage** tab: `coverage_log`, `coverage_days`, and the approved-list
  fields on `technicians` (run after `jobs_schema.sql`)
- `bridge_schema.sql` — the **M2 Bridge** workspace: twelve `bridge_*` tables, the role allowlist and
  the release gates (run after `coverage_schema.sql`; needs Supabase Auth — see below)
- `qualification_schema.sql` — the **Team Qualification** scorecard: twenty-one `qual_*` tables (versioned metric
  configuration, teams, source records, exclusions, immutable snapshots, official decisions, audit) — run after
  `bridge_schema.sql`; reuses its roles
- `scripts/crm-sync.mjs` — reconciles each booking's job reference against the CRM
- `tests/` — jsdom suites (`npm install && npm test`): the Bridge brief's §10 scenarios and the Qualification brief's
  25 acceptance tests, each run against an in-memory database that mirrors the schema's rules

The SQL files do not overlap, and each is idempotent — safe to re-run at any time.

## Setup (about 10 minutes)

### 1. Create / update the database
1. Go to [supabase.com](https://supabase.com) → **New project** (free tier is fine).
2. Open **SQL Editor → New query**, paste all of `schema.sql`, click **Run**.
   This creates the tables and seeds your six agents (Shiena, Levi, Reagan, Jane, Felicia, Toni).
   No admin PIN is seeded — the first person to open the Admin view is prompted to set one.
   - **Already have a database from an earlier version?** Just run `schema.sql` again — it's
     safe to re-run and includes the migrations that add the new `booked_appointments`,
     `cross_bookings`, and `weekly_history` structures.
3. Run `sales_schema.sql` and `jobs_schema.sql` if you want the Office Sales and Job Assignment
   workspaces, and `adc_db_schema.sql` for the Calling Database tab.
4. Open **Project Settings → API** and copy two things:
   - **Project URL** (e.g. `https://abcd.supabase.co`)
   - **anon public** key

### 2. Deploy to Vercel
Option A — drag & drop (fastest):
1. Put `index.html` in an empty folder.
2. Go to [vercel.com](https://vercel.com) → **Add New → Project → deploy** and drop the folder,
   or run `npx vercel` from the folder.

Option B — Git: push the folder to GitHub and import it in Vercel. No framework, no build command.

Vercel serves it over HTTPS automatically — required for Touch ID to work.

### 3. First run

**Live:** https://adc-outbound-performance-board-omega.vercel.app

1. Open the URL above. It asks for the **Supabase URL** and **anon key** — paste them
   (stored only in that browser's local storage).
2. Each agent opens the same URL, picks their name once on the **Report** tab — the device remembers it.

## How it works
- **Report** — the agent's daily entry. If they log any booking or cross-booking, they must
  enter a **5-digit job reference** for each one; Submit stays disabled until every reference is
  valid and unique.
- **Meeting** — a **ranked leaderboard** (rank · avatar · call-outcome mix bar with a team-average
  tick · Calls / Bookings / Contact→booking). Sort by bookings, calls, reach %, or conversion, and
  pick the period. Click any row to open the **agent report** (KPIs, target progress, bookings in
  period) with ‹ › to move between agents.
- **Scorecard** — full metric set filtered by period (Yesterday / This week / Last week /
  This month / Last month / Last 30d) and by agent. Groups (Activity / Lead Conversion / Sales /
  Operations) now have bold, clearly separated headers.
- **Admin** — unlocked with the **admin PIN** via the **Admin button in the top-right header**
  (shows "Admin ✓" when on; click again to lock). Only admins should know the PIN — it's
  pre-set on an existing database; on a fresh one the first person to open Admin sets it.
  Admin lets you:
  - Set **sale amount** + **status** (sold / ran, not sold / cancelled) on each booking, and
    **delete** an individual booking (which also corrects that day's booking count).
  - **Edit or delete a CSR's daily entry** under *Daily entries* — fix a mistyped number or
    remove a wrong day (deleting a day also removes that day's bookings).
  - Manage agents and targets, change the PIN, and edit the Supabase connection.
- **Touch ID / fingerprint** — after the PIN exists, open **Admin → Connection & security →
  "Enable Touch ID on this device."** After that, clicking **Admin** tries Touch ID first and
  falls back to the PIN. Enrolment is per-device; the PIN always works. (Requires HTTPS, which
  Vercel provides.)
- **Dark / light theme** — the ◐/☀ toggle in the header; remembered on the device.

## Historical data — what's included
A one-time backfill (already applied to the live database) carried every agent's daily
**call activity and booking/cross-booking counts**
(validated against the source sheet's own weekly totals). Two honest limitations of the source:
- **No job references or sale amounts per booking** — the sheet never tracked them daily, so
  historical bookings appear as counts (Meeting/Scorecard work fully) but not as rows in the
  Admin bookings table, and **revenue metrics for historical periods read $0**. Revenue builds
  up from the day admins start marking live bookings sold.
- **Known source typo:** Felicia, Jul 13 — "Not Interested" = 112 in the sheet (impossible vs
  120 calls / 20 reached; likely meant 12). Imported as-is; correct it in
  **Admin → Daily entries → Edit** if desired.

## Metric definitions
| Metric | Formula |
|---|---|
| Contact→booking | Booked appointments ÷ reached contacts |
| Call→booking | Booked appointments ÷ total calls |
| ADL | Revenue ÷ leads (bookings + cross-bookings) |
| AVT | Revenue ÷ sold jobs |
| Revenue per call | Revenue ÷ total calls |
| Runs | Bookings marked *sold* or *ran, not sold* |
| Jobs scheduled | All appointments booked (bookings + cross) |
| Cancellation % | Cancelled ÷ jobs scheduled |

## Security note
The included policies let the **anon key** read/write all tables — appropriate for an internal
team tool. The admin **PIN** is stored as a SHA-256 hash in `app_settings` and gates the Admin
**UI**. Because the app has no backend server, this is UI-level protection (a determined person
with the anon key could read the hash and brute-force a short PIN). That's the same model as the
Job Efficiency Board. If you ever need hardened admin (server-verified), that means adding
Supabase Auth or a small Vercel serverless function — happy to add it.


## Workspaces (brand dropdown, top-left)
Click the **ADC OUTBOUND ▾** name in the top-left to switch workspaces:
- **ADC Outbound** — the outbound board (Report / Meeting / Scorecard / Admin).
- **Office Sales** — an in-office sales tracker, identical to the Job Efficiency Board's:
  - **Dashboard** — KPIs (potentials, reach rate, sold #/$, closing ratio, ADL), a by-salesperson
    table, sold-$-by-day bars, and a funnel. Filter by range and salesperson.
  - **Daily Metrics** — one row per salesperson per day; Sold #/$ pull automatically from the
    Sales Log; reach rate, closing ratio, and ADL self-calculate. Saves on blur.
  - **Sales Log** — one row per sold job (CRM reference, amount, date); feeds every sold metric.
    Filter, search, and export CSV.
  - **Salespersons** — add / rename / deactivate / delete. Renaming updates history.

  Run **`sales_schema.sql`** once in Supabase to create its tables. It uses the same Supabase
  connection as the rest of the app — no separate setup.


## Access & security (this build)
- **Login gate** — until a Supabase URL + anon key are entered, the app shows *only* the login
  screen and the dark/light toggle. All nav bars, the workspace switcher, and Admin stay hidden.
- **Log out** — a **Log out** button (top-right) returns to the login screen so you can enter or
  re-enter keys / switch projects. It clears the admin and Office Sales sessions for the browser.
- **Admin is platform-wide** — unlocking Admin applies to *both* workspaces. In ADC
  Outbound it reveals the Admin tab; in Office Sales it reveals salesperson management + PINs.
- **Everything runs on PST** — "today", period ranges, and all date logic use
  America/Los_Angeles regardless of the viewer's device timezone.

## Office Sales access (per-salesperson PINs)
- Each salesperson gets a **unique 6-character PIN**, generated automatically when an **admin**
  adds them (only admins can add salespersons or issue PINs). The PIN is shown in the
  Salespersons table (admin view) and via **New PIN** to reissue.
- Opening the **Office Sales** workspace prompts for a PIN; a valid active salesperson's PIN (or
  admin mode) grants access for the session. Run the updated `sales_schema.sql` to add the `pin`
  column if your salespersons table predates this build.

## Booking references
Booking and cross-booking references are now **6 characters, letters + numbers** (e.g. `X32RT7`),
entered uppercase and required-unique before a report can be submitted.

Note the uniqueness check is **client-side only** — there is no unique constraint in the
database, so a direct API write or two simultaneous submits could still create a duplicate.

## CRM status sync

`scripts/crm-sync.mjs` matches every booking's job reference against the Apollo CRM and records
what the CRM says about that job, so **Cancelled** and **Needs review** reflect reality instead
of what someone remembered to update.

```bash
node scripts/crm-sync.mjs --dry-run    # print every intended change, write nothing
node scripts/crm-sync.mjs              # apply
```

Run `crm_sync_schema.sql` once first. Credentials are read from `~/.claude/secrets/apollo.env`
and `~/.config/adc/supabase.env` — **never** from this repo. The sync runs server-side on
purpose: this app is a single public static file, so a token placed in it would be world-readable.

**What it does with each answer:**

| CRM says | booking is `pending` | booking is `sold` / `ran not sold` |
|---|---|---|
| `Canceled` (40) | → `cancelled` | left alone, flagged under **Conflicts** |
| anything else | stays in **Needs review** | left alone |

It never reverts a recorded sale and never un-cancels. Both of those reverse a decision a person
made, so they are surfaced as conflicts rather than applied.

**Needs review** is therefore *the CRM does not call it cancelled, and nobody has recorded an
outcome yet*. Adding a sale amount or marking "ran, not sold" drops the row out of the queue.
Jobs the CRM has already **Closed** sort to the top — those are the ones you can actually answer.

**Things worth knowing about the CRM API:**
- The CRM spells it **"Canceled"** with one L; this app uses `cancelled` with two. The sync
  matches on the status *code* (40). Any string comparison silently misses every cancellation.
- Its window is capped at **7 days** and filters on `updated_at`, not the job date — so it is a
  change feed, and an old job reappears whenever its status moves. The sync walks backwards a
  window at a time until every reference resolves.
- A reference the sync cannot find is **left unsynced and reported**, never guessed at. Jobs
  cancelled before a technician was ever assigned appear to be absent from the log entirely.
- `Closed` is an accounting status, not a sale. That is exactly why those land in Needs review
  rather than being counted as revenue.

## Targets in Meeting

The two weekly numbers you set per agent in Admin — **Target bookings** and **Target
cross-bookings** — are **added together** into one goal, because a cross-booking counts toward
target just like a booking. Defaults are 5 + 3, so 8 a week.

That weekly figure is then **prorated across whatever period Meeting is showing**:

```
target   = (target_bookings + target_crossbookings) × days ÷ 7
attained = (bookings − cancelled) + (cross-books − cancelled)
```

A period that includes today counts only the **days elapsed so far**, so an agent who is on pace
reads 100% on a Tuesday instead of looking two-thirds behind. "Yesterday" is one seventh of the
weekly target, not the whole thing — which is what it used to show.

Attainment appears on every leaderboard row, as a team KPI, and as the bar in the agent
drill-down. **Vs target** is also a sort option.

**Booked is net of cancellations everywhere.** A cancelled cross-booking comes off the
cross-booking total, not the booking total.

> **Periods before 2026-07-22 are counted gross.** Individual bookings only start being recorded
> on that date; the 151 daily reports before it carry a booking *count* with no rows behind it,
> from the one-time historical backfill. Which of those were cancelled is unknowable, so any
> period reaching back that far marks the affected figures with `*` and says so, rather than
> printing a net number it cannot actually compute. From 2026-07-22 onward the counts and the
> rows agree exactly.

## Custom date ranges
Both **Meeting** and **Scorecard** now include a **Custom** period with From/To date pickers, in
addition to the presets.


## Built-in SOP tab
Both guides are embedded in the app. The **SOP** tab (last tab in both the ADC Outbound and
Office Sales navs) lets anyone **Open guide** (opens full-screen in a new browser tab, ready to
print) or **Preview** it inline. No extra files need to be deployed — the guides travel inside
`index.html`. The standalone `SOP_Outbound_Agent.*` and `SOP_Office_Sales.*` files remain
available for printing or sharing outside the app.


## Job Assignment workspace
Third workspace in the brand dropdown (**Job Assignment**). Run **`jobs_schema.sql`** once in
Supabase to create its two tables (`technicians`, `job_assignments`), then **`coverage_schema.sql`**
for the Coverage tab. Four tabs:

1. **Today's Assignment** — pick a date, choose **job type (ADC / DVC)**, technician, and the
   number of jobs, then Assign. Assigning the same technician + type for that date updates the
   number rather than duplicating it. Below, the day's rows are listed with editable counts and
   Remove, plus KPI cards (jobs assigned, ADC, DVC, technicians assigned, avg jobs/tech).
2. **Breakdown** — totals over **This week / Last week / This month / Last month / Custom**
   (with From/To), filterable by job type and technician. Shows KPIs, a by-technician table
   (ADC, DVC, total, days assigned, avg/day, share %), share-of-jobs and jobs-by-day bars, a
   full assignment list, and CSV export.
3. **Technicians** — add, rename, deactivate, or delete technicians. **Open to DSRs — no admin
   needed.** Deactivating hides someone from the dropdown but keeps their history; deleting
   removes them from the list while past assignments keep the name. **Approved** is separate
   and admin-only: it marks who is on the frozen approved-technician list, with their areas,
   job types (estimate / install / both), availability and contact method. A newly added
   technician is *not* approved until an admin approves them.
4. **Coverage** — the coverage log (Rock *ADC Ironclad Coverage*, milestone 1 · SOP ADC-DSR-001).
   No ADC job is rejected until every **approved, active** technician who matches the area and
   job type has been offered it, and every offer is written down. One row per offer or status
   change — a job moves through **Uncovered · Reassigned · Rejected · Potentially lost ·
   Confirmed lost** and each is a new row, never an overwrite. Per day: owner, backup and
   review times; totals computed from each job's latest row; jobs still open from earlier days
   carried over automatically; a seven-point end-of-day review that closes the day. Three rules
   are enforced by the database, not just the form: **Rejected needs at least one technician
   offered**, **Confirmed lost needs a reason**, **Reassigned needs a final assignee** — and every
   offered name must be approved and active at the time. Nothing in the log can be deleted.

All dates follow PST like the rest of the platform.


## M2 Bridge workspace
Fourth entry in the brand dropdown (**M2 Bridge ↗**) — it opens **`bridge.html`**, a separate page, so the
board's single file stays the board and the Bridge can keep growing. Built from the brief *ADL — M2 High-Value-Job
Bridge* (2026-09-18) for Rock *ADC Ironclad Coverage* milestone 2. It protects high-value sales during
the transition while preserving gross margin: every high-value lead is recorded with its indicators and
evidence, staffed by route (**combined technician** or **Sagi**), estimated in versions, priced through an
**economics version** (R, D, C, K, gross profit, margin, gate), and released only through two written
approvals — the estimate visit and the work release. Seven sub-tabs: Queue · Opportunity · Approvals
(one-hour timers) · Reconciliation · Scorecard · Coverage register · Settings.

**It is the only part of the board with real sign-in.** The brief requires approvals that are evidence,
so the Bridge uses Supabase Auth (magic link) with a two-role allowlist — `manager` (Luka: approvals,
release, Sardor exceptions, settings) and `dispatcher` (Vasyl) — and the database stamps the approver
from the signed-in identity. The page has its own two Supabase clients (anon for the roster, a session-holding one for the `bridge_*`
tables, under its own storage key), so signing in changes nothing for the board. Sardor does not sign in: a margin exception is recorded by the manager on
his behalf and must carry how he confirmed (text / call) and a reference.

**Rules the database enforces** (`bridge_schema.sql`): release needs an approved economics version whose
gate is at floor (or a recorded Sardor exception for that exact version), an accepted estimate, every
service classified with a margin rule, no unknown cost, and — on Sagi's route — an approved installer and
an explicitly approved job-level amount. Approvals and events are append-only; an approved economics
version is immutable and a later change creates a new version and pulls the job back to review.

**Every business value carries the brief's own status** — confirmed / proposed / unresolved — in
`bridge_config` and the Settings tab. Unresolved values are `null` and block what depends on them; nothing
is defaulted silently. Money is integer cents; margins are compared unrounded.

**Setup (Luka, once):** Supabase → Authentication → Providers → Email: on, magic link on, sign-ups **off**;
URL configuration → Site URL = the deployed URL and an additional redirect URL of `<deployed URL>/bridge.html`
(the magic link returns to the Bridge page). Authentication → Users → add
`luka.m@homealliance.com` and `vasyl.k@homealliance.com` (Auto Confirm). Run **`bridge_schema.sql`**; if
the users existed the roles are seeded, otherwise `select grant_bridge('email','manager')`. The SLA watch
(`adc-bridge-sla-watch`, a scheduled task) reads pending requests with the service-role key and DMs Luka
about overdue or urgent ones — **off until `notify_enabled` is true** in Settings.


## Team Qualification workspace (M4)
Fifth entry in the brand dropdown (**Team Qualification ↗**) — opens **`qualification.html`**, its own page, built
from the brief *ADL — M4 Team Qualification Scorecard and Reporting Structure* (2026-09-23) for Rock *ADC Ironclad
Coverage* milestone 4. One balanced standard for every technician-sales team — incumbents, candidates and a rebuilt
team led by the former technician: seven weighted categories (sales 20 · revenue efficiency 15 · coverage 15 ·
attendance 10 · completion 15 · customer quality 15 · compliance 10), bands 100/70/40/0, non-negotiable gates,
evidence states (Pending Entry Review → Supervised Trial → Pending Evidence → Decision Eligible) and four official
outcomes — Pass · Coaching · Probation · Disqualify — recorded only by the manager on a **frozen evidence snapshot**
tied to the metric version in force. Six tabs: Overview · Teams (comparison) · Team (detail, every source record,
drill-downs, the decision form) · Queues · Configuration (versions) · Definitions · **SOP** (the dispatcher's
procedure, ADC-QUAL-001, readable before data loads — names the role, never the person).

**Design (2026-09-23).** The page follows the claude.ai/design project *Team Qualification* — an Apple-system look:
one accent, grouped inset lists, segmented controls, ring and bar scores, and **sheets instead of browser prompts** for
every entry. The Team page is a summary (score ring, official vs recommended, gates, seven categories with drill-down,
evidence progress) plus **guided daily entry** for the dispatcher (lead → appointment → job → completion, with a
"continue where you left off" list) and one page per record type. Timestamps typed on the page are Pacific time
regardless of the machine's zone.

**Sign-in and roles are the Bridge's** (`bridge_roles`: manager / dispatcher, same storage key), so one magic link
serves both pages. The dispatcher records leads, estimate versions, appointments, jobs, costs, promise-date
reschedules, availability, coverage offers and responses, quality events, compliance checks, supervised-job notes,
and requests exclusions; the manager completes entry reviews, approves members and exclusions, signs off supervised
jobs, rules on substantiation, confirms incidents, imposes and lifts restrictions, activates metric versions and
records decisions. Technicians do not sign in and nobody edits a calculated total — corrections happen in the source
record or through an approved exclusion.

**The engine is a pure function** (`qualCompute`) of team, metric version, source rows, period and clock: every
rate carries numerator, denominator, n, excluded and missing counts and the source ids behind it; a zero denominator
is `N/A`; an unknown cost never becomes zero; a job with several quality events counts once; immature jobs are shown
separately; eligibility of a coverage offer is frozen when the offer is made, so a later availability edit cannot
remove it; the weighted score is definitive only when every category has points. The frozen snapshot is exactly the
engine's output.

**Rules the database enforces** (`qualification_schema.sql`): weights must total exactly 100 and bands be strictly
ordered or the version is refused; a version used in an official decision is immutable; only one version is active;
Pass is refused unless the snapshot is Decision Eligible with a definitive score, every gate passed and no 0-point
band; Coaching and Probation need a named issue, corrective action, owner, due date and next review (the action row
is created from the decision); snapshots, decisions, estimate versions and reschedules are insert-only; the original
promise date never changes; a locked availability row cannot be edited; a pass on a compliance check needs evidence;
every exclusion is a row with requester, reason, approver and time. `anon` is revoked from every `qual_*` table.
Sensitive actions land in `qual_audit`.

**Requirement status is data.** Metric v1 is seeded as a **draft** with the brief's proposed defaults; every
unresolved value (§18) — above all the **revenue-efficiency baseline** — is `null` with status `unresolved`, and the
page says official scoring is blocked until the manager activates a version that resolves it. Nothing is guessed.

**Setup (Luka, once):** run **`qualification_schema.sql`** after `bridge_schema.sql`; add `<deployed URL>/qualification.html`
to Supabase → Authentication → URL configuration → Redirect URLs (a link that lands on the Bridge still signs you in
for both pages). Review draft v1 in **Configuration**, set the baseline and thresholds you approve, activate. Add each
team on **Teams**, its roster, and complete the entry review. Ninety and ClickUp rollups are summary-only and are not
prerequisites for anything here.

## Calling Database (ADC Outbound → Database tab)
Imported from the **ADC Calling List** spreadsheet (tabs *ADC Res*, *ADC Commercial*, *DVC*):
**11,335 real records** (blank spreadsheet padding rows excluded).

**Setup — two steps, in order:**
1. Run **`adc_db_schema.sql`** in Supabase → SQL Editor (creates `adc_database`).
2. Import your contact list as CSV — Supabase → Table Editor → `adc_database` → Insert →
   *Import data from CSV*. A CSV import is far more reliable than a giant SQL file.
   The CSV is **not** in this repo and must not be: it holds customer names, phone numbers,
   emails, and addresses, and this repository is public. Export it from the ADC Calling List
   spreadsheet when you need it.

**The Database tab shows:**
- **Overview** — records, still callable, booked, do-not-call, never called, contact rate.
- **Runway** — how long the list lasts at your staffing. Editable assumptions (agents,
  calls/agent/day, attempt cap) recalculate everything live. Two honest scenarios: one call to
  each unique number, and the full attempt policy using remaining attempt-slots.
- **Composition** — every record in exactly one bucket, with a per-segment table.
- **Data quality** — quality score, unique numbers, duplicate rows, bad/dead numbers, records
  with no phone, booking rate when reached, each with a plain-English explanation.
- **Every disposition** — full distribution with its bucket and share.
- **Records** — search by name/phone/job ref, filter by segment and bucket, and update a
  disposition inline so the whole analysis stays current.
- **Exports** — an **AI brief (JSON)** containing every figure plus definitions and the questions
  it supports, a **Markdown report**, and the **full records CSV**. There's also a *Copy AI brief*
  button for pasting straight into a chat.

Dispositions are the single source of truth; buckets are derived in the app, so editing a
disposition immediately reclassifies the record everywhere.
