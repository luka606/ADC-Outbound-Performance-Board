-- =====================================================================================================
-- ADC Outbound Performance Board · M4 TEAM QUALIFICATION SCORECARD · database
-- Rock "ADC Ironclad Coverage", milestone 4 (due 2026-10-02). Brief: ADL_M4_Team_Qualification_Scorecard_System_Brief.md (2026-09-23).
--
-- One balanced qualification standard for every technician-sales team — incumbent, candidate, and a rebuilt team
-- led by the former technician. Seven weighted categories, non-negotiable gates, four official outcomes
-- (pass / coaching / probation / disqualify) that only the manager records, on an immutable evidence snapshot,
-- tied to the metric-configuration version in force.
--
-- IDENTITY. Same sign-in and roles as the M2 Bridge (bridge_roles; manager = Luka, dispatcher = Vasyl). The page
-- qualification.html shares the Bridge session. Nothing here is readable by the anon key.
-- STATUS of every business value is the brief's own: confirmed | proposed | unresolved. Unresolved = null and
-- blocks official scoring where it matters (the revenue-efficiency baseline above all). Nothing is guessed.
-- MONEY is integer cents. TIMESTAMPS are timestamptz; the page renders America/Los_Angeles (proposed, §18.7).
-- CALCULATED TOTALS are never stored as editable columns: the page computes from source rows; an official
-- decision freezes a snapshot row that no client role can update or delete.
--
-- Idempotent. Requires bridge_schema.sql (is_bridge_member, bridge_role, bridge_stamp) — applied 2026-09-18.
-- =====================================================================================================
begin;

create or replace function public.qual_is_manager() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select coalesce(public.bridge_role(),'') = 'manager';
$$;

-- Append-only audit of sensitive actions (brief §11). Written by triggers; readable by members; never edited.
create table if not exists public.qual_audit(
  id          bigserial primary key,
  at          timestamptz not null default now(),
  actor_email text,
  table_name  text not null,
  row_id      text,
  action      text not null,
  detail      jsonb
);
alter table public.qual_audit enable row level security;
drop policy if exists qual_audit_read on public.qual_audit;
create policy qual_audit_read on public.qual_audit for select to authenticated using (is_bridge_member());

create or replace function public.qual_audit_row() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare rid text; j jsonb;
begin
  j := case when tg_op = 'DELETE' then to_jsonb(old) else to_jsonb(new) end;
  rid := coalesce(j->>'id', j->>'version', null);
  insert into public.qual_audit(actor_email, table_name, row_id, action, detail)
  values (auth.email(), tg_table_name, rid, tg_op,
          case when tg_op = 'UPDATE' then jsonb_build_object('old', to_jsonb(old), 'new', to_jsonb(new)) else j end);
  return null;
end $$;

-- -----------------------------------------------------------------------------------------------------
-- 1 · Metric configuration versions — weights, bands, gates, evidence minimums, windows, revenue rules.
--     Immutable once used in an official decision. Exactly one may be active. Weights must total 100.
-- -----------------------------------------------------------------------------------------------------
create table if not exists public.qual_metric_versions(
  id              uuid primary key default gen_random_uuid(),
  version         integer not null unique,
  label           text not null,
  status          text not null default 'draft' check (status in ('draft','active','superseded')),
  effective_from  date,
  categories      jsonb not null,     -- [{key,label,weight_pct,direction:'higher'|'lower',formula,numerator,denominator,target,bands:{p100,p70,p40},status}]
  gates           jsonb not null default '[]',
  evidence        jsonb not null,     -- {window_days, min_qualified_estimates, min_completed_jobs, supervised_jobs, decision_age_days:{value,status}}
  windows         jsonb not null,     -- {quality_observation_days:{value,status}, on_time_grace_minutes:{value,status}, timezone:{value,status}, week_start:{value,status}}
  revenue         jsonb not null,     -- {baseline_cents:{value,status}, credit_point:{value,status}, segmented_by:{value,status}}
  outcome_rules   jsonb not null,     -- {pass_min, coaching_min, probation_min, probation_days:{value,status}, coaching_repeat_to_probation, membership_change_restarts:{value,status}}
  critical_events jsonb not null default '[]',
  margin_rules    jsonb not null,     -- {installation:{target_pct,floor_pct}, cleaning:{floor_pct}}  confirmed
  change_note     text,
  approved_by     text,
  approved_at     timestamptz,
  activated_at    timestamptz,
  used_in_decision boolean not null default false,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text
);
comment on table public.qual_metric_versions is 'Versioned scorecard configuration (brief §4–§7, §10.5). Weights must total exactly 100; bands strictly ordered; only the manager activates; a version used in an official decision can only be superseded, never edited.';
alter table public.qual_metric_versions enable row level security;
drop policy if exists qmv_read  on public.qual_metric_versions;
drop policy if exists qmv_write on public.qual_metric_versions;
create policy qmv_read  on public.qual_metric_versions for select to authenticated using (is_bridge_member());
create policy qmv_write on public.qual_metric_versions for all    to authenticated using (qual_is_manager()) with check (qual_is_manager());

create or replace function public.qual_version_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare c jsonb; total numeric := 0; dirn text; p100 numeric; p70 numeric; p40 numeric; n int := 0; k text; seen text[] := '{}';
begin
  if tg_op = 'UPDATE' then
    if old.used_in_decision and not (new.status = 'superseded' and to_jsonb(new) - 'status' - 'updated_at' - 'updated_by' - 'used_in_decision' = to_jsonb(old) - 'status' - 'updated_at' - 'updated_by' - 'used_in_decision') then
      raise exception 'Version % has been used in an official decision and is immutable. Create a new version; this one can only be superseded (brief §9, §16.18).', old.version;
    end if;
    if old.status = 'superseded' and new.status <> 'superseded' then
      raise exception 'A superseded version is not reactivated. Create a new version.';
    end if;
  end if;
  if jsonb_typeof(new.categories) <> 'array' or jsonb_array_length(new.categories) = 0 then
    raise exception 'categories must be a non-empty array';
  end if;
  for c in select * from jsonb_array_elements(new.categories) loop
    n := n + 1; k := c->>'key';
    if k is null or k = '' then raise exception 'Category % has no key', n; end if;
    if k = any(seen) then raise exception 'Duplicate category key %', k; end if;
    seen := seen || k;
    if (c->>'weight_pct') is null then raise exception 'Category % has no weight_pct', k; end if;
    total := total + (c->>'weight_pct')::numeric;
    dirn := coalesce(c->>'direction','higher');
    if dirn not in ('higher','lower') then raise exception 'Category %: direction must be higher or lower', k; end if;
    p100 := (c->'bands'->>'p100')::numeric; p70 := (c->'bands'->>'p70')::numeric; p40 := (c->'bands'->>'p40')::numeric;
    if p100 is null or p70 is null or p40 is null then raise exception 'Category %: bands need p100, p70 and p40 thresholds', k; end if;
    if dirn = 'higher' and not (p100 > p70 and p70 > p40) then
      raise exception 'Category %: bands overlap or leave a gap — for a higher-is-better metric p100 > p70 > p40 is required (got %, %, %)', k, p100, p70, p40;
    end if;
    if dirn = 'lower' and not (p100 < p70 and p70 < p40) then
      raise exception 'Category %: bands overlap or leave a gap — for a lower-is-better metric p100 < p70 < p40 is required (got %, %, %)', k, p100, p70, p40;
    end if;
  end loop;
  if total <> 100 then
    raise exception 'Category weights total % — they must total exactly 100 (brief §4.1, §16.2). Nothing is normalised silently.', total;
  end if;
  if new.status = 'active' and (tg_op = 'INSERT' or old.status <> 'active') then
    if not qual_is_manager() then raise exception 'Only the manager activates a metric version (brief §11).'; end if;
    if coalesce(btrim(new.change_note),'') = '' then raise exception 'Activation needs a change note (brief §10.5).'; end if;
    new.approved_by := auth.email(); new.approved_at := now(); new.activated_at := now();
    new.effective_from := coalesce(new.effective_from, (now() at time zone 'America/Los_Angeles')::date);
    update public.qual_metric_versions set status = 'superseded' where status = 'active' and id <> new.id;
  end if;
  return new;
