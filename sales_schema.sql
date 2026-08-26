-- =====================================================================
-- ADC Outbound Performance Board — Office Sales workspace
-- =====================================================================
-- Generated from the live Supabase project (public schema) on 2026-08-26.
-- Run in Supabase > SQL Editor, after schema.sql. Idempotent.
--
-- Creates the three tables the Office Sales workspace reads and writes:
-- the salesperson roster, their daily activity metrics, and the sales log.
--
-- SECURITY NOTE -------------------------------------------------------
-- `salespersons.pin` is stored in PLAINTEXT and, under the policy below,
-- the table is readable by anyone holding the publishable key — which ships
-- in every browser that loads the app. The app also checks PINs client-side
-- (`select name,active from salespersons where pin = ...`). Treat these PINs
-- as a soft UI separation between salespeople, not as authentication.
-- See README.md.
-- ---------------------------------------------------------------------

create table if not exists salespersons(
  id         uuid primary key default gen_random_uuid(),
  name       text not null unique,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  pin        text
);

-- Added in a later version; this line brings older databases up to date.
alter table salespersons add column if not exists pin text;

-- Unique so two salespeople can't share a PIN (the login lookup takes the
-- first match, which would otherwise be ambiguous).
create unique index if not exists salespersons_pin_idx on salespersons(pin);

create table if not exists sales_metrics(
  date                 date not null,
  salesperson          text not null,
  total_potentials     int,
  promising_potentials int,
  reach_attempts       int,
  customers_reached    int,
  cancellations        int,
  estimates_amount     numeric(12,2),
  updated_at           timestamptz not null default now(),
  primary key(date, salesperson)
);

create index if not exists sales_metrics_date_idx on sales_metrics(date);

create table if not exists sales(
  id           uuid primary key default gen_random_uuid(),
  date         date not null,
  salesperson  text not null,
  crm_ref      text not null,
  amount       numeric(12,2) not null,
  notes        text,
  submitted_at timestamptz not null default now()
);

create index if not exists sales_date_idx   on sales(date);
create index if not exists sales_person_idx on sales(salesperson);

-- `sales.salesperson` and `sales_metrics.salesperson` hold the name as text
-- rather than a foreign key to salespersons(id). Renaming a salesperson in
-- the app therefore rewrites those columns in place; see renameSalesperson()
-- in index.html.

alter table salespersons  enable row level security;
alter table sales_metrics enable row level security;
alter table sales         enable row level security;

drop policy if exists anon_all on salespersons;
create policy anon_all on salespersons for all using(true) with check(true);
drop policy if exists anon_all on sales_metrics;
create policy anon_all on sales_metrics for all using(true) with check(true);
drop policy if exists anon_all on sales;
create policy anon_all on sales for all using(true) with check(true);
