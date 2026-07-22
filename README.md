# ADC Outbound — Performance Board

Replaces the per-agent Google Sheet with a single web app: agents enter daily numbers,
everything saves to Supabase, and you review it in Meeting / Scorecard / Admin views.

## What's in the box
- `index.html` — the entire app (one self-contained file, no build step)
- `schema.sql` — database tables + security policies + agent seed

## Setup (about 10 minutes)

### 1. Create the database
1. Go to [supabase.com](https://supabase.com) → **New project** (free tier is fine).
2. Open **SQL Editor → New query**, paste all of `schema.sql`, click **Run**.
   This creates the tables and seeds your six agents (Shiena, Levi, Reagan, Jane, Felicia, Toni).
3. Open **Project Settings → API** and copy two things:
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
- **Meeting** — a card per agent (calls / bookings / cross at a glance + 14-day trend line).
  Click a card to open their performance detail and recent bookings.
- **Scorecard** — full metric set filtered by period (Yesterday / This week / Last week /
  This month / Last month / Last 30d) and by agent.
- **Admin** — unlocked with **Touch ID** (register once per Mac). Shows consolidated
  Yesterday / Last week / Last month totals, and lets you set **sale amount** + **status**
  (sold / ran, not sold / cancelled) on each booking, manage agents, and edit the connection.

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
team tool. The Touch ID gate protects the Admin **UI**, but because the app has no backend
server, it can't cryptographically verify the biometric assertion. If you later need
hardened admin (server-verified), that requires adding a small Vercel serverless function —
happy to add it.