end $$;
drop trigger if exists qmv_guard_t on public.qual_metric_versions;
create trigger qmv_guard_t before insert or update on public.qual_metric_versions for each row execute function public.qual_version_guard();
drop trigger if exists qmv_stamp_t on public.qual_metric_versions;
create trigger qmv_stamp_t before insert or update on public.qual_metric_versions for each row execute function public.bridge_stamp();
drop trigger if exists qmv_audit_t on public.qual_metric_versions;
create trigger qmv_audit_t after insert or update or delete on public.qual_metric_versions for each row execute function public.qual_audit_row();

-- -----------------------------------------------------------------------------------------------------
-- 2 · Teams, members, availability
-- -----------------------------------------------------------------------------------------------------
create table if not exists public.qual_teams(
  id            uuid primary key default gen_random_uuid(),
  seq           bigint generated by default as identity,           -- stable human code T-<seq>; names may change
  name          text not null,
  status        text not null default 'prospective' check (status in ('prospective','provisional','active','inactive','disqualified')),
  team_type     text not null default 'candidate' check (team_type in ('incumbent','candidate','rebuilt')),
  leader_name   text,
  former_technician boolean not null default false,                -- rebuilt team led by the removed technician: same rules, flagged for visibility
  territories   text[] not null default '{}',
  services      text[] not null default '{}',
  active_from   date,
  active_to     date,
  entry_review  jsonb not null default '{}',                       -- {identity,members,territories,services,equipment,documents,availability,payment_compliance,approvals} → {done,note}
  entry_review_complete_at timestamptz,
  entry_reviewed_by text,
  notes         text,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text
);
comment on table public.qual_teams is 'One row per team ever considered (brief §9). id is the stable identity; names change without breaking history. Entry-review completion is a manager act.';
alter table public.qual_teams enable row level security;
drop policy if exists qt_rw on public.qual_teams;
create policy qt_rw on public.qual_teams for all to authenticated using (is_bridge_member()) with check (is_bridge_member());
create or replace function public.qual_team_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if new.entry_review_complete_at is not null and (tg_op = 'INSERT' or old.entry_review_complete_at is null) then
    if not qual_is_manager() then raise exception 'Only the manager completes an entry review (brief §8.A, §11).'; end if;
    new.entry_reviewed_by := auth.email();
  end if;
  if tg_op = 'UPDATE' and new.status in ('active','disqualified') and old.status <> new.status and pg_trigger_depth() = 0 then
    raise exception 'A team becomes % only through an official decision (brief §7). Record the decision; the status follows.', new.status;
  end if;
  return new;
end $$;
drop trigger if exists qt_guard_t on public.qual_teams;
create trigger qt_guard_t before insert or update on public.qual_teams for each row execute function public.qual_team_guard();
drop trigger if exists qt_stamp_t on public.qual_teams;
create trigger qt_stamp_t before insert or update on public.qual_teams for each row execute function public.bridge_stamp();
drop trigger if exists qt_audit_t on public.qual_teams;
create trigger qt_audit_t after insert or update or delete on public.qual_teams for each row execute function public.qual_audit_row();

create table if not exists public.qual_team_members(
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references public.qual_teams(id) on delete cascade,
  technician_id uuid references public.technicians(id),
  person_name   text not null,
  role          text not null default 'technician' check (role in ('leader','technician','installer','helper','salesperson')),
  active_from   date not null default current_date,
  active_to     date,
  credentials   jsonb not null default '[]',                       -- [{name,status:'valid'|'expired'|'missing',expires}]
  approval_status text not null default 'pending' check (approval_status in ('pending','approved','rejected')),
  approved_by   text, approved_at timestamptz,
  note          text,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text
);
alter table public.qual_team_members enable row level security;
drop policy if exists qtm_rw on public.qual_team_members;
create policy qtm_rw on public.qual_team_members for all to authenticated using (is_bridge_member()) with check (is_bridge_member());
create or replace function public.qual_member_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if new.approval_status = 'approved' and (tg_op = 'INSERT' or old.approval_status <> 'approved') then
    if not qual_is_manager() then raise exception 'Only the manager approves a team member (brief §11).'; end if;
    new.approved_by := auth.email(); new.approved_at := now();
  end if;
  if new.approval_status <> 'approved' then new.approved_by := null; new.approved_at := null; end if;
  return new;
end $$;
drop trigger if exists qtm_guard_t on public.qual_team_members;
create trigger qtm_guard_t before insert or update on public.qual_team_members for each row execute function public.qual_member_guard();
drop trigger if exists qtm_stamp_t on public.qual_team_members;
create trigger qtm_stamp_t before insert or update on public.qual_team_members for each row execute function public.bridge_stamp();
drop trigger if exists qtm_audit_t on public.qual_team_members;
create trigger qtm_audit_t after insert or update or delete on public.qual_team_members for each row execute function public.qual_audit_row();

-- Availability is declared BEFORE offers. A row is locked the moment a coverage event references its date;
-- after that it cannot change — a correction is a new row with a reason, approved by the manager, and it never
-- alters the eligibility already snapshotted on existing coverage events (brief §4.2 coverage, §13, §16.14).
create table if not exists public.qual_availability(
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references public.qual_teams(id) on delete cascade,
  avail_date    date not null,
  territory     text,                                             -- null = all the team's territories
  service       text,                                             -- null = all the team's services
  available     boolean not null default true,
  windows       text,
  submitted_at  timestamptz not null default now(),
  retroactive   boolean not null default false,                   -- set when declared after the date it describes
  locked_at     timestamptz,
  supersedes    uuid references public.qual_availability(id),
  change_reason text,
  approved_by   text, approved_at timestamptz,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text
);
alter table public.qual_availability enable row level security;
drop policy if exists qav_rw on public.qual_availability;
create policy qav_rw on public.qual_availability for all to authenticated using (is_bridge_member()) with check (is_bridge_member());
create or replace function public.qual_availability_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare offers int;
begin
  if tg_op = 'UPDATE' then
    if old.locked_at is not null and pg_trigger_depth() = 0 then
      raise exception 'This availability row is locked — an offer was already made against it. Record a correction as a new row with a reason (brief §13).';
    end if;
    if new.avail_date <> old.avail_date or new.team_id <> old.team_id then raise exception 'Move availability by adding a new row, not by editing the date.'; end if;
  end if;
  if tg_op = 'INSERT' then
    new.submitted_at := now();
    new.retroactive := new.avail_date < (now() at time zone 'America/Los_Angeles')::date;
    select count(*) into offers from public.qual_coverage_events e where e.team_id = new.team_id and e.job_date = new.avail_date;
    if offers > 0 or new.supersedes is not null then
      if coalesce(btrim(new.change_reason),'') = '' then raise exception 'Offers already exist for % — a later availability change needs a reason and the manager''s approval. Eligibility already recorded on those offers does not change.', new.avail_date; end if;
      if not qual_is_manager() then raise exception 'Only the manager approves an availability change after offers were made (brief §11).'; end if;
      new.approved_by := auth.email(); new.approved_at := now();
    end if;
  end if;
  return new;
