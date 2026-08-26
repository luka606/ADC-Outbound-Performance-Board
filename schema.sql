-- =====================================================================
-- ADC Outbound Performance Board — core schema (Outbound workspace)
-- =====================================================================
-- Generated from the live Supabase project (public schema) on 2026-08-26.
-- Run in Supabase > SQL Editor. Every statement is idempotent, so this is
-- safe to re-run against an existing database.
--
-- This file covers the Outbound workspace only. The other workspaces each
-- have their own file, and none of them overlap:
--
--   schema.sql         agents, daily_reports, bookings, app_settings,
--                      weekly_history, admin_credentials   <- this file
--   sales_schema.sql   Office Sales workspace
--   jobs_schema.sql    Job Assignment workspace
--   adc_db_schema.sql  customer contact list
--
-- SECURITY NOTE -------------------------------------------------------
-- The policies at the bottom of this file grant unrestricted read/write/
-- delete to the anonymous (publishable) key, which ships in every agent's
-- browser. This reproduces the live configuration; it is not a
-- recommendation. See README.md.
-- ---------------------------------------------------------------------


-- =====================================================================
-- Outbound agents and their daily numbers
-- =====================================================================

create table if not exists agents(
  id                   uuid primary key default gen_random_uuid(),
  name                 text not null unique,
  active               boolean not null default true,
  target_bookings      int not null default 5,
  target_crossbookings int not null default 3,
  sort_order           int not null default 0,
  created_at           timestamptz not null default now()
);

create table if not exists daily_reports(
  id                  uuid primary key default gen_random_uuid(),
  agent_id            uuid not null references agents(id) on delete cascade,
  report_date         date not null,
  total_calls         int not null default 0,
  reached_contacts    int not null default 0,
  no_answer           int not null default 0,
  not_interested      int not null default 0,
  follow_up_needed    int not null default 0,
  note                text,
  submitted_at        timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  booked_appointments int not null default 0,
  cross_bookings      int not null default 0,
  unique(agent_id, report_date)
);

-- Migrations for databases created before these columns existed. They sit
-- last in the table above to match the live column order.
alter table daily_reports add column if not exists booked_appointments int not null default 0;
alter table daily_reports add column if not exists cross_bookings      int not null default 0;

create table if not exists bookings(
  id          uuid primary key default gen_random_uuid(),
  agent_id    uuid not null references agents(id) on delete cascade,
  report_date date not null,
  kind        text not null check(kind in ('booking','crossbooking')),
  job_ref     text not null,
  sale_amount numeric(12,2),
  status      text not null default 'pending'
              check(status in ('pending','ran_not_sold','sold','cancelled')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create index if not exists bookings_agent_idx on bookings(agent_id);
create index if not exists bookings_date_idx  on bookings(report_date);


-- =====================================================================
-- Settings and archived weekly rollups
-- =====================================================================

-- Holds `admin_pin` (sha256 of the admin PIN) and `admin_passkeys`
-- (JSON array of registered WebAuthn credential IDs).
create table if not exists app_settings(
  key        text primary key,
  value      text,
  updated_at timestamptz not null default now()
);

create table if not exists weekly_history(
  id                  uuid primary key default gen_random_uuid(),
  scope               text not null default 'Team',
  week_no             int,
  week_start          date,
  week_end            date,
  number_of_agents    int,
  total_calls         int,
  reached_contacts    int,
  no_answer           int,
  not_interested      int,
  follow_up_needed    int,
  booked_appointments int,
  cross_bookings      int,
  sold_jobs           int,
  revenue             numeric(12,2),
  revenue_cross       numeric(12,2),
  runs                int,
  cancellations       int,
  jobs_scheduled      int
);


-- =====================================================================
-- Unused — present in the live database, never queried by the app
-- =====================================================================
-- `admin_credentials` holds one WebAuthn credential ID, but the application
-- registers passkeys into app_settings('admin_passkeys') and never reads
-- this table. Reproduced here for fidelity with production. A fresh
-- deployment does not need it; it is a candidate for removal.

create table if not exists admin_credentials(
  id            uuid primary key default gen_random_uuid(),
  credential_id text not null unique,
  label         text,
  created_at    timestamptz not null default now()
);


-- =====================================================================
-- Row Level Security
-- =====================================================================
-- Reproduces the live configuration: RLS on, one permissive ALL policy per
-- table granting unrestricted access to every role, including `anon`.

alter table agents            enable row level security;
alter table daily_reports     enable row level security;
alter table bookings          enable row level security;
alter table app_settings      enable row level security;
alter table weekly_history    enable row level security;
alter table admin_credentials enable row level security;

drop policy if exists anon_all on agents;
create policy anon_all on agents for all using(true) with check(true);
drop policy if exists anon_all on daily_reports;
create policy anon_all on daily_reports for all using(true) with check(true);
drop policy if exists anon_all on bookings;
create policy anon_all on bookings for all using(true) with check(true);
drop policy if exists anon_all on app_settings;
create policy anon_all on app_settings for all using(true) with check(true);
drop policy if exists anon_all on weekly_history;
create policy anon_all on weekly_history for all using(true) with check(true);
drop policy if exists anon_all on admin_credentials;
create policy anon_all on admin_credentials for all using(true) with check(true);


-- =====================================================================
-- Seed agents
-- =====================================================================

insert into agents(name, sort_order) values
  ('Shiena',1),('Levi',2),('Reagan',3),('Jane',4),('Felicia',5),('Toni',6)
  on conflict(name) do nothing;


-- =====================================================================
-- First-run admin PIN
-- =====================================================================
-- No PIN is seeded here on purpose: a hash committed to a public repo is a
-- 10,000-entry search space for a 4-digit PIN and reverses in milliseconds.
--
-- Leave this out and the app prompts you to choose a PIN the first time you
-- open the Admin view, then stores its sha256 itself. To seed one anyway,
-- compute the hash locally and insert it — do not commit the result:
--
--   printf '<your-pin>' | shasum -a 256
--
--   insert into app_settings(key, value)
--   values ('admin_pin', '<hash>')
--   on conflict(key) do nothing;
