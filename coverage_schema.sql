-- =====================================================================
-- ADC Outbound Performance Board — Coverage log (Job Assignment workspace)
-- =====================================================================
-- Written 2026-09-16. Run in Supabase > SQL Editor, AFTER jobs_schema.sql.
-- Idempotent — safe to re-run. Carries its own BEGIN/COMMIT.
--
-- WHY
-- An ADC job that cannot go to its usual technician is not rejected until
-- every APPROVED, ACTIVE technician who could take it has been offered it —
-- and the whole sequence is on record. Until now the board stored how many
-- jobs each technician had per day, not which job went where or who was
-- asked, so "we had nobody" could be said but never shown. This is Rock
-- "ADC Ironclad Coverage", milestone 1, and SOP ADC-DSR-001.
--
-- WHAT IT ADDS
--   technicians.approved  + areas, job_types, availability, contact_method
--       `approved` is the frozen approved-technician list and is admin-set.
--       The existing `active` flag keeps its meaning: "in the assignment
--       dropdown". A technician counts as a coverage option only when BOTH
--       approved and active.
--   coverage_log          one row per offer or status change, per job. A
--       job's current state is its latest row; earlier rows are history.
--   coverage_days         one row per workday: owner, backup, review times,
--       the end-of-day checklist, and when the day was closed.
--
-- THE GUARDRAILS LIVE HERE, NOT ONLY IN THE PAGE
--   * outcome = 'rejected'       requires at least one technician offered
--   * outcome = 'confirmed_lost' requires a lost_reason
--   * outcome = 'reassigned'     requires a final_assignee
--   * every name in offered_names must be an approved AND active
--     technician at the moment the row is written (trigger)
--
-- SECURITY NOTE
-- Policies address `anon` per verb, in the shape of sql/rls_lockdown.sql,
-- so they survive that lockdown unchanged. As everywhere in this project,
-- `anon` is the one shared principal — see rls_lockdown.sql, "WHY THIS FILE
-- CANNOT FULLY FIX THE PROBLEM". No DELETE is granted on either table: the
-- log is evidence. Fix a row by editing it or by adding a correcting row.
-- ---------------------------------------------------------------------

begin;

-- ---------------------------------------------------------------------
-- 1. The approved-technician list, on the existing roster
-- ---------------------------------------------------------------------
alter table public.technicians add column if not exists approved       boolean not null default false;
alter table public.technicians add column if not exists areas          text;
alter table public.technicians add column if not exists job_types      text;
alter table public.technicians add column if not exists availability   text;
alter table public.technicians add column if not exists contact_method text;
alter table public.technicians add column if not exists approved_at    timestamptz;
alter table public.technicians add column if not exists approved_by    text;
alter table public.technicians add column if not exists approval_note  text;

-- Checks are added by name so a re-run does not fail on an existing column.
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'technicians_job_types_chk') then
    alter table public.technicians add constraint technicians_job_types_chk
      check (job_types is null or job_types in ('estimate','install','both'));
  end if;
  if not exists (select 1 from pg_constraint where conname = 'technicians_contact_method_chk') then
    alter table public.technicians add constraint technicians_contact_method_chk
      check (contact_method is null or contact_method in ('call','text','crm'));
  end if;
end $$;

comment on column public.technicians.approved is
  'The frozen approved-technician list (Rock ADC Ironclad Coverage, m1). Admin-set in the '
  'Technicians tab. Counts as a coverage option only together with active = true. '
  'Newly added technicians start false.';

-- Seed areas from the area token the board names already carry
-- ("3 LA Sagi" -> LA). Best-known, not verified; Rock m3 refines to ZIP/city.
-- Only fills rows that have no area yet, so a hand-entered value is never overwritten.
update public.technicians
   set areas = (regexp_match(name, '^\d+\s+(LA|OC|SD|SF|Miami|Ventura)\s'))[1]
 where areas is null
   and name ~ '^\d+\s+(LA|OC|SD|SF|Miami|Ventura)\s';

-- ---------------------------------------------------------------------
-- 2. The log — one row per offer or status change
-- ---------------------------------------------------------------------
create table if not exists public.coverage_log(
  id                uuid primary key default gen_random_uuid(),
  log_date          date not null,                 -- the PT workday the row belongs to
  time_local        text,                          -- HH:MM as entered, PT
  lead_ref          text not null,                 -- lead / job ID (upper-cased by trigger)
  area              text,
  job_date          date,
  value             numeric(12,2),
  original_assignee text,
  issue             text,
  offered_names     text[] not null default '{}',  -- technicians offered, in order
  offered_method    text,                          -- call | text | crm
  responses         text,
  final_assignee    text,
  outcome           text not null,
  lost_reason       text,
  next_action       text,
  owner             text,
  created_by        text,                          -- self-asserted (agent picker / session); not an audit trail
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  constraint coverage_log_outcome_chk check (outcome in ('uncovered','reassigned','rejected','potentially_lost','confirmed_lost')),
  constraint coverage_log_rejected_needs_offer   check (outcome <> 'rejected'       or cardinality(offered_names) >= 1),
  constraint coverage_log_lost_needs_reason      check (outcome <> 'confirmed_lost' or nullif(btrim(coalesce(lost_reason,'')),'')    is not null),
  constraint coverage_log_reassigned_needs_final check (outcome <> 'reassigned'     or nullif(btrim(coalesce(final_assignee,'')),'') is not null)
);
create index if not exists coverage_log_date_idx on public.coverage_log(log_date);
create index if not exists coverage_log_lead_idx on public.coverage_log(lead_ref);