end $$;
drop trigger if exists qav_guard_t on public.qual_availability;
create trigger qav_guard_t before insert or update on public.qual_availability for each row execute function public.qual_availability_guard();
drop trigger if exists qav_stamp_t on public.qual_availability;
create trigger qav_stamp_t before insert or update on public.qual_availability for each row execute function public.bridge_stamp();
drop trigger if exists qav_audit_t on public.qual_availability;
create trigger qav_audit_t after insert or update or delete on public.qual_availability for each row execute function public.qual_audit_row();

-- -----------------------------------------------------------------------------------------------------
-- 3 · Leads (sales + revenue cohort), estimate versions, appointments, jobs, reschedules
-- -----------------------------------------------------------------------------------------------------
create table if not exists public.qual_leads(
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references public.qual_teams(id) on delete cascade,
  lead_ref      text not null,
  source        text,
  bridge_opportunity_id uuid unique references public.bridge_opportunities(id),
  territory     text,
  service       text not null default 'cleaning' check (service in ('installation','cleaning','mixed','other')),
  assigned_at   timestamptz not null default now(),               -- assignment cohort: the period a lead belongs to, forever
  qualified     boolean not null default true,
  qualification_evidence text,
  status        text not null default 'pending' check (status in ('pending','won','declined','team_failed')),
  decision_at   timestamptz,
  failure_reason text,
  sold_revenue_cents bigint,
  collected_revenue_cents bigint,
  notes         text,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text,
  constraint ql_won_needs_revenue    check (status <> 'won' or sold_revenue_cents is not null),
  constraint ql_decided_needs_time   check (status = 'pending' or decision_at is not null),
  constraint ql_failed_needs_reason  check (status <> 'team_failed' or coalesce(btrim(failure_reason),'') <> '')
);
comment on table public.qual_leads is 'One row per qualified opportunity assigned to a team (brief §4.2). Estimate revisions live in qual_lead_estimates and never add denominator entries. assigned_at is the cohort and never moves.';
alter table public.qual_leads enable row level security;
drop policy if exists ql_rw on public.qual_leads;
create policy ql_rw on public.qual_leads for all to authenticated using (is_bridge_member()) with check (is_bridge_member());
create or replace function public.qual_lead_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if tg_op = 'UPDATE' and new.assigned_at <> old.assigned_at then raise exception 'assigned_at is the assignment cohort and never moves (brief §4.2).'; end if;
  if new.status <> 'pending' and new.decision_at is null then new.decision_at := now(); end if;
  return new;
end $$;
drop trigger if exists ql_guard_t on public.qual_leads;
create trigger ql_guard_t before insert or update on public.qual_leads for each row execute function public.qual_lead_guard();
drop trigger if exists ql_stamp_t on public.qual_leads;
create trigger ql_stamp_t before insert or update on public.qual_leads for each row execute function public.bridge_stamp();

create table if not exists public.qual_lead_estimates(
  id            uuid primary key default gen_random_uuid(),
  lead_id       uuid not null references public.qual_leads(id) on delete cascade,
  version       integer not null,
  price_cents   bigint,
  presented_at  timestamptz not null default now(),
  outcome       text not null default 'pending' check (outcome in ('pending','accepted','declined')),
  note          text,
  created_at timestamptz not null default now(), created_by text,
  unique (lead_id, version)
);
alter table public.qual_lead_estimates enable row level security;
drop policy if exists qle_read on public.qual_lead_estimates;
drop policy if exists qle_ins  on public.qual_lead_estimates;
drop policy if exists qle_upd  on public.qual_lead_estimates;
create policy qle_read on public.qual_lead_estimates for select to authenticated using (is_bridge_member());
create policy qle_ins  on public.qual_lead_estimates for insert to authenticated with check (is_bridge_member());
create policy qle_upd  on public.qual_lead_estimates for update to authenticated using (is_bridge_member()) with check (is_bridge_member());
create or replace function public.qual_estimate_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if tg_op = 'UPDATE' and (new.price_cents <> old.price_cents or new.version <> old.version or new.lead_id <> old.lead_id or new.presented_at <> old.presented_at) then
    raise exception 'An estimate version is never edited — add the next version (brief §4.2). Only its outcome may change.';
  end if;
  return new;
end $$;
drop trigger if exists qle_guard_t on public.qual_lead_estimates;
create trigger qle_guard_t before update on public.qual_lead_estimates for each row execute function public.qual_estimate_guard();
drop trigger if exists qle_stamp_t on public.qual_lead_estimates;
create trigger qle_stamp_t before insert on public.qual_lead_estimates for each row execute function public.bridge_stamp();

create table if not exists public.qual_appointments(
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references public.qual_teams(id) on delete cascade,
  lead_id       uuid references public.qual_leads(id) on delete set null,
  job_id        uuid,
  scheduled_at  timestamptz not null,
  territory     text,
  service       text,
  arrival_at    timestamptz,
  contact_at    timestamptz,
  outcome       text not null default 'scheduled' check (outcome in ('scheduled','attended','late','no_show','customer_reschedule','company_cancel','force_majeure')),
  reason        text,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text,
  constraint qap_excl_needs_reason check (outcome not in ('customer_reschedule','company_cancel','force_majeure') or coalesce(btrim(reason),'') <> '')
);
comment on table public.qual_appointments is 'Attendance source (brief §4.2). customer_reschedule / company_cancel / force_majeure are the only documented exclusions and each needs a reason; a no-show without a reason is "unexplained".';
alter table public.qual_appointments enable row level security;
drop policy if exists qap_rw on public.qual_appointments;
create policy qap_rw on public.qual_appointments for all to authenticated using (is_bridge_member()) with check (is_bridge_member());
drop trigger if exists qap_stamp_t on public.qual_appointments;
create trigger qap_stamp_t before insert or update on public.qual_appointments for each row execute function public.bridge_stamp();

