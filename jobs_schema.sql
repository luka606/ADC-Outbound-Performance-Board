-- =====================================================================
-- ADC Outbound Performance Board — Job Assignment workspace
-- =====================================================================
-- Generated from the live Supabase project (public schema) on 2026-08-26.
-- Run in Supabase > SQL Editor, after schema.sql. Idempotent.
--
-- Creates the technician roster and the per-day job counts behind the
-- Job Assignment workspace.
--
-- SECURITY NOTE -------------------------------------------------------
-- The policies below grant unrestricted read/write/delete to the anonymous
-- (publishable) key. This reproduces the live configuration. See README.md.
-- ---------------------------------------------------------------------

create table if not exists technicians(
  id           uuid primary key default gen_random_uuid(),
  name         text not null unique,
  active       boolean not null default true,
  default_type text check(default_type in ('ADC','DVC')),
  created_at   timestamptz not null default now()
);

create table if not exists job_assignments(
  id         uuid primary key default gen_random_uuid(),
  date       date not null,
  technician text not null,
  job_type   text not null check(job_type in ('ADC','DVC')),
  jobs       int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  -- The app upserts on this key, one row per technician per type per day.
  unique(date, technician, job_type)
);

create index if not exists job_assign_date_idx on job_assignments(date);
create index if not exists job_assign_tech_idx on job_assignments(technician);

-- `job_assignments.technician` holds the name as text rather than a foreign
-- key to technicians(id). Renaming a technician in the app rewrites this
-- column in place; see renameTech() in index.html.

alter table technicians     enable row level security;
alter table job_assignments enable row level security;

drop policy if exists anon_all on technicians;
create policy anon_all on technicians for all using(true) with check(true);
drop policy if exists anon_all on job_assignments;
create policy anon_all on job_assignments for all using(true) with check(true);