comment on table public.coverage_log is
  'One row per offer or status change for an ADC job that could not follow normal assignment. '
  'A job''s current state is its latest row; earlier rows are preserved history. Never deleted — '
  'it is the evidence behind the Rock completion gate. See SOP ADC-DSR-001.';

-- Offered names must be approved AND active when the row is written. A later
-- revocation does not rewrite history: the check runs only on that row's own
-- insert or update.
create or replace function public.coverage_log_validate()
returns trigger
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $$
declare
  bad text;
begin
  new.updated_at := now();
  new.lead_ref   := upper(btrim(coalesce(new.lead_ref,'')));
  if new.lead_ref = '' then
    raise exception 'Lead / job ID is required';
  end if;
  select n into bad
    from unnest(new.offered_names) as n
   where not exists (select 1 from public.technicians t
                      where t.name = n and t.approved and t.active)
   limit 1;
  if bad is not null then
    raise exception 'Not an approved, active technician: %', bad;
  end if;
  return new;
end $$;

drop trigger if exists coverage_log_validate_t on public.coverage_log;
create trigger coverage_log_validate_t
  before insert or update on public.coverage_log
  for each row execute function public.coverage_log_validate();

-- ---------------------------------------------------------------------
-- 3. The day — owner, backup, end-of-day review
-- ---------------------------------------------------------------------
create table if not exists public.coverage_days(
  log_date     date primary key,
  owner        text,
  backup       text,
  review_times text not null default '10:00, 14:00, 17:00',
  eod          jsonb not null default '{}'::jsonb,   -- the seven end-of-day checks, keyed by the page
  eod_note     text,
  closed_at    timestamptz,
  closed_by    text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

comment on table public.coverage_days is
  'One row per PT workday of the coverage log: daily owner, backup, review times, the end-of-day '
  'checklist and when the day was closed. closed_at is what a compliance check reads.';

-- ---------------------------------------------------------------------
-- 4. Policies — `anon` per verb, no DELETE, nothing for `authenticated`
-- ---------------------------------------------------------------------
alter table public.coverage_log  enable row level security;
alter table public.coverage_days enable row level security;

drop policy if exists coverage_log_anon_read   on public.coverage_log;
drop policy if exists coverage_log_anon_insert on public.coverage_log;
drop policy if exists coverage_log_anon_update on public.coverage_log;
create policy coverage_log_anon_read   on public.coverage_log for select to anon using (true);
create policy coverage_log_anon_insert on public.coverage_log for insert to anon with check (true);
create policy coverage_log_anon_update on public.coverage_log for update to anon using (true) with check (true);

drop policy if exists coverage_days_anon_read   on public.coverage_days;
drop policy if exists coverage_days_anon_insert on public.coverage_days;
drop policy if exists coverage_days_anon_update on public.coverage_days;
create policy coverage_days_anon_read   on public.coverage_days for select to anon using (true);
create policy coverage_days_anon_insert on public.coverage_days for insert to anon with check (true);
create policy coverage_days_anon_update on public.coverage_days for update to anon using (true) with check (true);

revoke all on public.coverage_log, public.coverage_days from authenticated;
revoke delete, truncate, references, trigger on public.coverage_log, public.coverage_days from anon, authenticated;
grant select, insert, update on public.coverage_log, public.coverage_days to anon;

commit;

-- =====================================================================
-- VERIFY (run after committing)
-- =====================================================================
-- 1. Both tables exist and the roster has the new columns:
--      select column_name from information_schema.columns
--       where table_name = 'technicians' and column_name in ('approved','areas','job_types','availability','contact_method');
--    Expect 5 rows.
-- 2. The guardrail refuses a bare rejection:
--      insert into coverage_log(log_date, lead_ref, outcome) values (current_date, 'TEST01', 'rejected');
--    Expect: violates check constraint "coverage_log_rejected_needs_offer".
-- 3. The trigger refuses an unapproved name:
--      insert into coverage_log(log_date, lead_ref, outcome, offered_names)
--      values (current_date, 'TEST01', 'uncovered', array['nobody']);
--    Expect: Not an approved, active technician: nobody
-- 4. Nothing in this file is reachable to `authenticated`, and `anon` has no DELETE:
--      select grantee, privilege_type from information_schema.role_table_grants
--       where table_name in ('coverage_log','coverage_days') order by 1,2;