create table if not exists public.qual_jobs(
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references public.qual_teams(id) on delete cascade,
  lead_id       uuid references public.qual_leads(id) on delete set null,
  job_ref       text,
  service       text not null default 'cleaning' check (service in ('installation','cleaning','mixed','other')),
  service_mix   jsonb not null default '[]',                       -- [{service, revenue_cents, cost_cents}] for mixed jobs (per-service floors)
  sold_at       date,
  promised_date date not null,                                     -- the original promise: immutable
  current_promise_date date not null,                              -- moves only through qual_job_reschedules
  completed_at  timestamptz,
  completion_evidence text,
  revenue_cents bigint,
  costs         jsonb not null default '[]',                       -- [{category, amount_cents|null, status:'estimated'|'actual'|'unknown'}]
  margin_exception_ref text,                                       -- Sardor's authorised exception (Bridge approval id / reference); visible, never improves the score
  cancelled     boolean not null default false,
  cancel_reason text,
  notes         text,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text,
  constraint qj_cancel_needs_reason check (not cancelled or coalesce(btrim(cancel_reason),'') <> '')
);
comment on table public.qual_jobs is 'Completion, margin and quality source (brief §4.2, §4.3). promised_date never changes; reschedules are versioned events. Unknown costs stay unknown — the page shows no margin for them.';
alter table public.qual_jobs enable row level security;
drop policy if exists qj_rw on public.qual_jobs;
create policy qj_rw on public.qual_jobs for all to authenticated using (is_bridge_member()) with check (is_bridge_member());
create or replace function public.qual_job_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if tg_op = 'INSERT' then new.current_promise_date := new.promised_date; end if;
  if tg_op = 'UPDATE' then
    if new.promised_date <> old.promised_date then raise exception 'The original promise date is immutable — record a customer-approved reschedule instead (brief §4.2).'; end if;
    if new.current_promise_date <> old.current_promise_date and pg_trigger_depth() = 0 then raise exception 'The promise date moves only through a recorded reschedule (qual_job_reschedules).'; end if;
  end if;
  return new;
end $$;
drop trigger if exists qj_guard_t on public.qual_jobs;
create trigger qj_guard_t before insert or update on public.qual_jobs for each row execute function public.qual_job_guard();
drop trigger if exists qj_stamp_t on public.qual_jobs;
create trigger qj_stamp_t before insert or update on public.qual_jobs for each row execute function public.bridge_stamp();
do $$ begin
  if not exists (select 1 from pg_constraint where conname = 'qual_appointments_job_id_fkey') then
    alter table public.qual_appointments add constraint qual_appointments_job_id_fkey foreign key (job_id) references public.qual_jobs(id) on delete set null;
  end if;
end $$;

create table if not exists public.qual_job_reschedules(
  id          uuid primary key default gen_random_uuid(),
  job_id      uuid not null references public.qual_jobs(id) on delete cascade,
  from_date   date not null,
  to_date     date not null,
  reason      text not null,
  customer_approved boolean not null default true,
  created_at timestamptz not null default now(), created_by text
);
alter table public.qual_job_reschedules enable row level security;
drop policy if exists qjr_read on public.qual_job_reschedules;
drop policy if exists qjr_ins  on public.qual_job_reschedules;
create policy qjr_read on public.qual_job_reschedules for select to authenticated using (is_bridge_member());
create policy qjr_ins  on public.qual_job_reschedules for insert to authenticated with check (is_bridge_member());
create or replace function public.qual_reschedule_after() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  update public.qual_jobs set current_promise_date = new.to_date where id = new.job_id;
  return null;
end $$;
drop trigger if exists qjr_after_t on public.qual_job_reschedules;
create trigger qjr_after_t after insert on public.qual_job_reschedules for each row execute function public.qual_reschedule_after();
drop trigger if exists qjr_stamp_t on public.qual_job_reschedules;
create trigger qjr_stamp_t before insert on public.qual_job_reschedules for each row execute function public.bridge_stamp();

-- -----------------------------------------------------------------------------------------------------
-- 4 · Coverage events, customer-quality events, compliance checks
-- -----------------------------------------------------------------------------------------------------
create table if not exists public.qual_coverage_events(
  id              uuid primary key default gen_random_uuid(),
  team_id         uuid not null references public.qual_teams(id) on delete cascade,
  coverage_log_id uuid references public.coverage_log(id) on delete set null,
  offered_at      timestamptz not null default now(),
  lead_ref        text,
  territory       text,
  service         text,
  job_date        date not null,
  eligible        boolean not null default false,
  eligibility     jsonb not null default '{}',                     -- {territory_ok, service_ok, availability_ok, reasons[]} — snapshotted at offer time
  response        text not null default 'pending' check (response in ('pending','accepted','declined','no_response','reassigned')),
  contact_met     boolean,
  fulfilled       boolean not null default false,
  failure_reason  text,
  notes           text,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text,
  unique (team_id, coverage_log_id)
);
comment on table public.qual_coverage_events is 'One offer to one team (brief §4.2 coverage). Eligibility is computed and frozen at insert from territories, services and availability declared before the offer; later availability edits cannot change it (brief §16.14).';
alter table public.qual_coverage_events enable row level security;
drop policy if exists qce_rw on public.qual_coverage_events;
create policy qce_rw on public.qual_coverage_events for all to authenticated using (is_bridge_member()) with check (is_bridge_member());
create or replace function public.qual_coverage_before() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare t public.qual_teams%rowtype; terr_ok boolean; svc_ok boolean; av_ok boolean; reasons text[] := '{}';
begin
  if tg_op = 'UPDATE' then
    if new.eligible <> old.eligible or new.eligibility <> old.eligibility or new.job_date <> old.job_date or new.team_id <> old.team_id
       or coalesce(new.territory,'') <> coalesce(old.territory,'') or coalesce(new.service,'') <> coalesce(old.service,'') or new.offered_at <> old.offered_at then
      raise exception 'The offer and its eligibility are frozen at the time it was made. Only the response, contact and fulfilment fields change.';
    end if;
  else
    select * into t from public.qual_teams where id = new.team_id;
    terr_ok := new.territory is null or cardinality(t.territories) = 0 or new.territory = any(t.territories);
    svc_ok  := new.service is null or cardinality(t.services) = 0 or new.service = any(t.services);
    av_ok := exists (select 1 from public.qual_availability a where a.team_id = new.team_id and a.avail_date = new.job_date and a.available
                       and not a.retroactive and a.submitted_at <= new.offered_at
                       and (a.territory is null or new.territory is null or a.territory = new.territory)
                       and (a.service   is null or new.service   is null or a.service   = new.service));
    if not terr_ok then reasons := array_append(reasons, 'outside approved territory'); end if;
    if not svc_ok  then reasons := array_append(reasons, 'outside service capability'); end if;
    if not av_ok   then reasons := array_append(reasons, 'no availability declared before the offer for this date'); end if;
    new.eligible := terr_ok and svc_ok and av_ok;
    new.eligibility := jsonb_build_object('territory_ok', terr_ok, 'service_ok', svc_ok, 'availability_ok', av_ok, 'reasons', to_jsonb(reasons), 'evaluated_at', now());
  end if;
  new.fulfilled := (new.response = 'accepted' and coalesce(new.contact_met,false));
  if new.response in ('declined','no_response','reassigned') and coalesce(btrim(new.failure_reason),'') = '' then
    raise exception 'A % needs its reason recorded separately (brief §4.2).', new.response;
  end if;
  return new;
end $$;
create or replace function public.qual_coverage_after() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  update public.qual_availability set locked_at = now() where team_id = new.team_id and avail_date = new.job_date and locked_at is null;
  return null;
end $$;
drop trigger if exists qce_before_t on public.qual_coverage_events;
create trigger qce_before_t before insert or update on public.qual_coverage_events for each row execute function public.qual_coverage_before();
drop trigger if exists qce_after_t on public.qual_coverage_events;
create trigger qce_after_t after insert on public.qual_coverage_events for each row execute function public.qual_coverage_after();
drop trigger if exists qce_stamp_t on public.qual_coverage_events;
create trigger qce_stamp_t before insert or update on public.qual_coverage_events for each row execute function public.bridge_stamp();

