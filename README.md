# ADC Outbound — Performance Board

Replaces the per-agent Google Sheet with a single web app: agents enter daily numbers,
everything saves to Supabase, and you review it in Meeting / Scorecard / Admin views.

## What's in the box
- `index.html` — the entire app (one self-contained file, no build step)
- `schema.sql` — core Outbound tables (agents, daily reports, bookings, settings, weekly
  history) + security policies + agent seed
- `sales_schema.sql` — tables for the **Office Sales** workspace (salespersons, daily metrics, sales log)
- `jobs_schema.sql` — tables for the **Job Assignment** workspace (technicians, job assignments)
- `adc_db_schema.sql` — the `adc_database` customer contact list behind the **Database** tab

The four SQL files do not overlap, and each is idempotent — safe to re-run at any time.

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
1. Open your Vercel URL. It asks for the **Supabase URL** and **anon key** — paste them
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
Supabase to create its two tables (`technicians`, `job_assignments`). Three tabs:

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
   removes them from the list while past assignments keep the name.

All dates follow PST like the rest of the platform.


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
