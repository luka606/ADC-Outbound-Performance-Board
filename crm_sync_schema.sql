-- =====================================================================
-- ADC Outbound Performance Board — CRM status sync
-- =====================================================================
-- Run in Supabase > SQL Editor, after schema.sql. Idempotent.
--
-- Adds the columns `scripts/crm-sync.mjs` writes when it reconciles each
-- booking's job reference against the Apollo CRM.
--
-- WHY THESE ARE SEPARATE COLUMNS -------------------------------------
-- `bookings.status` stays the board's own outcome — what the team decided.
-- The `crm_*` columns are the CRM's opinion, recorded alongside it. Keeping
-- them apart means the two can disagree visibly instead of one silently
-- overwriting the other, and a bad sync can be undone by clearing the
-- `crm_*` columns without touching a single human decision.
--
-- The sync only ever writes `status` in one direction: pending -> cancelled,
-- when CRM says the job is Canceled. It never reverts a recorded sale and
-- never un-cancels. Those disagreements land in `crm_conflict` instead.
-- ---------------------------------------------------------------------

-- CRM status code. 1 New, 2 Pending, 3 Won, 5 Closed, 7 Paid, 40 Canceled.
-- Match on the CODE, never the label: the CRM spells it "Canceled" with one
-- L while this app uses "cancelled" with two.
alter table bookings add column if not exists crm_status_code   int;

-- The CRM's own label, stored verbatim for display and for spotting new
-- status values the sync has not been taught about.
alter table bookings add column if not exists crm_status         text;

-- The CRM's scheduled date for the job. Often differs from `report_date`,
-- which is the day the agent booked it, not the day the tech runs it.
alter table bookings add column if not exists crm_scheduled_date date;

-- Null means this booking has never been matched to a CRM job.
alter table bookings add column if not exists crm_synced_at      timestamptz;

-- Set when the CRM contradicts a decision someone already recorded. Null in
-- the normal case. Surfaced in Admin under the Conflicts filter.
alter table bookings add column if not exists crm_conflict       text;

-- The sync looks bookings up by reference; without this it is a seq scan per
-- batch. Not unique on purpose — whether job_ref should be globally unique or
-- unique per agent-and-date is an open decision, and guessing it here would
-- fail the sync on real data rather than surface the question.
create index if not exists bookings_job_ref_idx on bookings(job_ref);

-- Finds the Needs Review queue and the Conflicts list without a full scan.
create index if not exists bookings_crm_status_idx on bookings(crm_status_code);