create table if not exists public.qual_quality_events(
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references public.qual_teams(id) on delete cascade,
  job_id        uuid not null references public.qual_jobs(id) on delete cascade,
  type          text not null check (type in ('complaint','callback','refund','damage','corrective_work','other')),
  severity      text not null default 'low' check (severity in ('low','medium','severe')),
  substantiation text not null default 'pending' check (substantiation in ('pending','substantiated','unsubstantiated')),
  responsible_party text,
  cost_cents    bigint,
  status        text not null default 'open' check (status in ('open','closed')),
  evidence      text,
  opened_at     timestamptz not null default now(),
  closed_at     timestamptz,
  resolution    text,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text
);
comment on table public.qual_quality_events is 'Customer-quality events (brief §4.2). Many events may point at one job; the job counts once in the rate while every event and cost stays visible (brief §16.12).';
alter table public.qual_quality_events enable row level security;
drop policy if exists qqe_rw on public.qual_quality_events;
create policy qqe_rw on public.qual_quality_events for all to authenticated using (is_bridge_member()) with check (is_bridge_member());
create or replace function public.qual_quality_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if new.substantiation <> 'pending' and (tg_op = 'INSERT' or old.substantiation = 'pending') and not qual_is_manager() then
    raise exception 'Only the manager rules a customer issue substantiated or unsubstantiated (brief §11).';
  end if;
  if new.status = 'closed' then new.closed_at := coalesce(new.closed_at, now()); else new.closed_at := null; end if;
  return new;
end $$;
drop trigger if exists qqe_guard_t on public.qual_quality_events;
create trigger qqe_guard_t before insert or update on public.qual_quality_events for each row execute function public.qual_quality_guard();
drop trigger if exists qqe_stamp_t on public.qual_quality_events;
create trigger qqe_stamp_t before insert or update on public.qual_quality_events for each row execute function public.bridge_stamp();

create table if not exists public.qual_compliance_checks(
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references public.qual_teams(id) on delete cascade,
  job_id        uuid references public.qual_jobs(id) on delete set null,
  lead_id       uuid references public.qual_leads(id) on delete set null,
  requirement   text not null,
  critical      boolean not null default false,
  result        text not null default 'missing' check (result in ('pass','fail','missing')),
  reviewer      text,
  evidence      text,
  checked_at    timestamptz not null default now(),
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text,
  constraint qcc_pass_needs_evidence check (result <> 'pass' or coalesce(btrim(evidence),'') <> '')
);
comment on table public.qual_compliance_checks is 'Required checks per job or lead (brief §4.2 compliance). Missing evidence is not a pass — a pass row must carry evidence. Critical checks must all pass for any Pass outcome.';
alter table public.qual_compliance_checks enable row level security;
drop policy if exists qcc_rw on public.qual_compliance_checks;
create policy qcc_rw on public.qual_compliance_checks for all to authenticated using (is_bridge_member()) with check (is_bridge_member());
drop trigger if exists qcc_stamp_t on public.qual_compliance_checks;
create trigger qcc_stamp_t before insert or update on public.qual_compliance_checks for each row execute function public.bridge_stamp();

-- -----------------------------------------------------------------------------------------------------
-- 5 · Exclusions (explicit, approved, never deleting the source), supervised jobs, incidents, restrictions
-- -----------------------------------------------------------------------------------------------------
create table if not exists public.qual_exclusions(
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references public.qual_teams(id) on delete cascade,
  source_table  text not null check (source_table in ('qual_leads','qual_appointments','qual_jobs','qual_coverage_events','qual_quality_events','qual_compliance_checks')),
  source_id     uuid not null,
  category      text not null check (category in ('duplicate','not_qualified','customer_cancel_early','company_cancel','pending_young','customer_reschedule','force_majeure','other')),
  reason        text not null,
  requested_by  text, requested_at timestamptz not null default now(),
  status        text not null default 'pending' check (status in ('pending','approved','rejected')),
  decided_by    text, decided_at timestamptz, decision_note text,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text,
  unique (source_table, source_id)
);
comment on table public.qual_exclusions is 'Every record removed from a denominator is an explicit row with actor, reason, approver and time (brief §4.2, §13, §16.15). Only approved exclusions take effect; the source row is never deleted.';
alter table public.qual_exclusions enable row level security;
drop policy if exists qex_read on public.qual_exclusions;
drop policy if exists qex_ins  on public.qual_exclusions;
drop policy if exists qex_upd  on public.qual_exclusions;
create policy qex_read on public.qual_exclusions for select to authenticated using (is_bridge_member());
create policy qex_ins  on public.qual_exclusions for insert to authenticated with check (is_bridge_member());
create policy qex_upd  on public.qual_exclusions for update to authenticated using (qual_is_manager()) with check (qual_is_manager());
create or replace function public.qual_exclusion_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if tg_op = 'INSERT' then new.requested_by := auth.email(); new.requested_at := now();
    if new.status <> 'pending' and not qual_is_manager() then raise exception 'Only the manager approves an exclusion (brief §11). Submit it as pending.'; end if;
  end if;
  if new.status <> 'pending' and (tg_op = 'INSERT' or old.status = 'pending') then
    if not qual_is_manager() then raise exception 'Only the manager approves or rejects an exclusion (brief §11).'; end if;
    new.decided_by := auth.email(); new.decided_at := now();
  end if;
  if tg_op = 'UPDATE' and old.status <> 'pending' and new.status <> old.status then raise exception 'A decided exclusion is not reopened. Request a new one.'; end if;
  if coalesce(btrim(new.reason),'') = '' then raise exception 'An exclusion needs a reason.'; end if;
  return new;
end $$;
drop trigger if exists qex_guard_t on public.qual_exclusions;
create trigger qex_guard_t before insert or update on public.qual_exclusions for each row execute function public.qual_exclusion_guard();
drop trigger if exists qex_stamp_t on public.qual_exclusions;
create trigger qex_stamp_t before insert or update on public.qual_exclusions for each row execute function public.bridge_stamp();
drop trigger if exists qex_audit_t on public.qual_exclusions;
create trigger qex_audit_t after insert or update or delete on public.qual_exclusions for each row execute function public.qual_audit_row();

create table if not exists public.qual_supervised_jobs(
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references public.qual_teams(id) on delete cascade,
  job_id        uuid references public.qual_jobs(id) on delete set null,
  observed_at   date not null default current_date,
  observer      text not null,
  notes         jsonb not null default '{}',                       -- {sales_handling, workmanship, customer_interaction, documentation, safety, feedback}
  result        text check (result in ('satisfactory','needs_correction','unsatisfactory')),
  reviewed_by   text, reviewed_at timestamptz,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text
);
alter table public.qual_supervised_jobs enable row level security;
drop policy if exists qsj_rw on public.qual_supervised_jobs;
create policy qsj_rw on public.qual_supervised_jobs for all to authenticated using (is_bridge_member()) with check (is_bridge_member());
create or replace function public.qual_supervised_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if new.reviewed_at is not null and (tg_op = 'INSERT' or old.reviewed_at is null) then
    if not qual_is_manager() then raise exception 'Only the manager signs off a supervised job (brief §8.B).'; end if;
    if new.result is null then raise exception 'Record the result before signing off.'; end if;
    new.reviewed_by := auth.email();
  end if;
  return new;
end $$;
drop trigger if exists qsj_guard_t on public.qual_supervised_jobs;
create trigger qsj_guard_t before insert or update on public.qual_supervised_jobs for each row execute function public.qual_supervised_guard();
drop trigger if exists qsj_stamp_t on public.qual_supervised_jobs;
create trigger qsj_stamp_t before insert or update on public.qual_supervised_jobs for each row execute function public.bridge_stamp();

create table if not exists public.qual_incidents(
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references public.qual_teams(id) on delete cascade,
  job_id        uuid references public.qual_jobs(id) on delete set null,
  event_code    text not null,                                    -- from the version's critical_events list, or 'other'
  description   text not null,
  status        text not null default 'suspected' check (status in ('suspected','under_review','confirmed','dismissed')),
  reported_at   timestamptz not null default now(),
  reviewed_by   text, reviewed_at timestamptz, review_note text,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text
);
comment on table public.qual_incidents is 'Suspected critical events (brief §7). The software flags; it never fabricates a finding — confirmed/dismissed is the manager''s documented review, and disqualification is still a separate official decision.';
alter table public.qual_incidents enable row level security;
drop policy if exists qin_rw on public.qual_incidents;
create policy qin_rw on public.qual_incidents for all to authenticated using (is_bridge_member()) with check (is_bridge_member());
create or replace function public.qual_incident_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if new.status in ('confirmed','dismissed') and (tg_op = 'INSERT' or old.status not in ('confirmed','dismissed')) then
    if not qual_is_manager() then raise exception 'Only the manager confirms or dismisses a critical event after documented review (brief §7, §11).'; end if;
    if coalesce(btrim(new.review_note),'') = '' then raise exception 'A confirmed or dismissed incident needs the review note.'; end if;
    new.reviewed_by := auth.email(); new.reviewed_at := now();
  end if;
  if tg_op = 'UPDATE' and old.status in ('confirmed','dismissed') and new.status <> old.status then raise exception 'A reviewed incident is not reopened. Record a new incident.'; end if;
  return new;
end $$;
drop trigger if exists qin_guard_t on public.qual_incidents;
create trigger qin_guard_t before insert or update on public.qual_incidents for each row execute function public.qual_incident_guard();
drop trigger if exists qin_stamp_t on public.qual_incidents;
create trigger qin_stamp_t before insert or update on public.qual_incidents for each row execute function public.bridge_stamp();
drop trigger if exists qin_audit_t on public.qual_incidents;
create trigger qin_audit_t after insert or update or delete on public.qual_incidents for each row execute function public.qual_audit_row();

create table if not exists public.qual_restrictions(
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references public.qual_teams(id) on delete cascade,
  incident_id   uuid references public.qual_incidents(id) on delete set null,
  kind          text not null default 'no_new_assignments',
  reason        text not null,
  affects_core_coverage boolean not null default false,
  imposed_by    text, imposed_at timestamptz not null default now(),
  lifted_by     text, lifted_at timestamptz, lift_reason text,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text
);
alter table public.qual_restrictions enable row level security;
drop policy if exists qrs_read on public.qual_restrictions;
drop policy if exists qrs_write on public.qual_restrictions;
create policy qrs_read  on public.qual_restrictions for select to authenticated using (is_bridge_member());
create policy qrs_write on public.qual_restrictions for all    to authenticated using (qual_is_manager()) with check (qual_is_manager());
create or replace function public.qual_restriction_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if tg_op = 'INSERT' then new.imposed_by := auth.email(); new.imposed_at := now(); new.lifted_at := null; new.lifted_by := null; end if;
  if tg_op = 'UPDATE' and new.lifted_at is not null and old.lifted_at is null then
    if coalesce(btrim(new.lift_reason),'') = '' then raise exception 'Lifting a restriction needs a reason (brief §13: overrides carry reason, actor, time).'; end if;
    new.lifted_by := auth.email(); new.lifted_at := now();
  end if;
  return new;
end $$;
drop trigger if exists qrs_guard_t on public.qual_restrictions;
create trigger qrs_guard_t before insert or update on public.qual_restrictions for each row execute function public.qual_restriction_guard();
drop trigger if exists qrs_stamp_t on public.qual_restrictions;
create trigger qrs_stamp_t before insert or update on public.qual_restrictions for each row execute function public.bridge_stamp();
drop trigger if exists qrs_audit_t on public.qual_restrictions;
create trigger qrs_audit_t after insert or update or delete on public.qual_restrictions for each row execute function public.qual_audit_row();

-- -----------------------------------------------------------------------------------------------------
-- 6 · Snapshots (immutable evidence), official decisions, corrective actions, reviews
-- -----------------------------------------------------------------------------------------------------
create table if not exists public.qual_snapshots(
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references public.qual_teams(id) on delete cascade,
  version_id    uuid not null references public.qual_metric_versions(id),
  period_start  date not null,
  period_end    date not null,
  computed      jsonb not null,                                    -- the full engine output: categories, gates, evidence, ids
  weighted_score numeric,
  evidence_state text not null,
  recommended_outcome text,
  created_at timestamptz not null default now(), created_by text
);
comment on table public.qual_snapshots is 'Frozen calculation used for an official decision (brief §9, §16.17). Insert-only: no client role can update or delete a snapshot; live values keep refreshing on the page.';
alter table public.qual_snapshots enable row level security;
drop policy if exists qsn_read on public.qual_snapshots;
drop policy if exists qsn_ins  on public.qual_snapshots;
create policy qsn_read on public.qual_snapshots for select to authenticated using (is_bridge_member());
create policy qsn_ins  on public.qual_snapshots for insert to authenticated with check (qual_is_manager());
drop trigger if exists qsn_stamp_t on public.qual_snapshots;
create trigger qsn_stamp_t before insert on public.qual_snapshots for each row execute function public.bridge_stamp();

create table if not exists public.qual_decisions(
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references public.qual_teams(id) on delete cascade,
  snapshot_id   uuid not null references public.qual_snapshots(id),
  version_id    uuid not null references public.qual_metric_versions(id),
  kind          text not null default 'official' check (kind in ('official','requalification','probation_end')),
  recommended_outcome text,
  official_outcome text not null check (official_outcome in ('pass','coaching','probation','disqualify')),
  reason        text not null,
  restrictions  text,
  period_start  date not null,
  period_end    date not null,
  next_review_date date,
  issue         text,                                              -- coaching / probation: the named issue
  action_text   text, action_owner text, action_due date,          -- coaching / probation: the corrective action (copied into qual_actions)
  reviewer_email text, reviewer_role text,
  decided_at    timestamptz not null default now()
);
comment on table public.qual_decisions is 'Official qualification outcomes (brief §7, §16.19–20). Insert-only, manager-only; identity and time come from the JWT. Pass is refused when the snapshot is not decision-eligible or a gate failed.';
alter table public.qual_decisions enable row level security;
drop policy if exists qdc_read on public.qual_decisions;
drop policy if exists qdc_ins  on public.qual_decisions;
create policy qdc_read on public.qual_decisions for select to authenticated using (is_bridge_member());
create policy qdc_ins  on public.qual_decisions for insert to authenticated with check (qual_is_manager());
create or replace function public.qual_decision_gate() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare s public.qual_snapshots%rowtype; v public.qual_metric_versions%rowtype; gates_failed int;
begin
  if not qual_is_manager() then raise exception 'Only the manager records an official qualification decision (brief §7, §11).'; end if;
  select * into s from public.qual_snapshots where id = new.snapshot_id;
  if s.id is null then raise exception 'Unknown snapshot.'; end if;
  if s.team_id <> new.team_id then raise exception 'That snapshot belongs to another team.'; end if;
  select * into v from public.qual_metric_versions where id = s.version_id;
  if v.status <> 'active' then raise exception 'The snapshot was computed with metric version %, which is not the active version. Refresh the snapshot with the active version (brief §13: one version per official cycle).', v.version; end if;
  new.version_id := s.version_id; new.period_start := s.period_start; new.period_end := s.period_end;
  new.recommended_outcome := s.recommended_outcome;
  new.reviewer_email := auth.email(); new.reviewer_role := bridge_role(); new.decided_at := now();
  if coalesce(btrim(new.reason),'') = '' then raise exception 'A decision needs a reason.'; end if;
  gates_failed := coalesce((select count(*) from jsonb_array_elements(s.computed->'gates') g where (g->>'passed')::boolean is false), 0);
  if new.official_outcome = 'pass' then
    if s.evidence_state <> 'decision_eligible' then raise exception 'Pass refused: the team is % — minimum evidence is not satisfied (brief §7, §16.6).', s.evidence_state; end if;
    if s.weighted_score is null then raise exception 'Pass refused: the weighted score is not definitive (a category is N/A or the revenue baseline is unresolved) (brief §13, §16.7).'; end if;
    if gates_failed > 0 then raise exception 'Pass refused: % critical gate(s) failed in the snapshot (brief §4, §16.5).', gates_failed; end if;
    if s.weighted_score < coalesce((v.outcome_rules->>'pass_min')::numeric, 80) then raise exception 'Pass refused: weighted score % is below the Pass minimum %.', s.weighted_score, coalesce((v.outcome_rules->>'pass_min')::numeric, 80); end if;
    if exists (select 1 from jsonb_array_elements(s.computed->'categories') c where (c->>'points')::numeric = 0) then raise exception 'Pass refused: a category sits in the 0-point band (brief §7).'; end if;
  end if;
  if new.official_outcome in ('coaching','probation') then
    if coalesce(btrim(new.issue),'') = '' or coalesce(btrim(new.action_text),'') = '' or coalesce(btrim(new.action_owner),'') = '' or new.action_due is null or new.next_review_date is null then
      raise exception '% requires a named issue, a corrective action, an owner, a due date and a next review date (brief §7, §16.20).', initcap(new.official_outcome);
    end if;
  end if;
  return new;
end $$;
create or replace function public.qual_decision_after() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  update public.qual_metric_versions set used_in_decision = true where id = new.version_id and not used_in_decision;
  if new.official_outcome in ('coaching','probation') then
    insert into public.qual_actions(team_id, decision_id, metric_key, action, owner, due_date, next_review_date)
    values (new.team_id, new.id, new.issue, new.action_text, new.action_owner, new.action_due, new.next_review_date);
  end if;
  update public.qual_teams set status = case new.official_outcome when 'pass' then 'active' when 'disqualify' then 'disqualified' else status end,
    active_from = case when new.official_outcome = 'pass' then coalesce(active_from, new.period_end) else active_from end,
    active_to = case when new.official_outcome = 'disqualify' then coalesce(active_to, (now() at time zone 'America/Los_Angeles')::date) else active_to end
  where id = new.team_id;
  return null;
end $$;
drop trigger if exists qdc_gate_t on public.qual_decisions;
create trigger qdc_gate_t before insert on public.qual_decisions for each row execute function public.qual_decision_gate();
drop trigger if exists qdc_after_t on public.qual_decisions;
create trigger qdc_after_t after insert on public.qual_decisions for each row execute function public.qual_decision_after();
drop trigger if exists qdc_audit_t on public.qual_decisions;
create trigger qdc_audit_t after insert or update or delete on public.qual_decisions for each row execute function public.qual_audit_row();

create table if not exists public.qual_actions(
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid not null references public.qual_teams(id) on delete cascade,
  decision_id   uuid references public.qual_decisions(id) on delete set null,
  incident_id   uuid references public.qual_incidents(id) on delete set null,
  metric_key    text,
  action        text not null,
  owner         text not null,
  due_date      date not null,
  next_review_date date,
  status        text not null default 'open' check (status in ('open','done','cancelled')),
  completion_evidence text,
  closed_by     text, closed_at timestamptz,
  clickup_task_id text,                                            -- retained to avoid duplicate tasks (brief §12); closing there changes nothing here
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text
);
alter table public.qual_actions enable row level security;
drop policy if exists qac_rw on public.qual_actions;
create policy qac_rw on public.qual_actions for all to authenticated using (is_bridge_member()) with check (is_bridge_member());
create or replace function public.qual_action_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if new.status <> 'open' and (tg_op = 'INSERT' or old.status = 'open') then
    if not qual_is_manager() then raise exception 'Only the manager closes a corrective action after reviewing its completion evidence (brief §12).'; end if;
    if new.status = 'done' and coalesce(btrim(new.completion_evidence),'') = '' then raise exception 'Closing an action needs completion evidence.'; end if;
    new.closed_by := auth.email(); new.closed_at := now();
  end if;
  if new.status = 'open' then new.closed_by := null; new.closed_at := null; end if;
  return new;
end $$;
drop trigger if exists qac_guard_t on public.qual_actions;
create trigger qac_guard_t before insert or update on public.qual_actions for each row execute function public.qual_action_guard();
drop trigger if exists qac_stamp_t on public.qual_actions;
create trigger qac_stamp_t before insert or update on public.qual_actions for each row execute function public.bridge_stamp();
drop trigger if exists qac_audit_t on public.qual_actions;
create trigger qac_audit_t after insert or update or delete on public.qual_actions for each row execute function public.qual_audit_row();

create table if not exists public.qual_reviews(
  id            uuid primary key default gen_random_uuid(),
  team_id       uuid references public.qual_teams(id) on delete cascade,
  kind          text not null default 'weekly' check (kind in ('weekly','official','shadow')),
  held_at       date not null default current_date,
  participants  text,
  observations  text,
  decisions     text,
  created_at timestamptz not null default now(), created_by text
);
alter table public.qual_reviews enable row level security;
drop policy if exists qrv_read on public.qual_reviews;
drop policy if exists qrv_ins  on public.qual_reviews;
create policy qrv_read on public.qual_reviews for select to authenticated using (is_bridge_member());
create policy qrv_ins  on public.qual_reviews for insert to authenticated with check (is_bridge_member());
drop trigger if exists qrv_stamp_t on public.qual_reviews;
create trigger qrv_stamp_t before insert on public.qual_reviews for each row execute function public.bridge_stamp();

-- -----------------------------------------------------------------------------------------------------
-- 7 · Grants: nothing for anon; members through RLS. Snapshots, decisions, estimates, reschedules, reviews
--     and the audit have no update/delete grant at all.
-- -----------------------------------------------------------------------------------------------------
do $$ declare t text; begin
  foreach t in array array['qual_audit','qual_metric_versions','qual_teams','qual_team_members','qual_availability','qual_leads','qual_lead_estimates',
    'qual_appointments','qual_jobs','qual_job_reschedules','qual_coverage_events','qual_quality_events','qual_compliance_checks','qual_exclusions',
    'qual_supervised_jobs','qual_incidents','qual_restrictions','qual_snapshots','qual_decisions','qual_actions','qual_reviews'] loop
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
  end loop;
  foreach t in array array['qual_metric_versions','qual_teams','qual_team_members','qual_availability','qual_leads','qual_appointments','qual_jobs',
    'qual_coverage_events','qual_quality_events','qual_compliance_checks','qual_exclusions','qual_supervised_jobs','qual_incidents','qual_restrictions','qual_actions'] loop
    execute format('grant insert, update on public.%I to authenticated', t);
  end loop;
  foreach t in array array['qual_lead_estimates','qual_job_reschedules','qual_snapshots','qual_decisions','qual_reviews'] loop
    execute format('grant insert on public.%I to authenticated', t);
  end loop;
  grant update on public.qual_lead_estimates to authenticated;   -- outcome only; the guard refuses everything else
  grant delete on public.qual_team_members, public.qual_availability to authenticated;  -- roster typos; both are audited
  grant usage, select on sequence public.qual_audit_id_seq to authenticated;
  grant usage, select on sequence public.qual_teams_seq_seq to authenticated;
end $$;
revoke all on function public.qual_is_manager() from public, anon;
grant execute on function public.qual_is_manager() to authenticated;

-- -----------------------------------------------------------------------------------------------------
-- 8 · Seed: metric version 1 as a DRAFT — the brief's proposed defaults, with every unresolved value null.
--     Nobody is scored officially until the manager reviews this and activates it (brief §15.11).
-- -----------------------------------------------------------------------------------------------------
insert into public.qual_metric_versions(version, label, status, categories, gates, evidence, windows, revenue, outcome_rules, critical_events, margin_rules, change_note)
select 1, 'v1 — proposed defaults from the M4 brief (2026-09-23)', 'draft',
 '[
  {"key":"sales","label":"Sales effectiveness","weight_pct":20,"direction":"higher","status":"confirmed",
   "formula":"won qualified estimates ÷ decision-eligible qualified estimates","numerator":"won qualified leads","denominator":"won + customer-declined + team-failed qualified leads (+ pending past the decision-age cutoff)","target":"≥ 50% close rate","bands":{"p100":50,"p70":40,"p40":30}},
  {"key":"revenue","label":"Revenue efficiency","weight_pct":15,"direction":"higher","status":"unresolved",
   "formula":"sold revenue ÷ qualified leads assigned, as % of the approved baseline","numerator":"sold revenue of the assignment cohort","denominator":"qualified leads assigned in the period","target":"≥ 100% of the approved baseline (baseline unresolved)","bands":{"p100":100,"p70":85,"p40":70}},
  {"key":"coverage","label":"Coverage reliability","weight_pct":15,"direction":"higher","status":"proposed",
   "formula":"eligible assignments fulfilled ÷ eligible assignments offered","numerator":"eligible offers accepted with the contact/arrival obligation met","denominator":"eligible offers (territory, service and availability declared before the offer)","target":"≥ 95%","bands":{"p100":95,"p70":90,"p40":80}},
  {"key":"attendance","label":"Attendance","weight_pct":10,"direction":"higher","status":"proposed",
   "formula":"on-time attended appointments ÷ scheduled responsible appointments","numerator":"attended on time","denominator":"attended + late + no-show (documented reschedules and cancellations excluded)","target":"≥ 95% and no unexplained no-show","bands":{"p100":95,"p70":90,"p40":85}},
  {"key":"completion","label":"Completion reliability","weight_pct":15,"direction":"higher","status":"proposed",
   "formula":"compliant on-time completions ÷ jobs due","numerator":"completed by the (rescheduled) promise date with completion evidence","denominator":"jobs whose promise date fell in the period","target":"≥ 95%","bands":{"p100":95,"p70":90,"p40":85}},
  {"key":"quality","label":"Customer quality","weight_pct":15,"direction":"lower","status":"proposed",
   "formula":"jobs with a substantiated issue ÷ eligible completed jobs (past the observation window)","numerator":"mature jobs with ≥ 1 substantiated issue (a job counts once)","denominator":"completed jobs past the observation window","target":"≤ 5% and no unresolved severe incident","bands":{"p100":5,"p70":10,"p40":15}},
  {"key":"compliance","label":"Compliance","weight_pct":10,"direction":"higher","status":"proposed",
   "formula":"passed required checks ÷ required checks; every critical check must pass","numerator":"checks passed with evidence","denominator":"all required checks (fail and missing both count against)","target":"100% critical and ≥ 95% overall","bands":{"p100":95,"p70":90,"p40":80}}
 ]'::jsonb,
 '[{"key":"critical_compliance","label":"Every critical compliance check passed"},
   {"key":"no_unresolved_severe","label":"No unresolved severe customer or safety incident"},
   {"key":"no_active_restriction","label":"No active restriction"},
   {"key":"no_confirmed_critical","label":"No confirmed automatic critical event"}]'::jsonb,
 '{"window_days":28,"min_qualified_estimates":10,"min_completed_jobs":5,"supervised_jobs":3,"decision_age_days":{"value":null,"status":"unresolved"}}'::jsonb,
 '{"quality_observation_days":{"value":30,"status":"proposed"},"on_time_grace_minutes":{"value":null,"status":"unresolved"},"timezone":{"value":"America/Los_Angeles","status":"proposed"},"week_start":{"value":"monday","status":"proposed"}}'::jsonb,
 '{"baseline_cents":{"value":null,"status":"unresolved"},"credit_point":{"value":"sold","status":"proposed"},"segmented_by":{"value":null,"status":"unresolved"}}'::jsonb,
 '{"pass_min":80,"coaching_min":70,"probation_min":60,"probation_days":{"value":null,"status":"unresolved"},"coaching_repeat_to_probation":2,"membership_change_restarts":{"value":null,"status":"unresolved"}}'::jsonb,
 '[{"code":"unsafe_work","label":"Unsafe work or deliberate disregard of a safety requirement","status":"proposed"},
   {"code":"payment_fraud","label":"Payment mishandling, theft, fraud or falsified records","status":"proposed"},
   {"code":"unauthorized_pricing","label":"Deliberate unauthorized pricing, financing or job-start behavior","status":"proposed"},
   {"code":"license_failure","label":"Required license, authorization or insurance failure","status":"proposed"},
   {"code":"abandonment","label":"Abandonment of an active customer job without an approved handoff","status":"proposed"},
   {"code":"severe_harm","label":"Severe customer harm or property damage from reckless or prohibited behavior","status":"proposed"}]'::jsonb,
 '{"installation":{"target_pct":40,"floor_pct":35},"cleaning":{"floor_pct":45},"status":"confirmed"}'::jsonb,
 'Seeded from the M4 brief §4–§7 as a draft. Activate only after reviewing weights, bands, gates and the unresolved values (§18).'
where not exists (select 1 from public.qual_metric_versions where version = 1);

commit;

-- VERIFY (read-only):
-- select version, status, used_in_decision from qual_metric_versions;
-- select count(*) from pg_tables where schemaname='public' and tablename like 'qual\_%';   -- 21
