-- =====================================================================
-- ADC Outbound Performance Board — M2 High-Value-Job Bridge workspace
-- =====================================================================
-- Written 2026-09-18 from "ADL — M2 High-Value-Job Bridge" (brief of the same
-- date; ADL = this board). Run in Supabase > SQL Editor AFTER coverage_schema.sql.
-- Idempotent — safe to re-run; config rows are inserted ON CONFLICT DO NOTHING
-- so a value Luka changed in Settings is never overwritten by a re-run.
--
-- WHY THIS FILE IS DIFFERENT FROM EVERY OTHER SCHEMA FILE HERE
-- The brief requires approvals that are EVIDENCE: release only by the manager,
-- margin exceptions only against Sardor's confirmation, approver identity and
-- timestamp on every decision, "a checkbox editable by the technician is not
-- approval evidence". The rest of this board has no identity (auth.users = 0;
-- every browser is `anon`; Admin is a client-side PIN). So the Bridge tables
-- are the first in this project addressed to `authenticated` and gated on a
-- membership table, with the actor stamped from the JWT by trigger — the
-- client cannot set it. `anon` is revoked from every table below. The 14
-- existing tables are untouched; their posture is unchanged.
--
-- ROLES (bridge_roles): manager (Luka) — approvals, release, Sardor exceptions,
-- settings, roles; dispatcher (Vasyl) — intake, assignment, estimates, costs,
-- requests, actuals entry. Two users. Technicians and Sagi do not sign in.
--
-- SARDOR BY PROXY (Luka's decision 2026-09-18): Sardor does not sign in. A
-- margin_exception row is recorded by the manager ON SARDOR'S BEHALF and MUST
-- carry confirmed_via (text|call) and a confirmation_ref. The record says what
-- it is; it does not pretend Sardor pressed the button.
--
-- REQUIREMENT STATUS IS DATA: bridge_config.status is confirmed | proposed |
-- unresolved, exactly as the brief labels each value. Unresolved values are
-- NULL and block release where the brief says they must (Sagi compensation,
-- the combined-route deduction list). Nothing is defaulted silently.
--
-- MONEY: integer cents (bigint). Margins are compared with integer arithmetic
-- (gross_profit*100 vs floor*revenue), never on rounded percentages.
--
-- SETUP Luka does in the dashboard (this file cannot):
--   Authentication → Providers → Email: on, magic link on, "Enable sign ups" OFF.
--   Authentication → URL configuration: Site URL and Redirect = the Vercel URL.
--   Authentication → Users → Add user for luka.m@homealliance.com and
--   vasyl.k@homealliance.com (Auto Confirm). If they exist when this runs,
--   the roles are seeded below; otherwise: select grant_bridge('email','manager').
-- ---------------------------------------------------------------------
begin;

-- =====================================================================
-- 1. Membership and roles
-- =====================================================================
create table if not exists public.bridge_roles(
  user_id  uuid primary key references auth.users(id) on delete cascade,
  email    text not null,
  role     text not null check (role in ('manager','dispatcher')),
  added_at timestamptz not null default now(),
  added_by text
);
comment on table public.bridge_roles is
  'Who may open the M2 Bridge workspace, and as what. manager = Luka (approvals, release, '
  'Sardor exceptions, settings). dispatcher = Vasyl (intake, assignment, estimates, costs, '
  'requests, actuals). Grown only through grant_bridge(); shrunk only through revoke_bridge(), '
  'which refuses to remove the last manager.';
alter table public.bridge_roles enable row level security;

create or replace function public.is_bridge_member() returns boolean
language sql stable security definer set search_path = public, auth as $$
  select exists (select 1 from public.bridge_roles where user_id = auth.uid());
$$;
create or replace function public.bridge_role() returns text
language sql stable security definer set search_path = public, auth as $$
  select role from public.bridge_roles where user_id = auth.uid();
$$;
revoke all on function public.is_bridge_member() from public;
revoke all on function public.bridge_role() from public;
grant execute on function public.is_bridge_member() to anon, authenticated;
grant execute on function public.bridge_role() to anon, authenticated;

drop policy if exists bridge_roles_read on public.bridge_roles;
create policy bridge_roles_read on public.bridge_roles for select to authenticated using (is_bridge_member());
revoke all on table public.bridge_roles from anon;

-- Called by a signed-in manager from Settings, or by Luka in the SQL Editor
-- (where auth.uid() is null — the editor runs as the table owner).
create or replace function public.grant_bridge(target_email text, target_role text)
returns text language plpgsql security definer set search_path = public, auth as $$
declare v_email text := lower(btrim(coalesce(target_email,''))); v_uid uuid;
begin
  if auth.uid() is not null and coalesce(bridge_role(),'') <> 'manager' then
    raise exception 'Not authorised. Only the Bridge manager can grant a role.';
  end if;
  if target_role not in ('manager','dispatcher') then raise exception 'Role must be manager or dispatcher'; end if;
  if v_email = '' or position('@' in v_email) = 0 then raise exception 'Enter an email address.'; end if;
  select id into v_uid from auth.users where lower(email) = v_email;
  if v_uid is null then
    raise exception 'No account for %. Create it first: Supabase → Authentication → Users → Add user (Auto Confirm), then grant it here.', v_email;
  end if;
  insert into public.bridge_roles(user_id, email, role, added_by)
  values (v_uid, v_email, target_role, coalesce(auth.email(), 'sql editor'))
  on conflict (user_id) do update set role = excluded.role, added_by = excluded.added_by, added_at = now();
  return v_email || ' is a Bridge ' || target_role || ' from their next sign-in.';
end $$;

create or replace function public.revoke_bridge(target_email text)
returns text language plpgsql security definer set search_path = public, auth as $$
declare v_email text := lower(btrim(coalesce(target_email,'')));
begin
  if auth.uid() is not null and coalesce(bridge_role(),'') <> 'manager' then
    raise exception 'Not authorised. Only the Bridge manager can revoke a role.';
  end if;
  if (select count(*) from public.bridge_roles where role = 'manager'
        and lower(email) <> v_email) = 0 then
    raise exception 'Refusing: that would leave the Bridge with no manager. Grant another manager first.';
  end if;
  delete from public.bridge_roles where lower(email) = v_email;
  if not found then return v_email || ' was not a Bridge member.'; end if;
  return v_email || ' no longer has the Bridge. Their sign-in is untouched.';
end $$;
revoke all on function public.grant_bridge(text,text) from public, anon;
revoke all on function public.revoke_bridge(text) from public, anon;
grant execute on function public.grant_bridge(text,text) to authenticated;
grant execute on function public.revoke_bridge(text) to authenticated;

-- Generic stamp: who and when, from the JWT. The page never sets these. Guarded per column so the
-- same function serves every bridge_* table whatever audit columns it carries (bridge_config has no
-- created_* pair) — the first apply failed on exactly that.
create or replace function public.bridge_stamp() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare j jsonb := to_jsonb(new);
begin
  if tg_op = 'INSERT' then
    if j ? 'created_at' then new.created_at := coalesce(new.created_at, now()); end if;
    if j ? 'created_by' then new.created_by := auth.email(); end if;
  end if;
  if j ? 'updated_at' then new.updated_at := now(); end if;
  if j ? 'updated_by' then new.updated_by := auth.email(); end if;
  return new;
end $$;

-- =====================================================================
-- 2. Configuration — every value carries the brief's own status
-- =====================================================================
create table if not exists public.bridge_config(
  key        text primary key,
  value      jsonb,
  status     text not null check (status in ('confirmed','proposed','unresolved')),
  note       text,
  created_at timestamptz not null default now(),
  created_by text,
  updated_at timestamptz not null default now(),
  updated_by text
);
comment on table public.bridge_config is
  'Business rules of the M2 Bridge, one row per key. status is the brief''s own label: confirmed '
  '(Luka said so), proposed (a design recommendation, not policy), unresolved (value is NULL and '
  'the page blocks whatever depends on it). Manager-only write. Re-running the schema never '
  'overwrites a row.';
alter table public.bridge_config enable row level security;
drop policy if exists bridge_config_read  on public.bridge_config;
drop policy if exists bridge_config_write on public.bridge_config;
create policy bridge_config_read  on public.bridge_config for select to authenticated using (is_bridge_member());
create policy bridge_config_write on public.bridge_config for all    to authenticated
  using (bridge_role() = 'manager') with check (bridge_role() = 'manager');
drop trigger if exists bridge_config_stamp_t on public.bridge_config;
create trigger bridge_config_stamp_t before insert or update on public.bridge_config for each row execute function public.bridge_stamp();

insert into public.bridge_config(key, value, status, note) values
 ('install_target_pct',            '40'::jsonb, 'confirmed',  'Installation gross-margin target (brief §3.4, Luka''s latest clarification).'),
 ('install_floor_pct',             '35'::jsonb, 'confirmed',  'Installation minimum without Sardor''s exception.'),
 ('cleaning_floor_pct',            '45'::jsonb, 'confirmed',  'Duct-cleaning minimum without Sardor''s exception. No separate target specified.'),
 ('service_rules',                 '{"installation":{"target_pct":40,"floor_pct":35},"cleaning":{"floor_pct":45}}'::jsonb, 'confirmed', 'Per-service margin rules. hvac / removal / other have NO rule yet — a job containing them cannot be released until one is set here (brief §3.4).'),
 ('min_expected_revenue_cents',    '500000'::jsonb, 'confirmed', 'Minimum expected job revenue for a qualified high-value opportunity: $5,000.'),
 ('territories',                   '["LA","OC"]'::jsonb, 'confirmed', 'Los Angeles and Orange County.'),
 ('bridge_end_date',               '"2027-01-01"'::jsonb, 'confirmed', 'The bridge ends. Nothing auto-completes on this date; the page shows a review banner (brief §8).'),
 ('decision_sla_minutes',          '60'::jsonb, 'confirmed', 'Approve / hold / reject within one hour of submission.'),
 ('sla_basis',                     'null'::jsonb, 'unresolved', 'Elapsed time vs operating hours — the timer shows elapsed and says the basis is unconfirmed (brief §5, §9.5).'),
 ('timezone',                      '"America/Los_Angeles"'::jsonb, 'proposed', 'The board''s convention; the brief says confirm rather than infer (§7).'),
 ('week_start',                    '"monday"'::jsonb, 'proposed', 'Reporting week boundary; confirm (§7).'),
 ('mixed_job_rule',                '"per_service_floors_with_explicit_allocation"'::jsonb, 'proposed', 'Split revenue and direct costs per service, apply each floor, show weighted job margin; compensation allocated by revenue share (§3.4 proposed).'),
 ('callback_window_days',          '30'::jsonb, 'proposed', 'Callback metric inactive until confirmed (§7).'),
 ('combined_commission_pct',       '50'::jsonb, 'confirmed', 'Combined technician: 50% of (R − D). The deduction list D is unresolved — see the agreement.'),
 ('installer_approver',            '"Luka"'::jsonb, 'proposed', 'Proposed owner of Sagi-route installer approval; not a confirmed delegation (§3.3, §9.3).'),
 ('hvac_indicator_requires_no_hvac_check', 'true'::jsonb, 'confirmed', 'HVAC interest counts only if the HVAC department has NOT booked a separate check.'),
 ('indicators',                    '[{"code":"returning_upsell","kind":"customer","label":"Returning customer who bought additional work on the previous visit"},{"code":"expensive_area","kind":"customer","label":"Expensive area or neighborhood (e.g. Malibu)"},{"code":"hvac_interest","kind":"customer","label":"Interest in HVAC services (only if no separate HVAC check is booked)"},{"code":"multi_service","kind":"customer","label":"Multiple service needs (e.g. duct work plus asbestos removal)"},{"code":"property_value_2m","kind":"property","label":"Property value of $2M or more (Zillow)"},{"code":"property_3000sqft","kind":"property","label":"Property of at least 3,000 sq ft"},{"code":"multi_story","kind":"property","label":"Multiple stories"},{"code":"older_expensive","kind":"property","label":"Expensive older property with replacement / insulation potential"},{"code":"commercial","kind":"property","label":"Commercial property"}]'::jsonb, 'confirmed', 'The nine high-value indicators (§3.1). No numerical weighting agreed.'),
 ('cost_categories',               '["materials","company_helper","travel","equipment","disposal","financing_processing","permits","other"]'::jsonb, 'proposed', 'Cost categories offered in the economics form.'),
 ('services',                      '["installation","cleaning","hvac","removal","other"]'::jsonb, 'confirmed', 'Service classification for estimate scope.'),
 ('notify_enabled',                'false'::jsonb, 'proposed', 'Configuration, not authorization: the SLA watch DMs nobody until this is true (§5).'),
 ('notify_channel',                '"luka_dm"'::jsonb, 'proposed', 'Where SLA/urgent alerts go when enabled.'),
 ('reminder_minutes',              '[30,60]'::jsonb, 'proposed', 'Reminder points inside the hour.'),
 ('coverage_denominator_agreed',   'false'::jsonb, 'unresolved', 'Coverage % shows N/A until the required territory × service list is agreed (§8).'),
 ('coverage_demo_weeks',           '4'::jsonb, 'proposed', 'Consecutive-week demonstration period for final acceptance; not yet approved (§8).'),
 ('sagi_approved_for_estimates',   'false'::jsonb, 'unresolved', 'Rock m2: approve the former technician''s salesperson for selected high-value estimates only. Set true when Luka approves; the sagi route is offered only then.')
on conflict (key) do nothing;

-- =====================================================================
-- 3. Compensation agreements — reusable, versioned, approved by the manager
-- =====================================================================
create table if not exists public.bridge_comp_agreements(
  id                   uuid primary key default gen_random_uuid(),
  name                 text not null,
  route                text not null check (route in ('combined','sagi')),
  recipient            text,
  components           jsonb not null default '[]'::jsonb,   -- [{name, rate_pct | fixed_cents, base}]
  deduction_categories text[],                               -- NULL = unresolved (brief §9.1)
  helper_treatment     text,
  version              int  not null default 1,
  status               text not null default 'draft' check (status in ('draft','approved','superseded')),
  approved_by          text, approved_at timestamptz,
  note                 text,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text
);
comment on table public.bridge_comp_agreements is
  'Compensation agreements the economics calculator may use. A combined-route agreement cannot be '
  'approved while deduction_categories is NULL (the deduction list is unresolved). Sagi has no '
  'agreement: his jobs use an explicitly approved job-level amount (brief §3.5, §9.2). Once approved '
  'a row can only move to superseded.';
alter table public.bridge_comp_agreements enable row level security;
drop policy if exists bca_rw on public.bridge_comp_agreements;
create policy bca_rw on public.bridge_comp_agreements for all to authenticated using (is_bridge_member()) with check (is_bridge_member());

create or replace function public.bridge_agreement_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if tg_op = 'UPDATE' and old.status = 'approved' then
    if new.status = 'superseded' and to_jsonb(new) - 'status' - 'updated_at' - 'updated_by' = to_jsonb(old) - 'status' - 'updated_at' - 'updated_by' then
      return new;
    end if;
    raise exception 'An approved agreement is immutable. Create a new version and supersede this one.';
  end if;
  if new.status = 'approved' and (tg_op = 'INSERT' or old.status <> 'approved') then
    if coalesce(bridge_role(),'') <> 'manager' then raise exception 'Only the manager can approve an agreement.'; end if;
    if jsonb_array_length(new.components) = 0 then raise exception 'An agreement needs at least one component.'; end if;
    if new.route = 'combined' and new.deduction_categories is null then
      raise exception 'The combined-route deduction list is unresolved (brief §9.1). Set it explicitly before approving.';
    end if;
    new.approved_by := auth.email(); new.approved_at := now();
  end if;
  return new;
end $$;
drop trigger if exists bca_guard_t on public.bridge_comp_agreements;
create trigger bca_guard_t before insert or update on public.bridge_comp_agreements for each row execute function public.bridge_agreement_guard();
drop trigger if exists bca_stamp_t on public.bridge_comp_agreements;
create trigger bca_stamp_t before insert or update on public.bridge_comp_agreements for each row execute function public.bridge_stamp();

insert into public.bridge_comp_agreements(id, name, route, recipient, components, deduction_categories, helper_treatment, status, note)
select '11111111-1111-4111-8111-000000000001', 'Combined technician — 50% after deductions (draft)', 'combined', 'combined technician',
       '[{"name":"technician_commission","rate_pct":50,"base":"R-D"}]'::jsonb, null,
       'Company pays helpers; whether company-paid helpers reduce the commission base is unresolved.',
       'draft', 'Brief §3.5: 50% after specified costs. The list of costs deducted before commission is NOT specified — deduction_categories stays NULL and this agreement cannot be approved until Luka sets it (§9.1).'
where not exists (select 1 from public.bridge_comp_agreements where id = '11111111-1111-4111-8111-000000000001');

-- =====================================================================
-- 4. Opportunities — every lead considered, including rejected and lost
-- =====================================================================
create table if not exists public.bridge_opportunities(
  id                       uuid primary key default gen_random_uuid(),
  seq                      bigint generated always as identity,
  customer_ref             text, property_ref text, job_ref text,
  territory                text not null check (territory in ('LA','OC')),
  intake_date              date not null default ((now() at time zone 'America/Los_Angeles')::date),
  indicators               jsonb not null default '[]'::jsonb,   -- [{code, evidence, evidence_date, source}]
  expected_revenue_cents   bigint check (expected_revenue_cents is null or expected_revenue_cents >= 0),
  expected_revenue_basis   text,
  expected_revenue_unknown boolean not null default false,
  hvac_check_booked        boolean,                              -- null = not verified
  route                    text check (route in ('combined','sagi')),
  salesperson              text,
  owner_email              text,
  status                   text not null default 'intake' check (status in (
                             'intake','visit_approval_pending','visit_authorized','inspected','customer_decision_pending',
                             'economics_review','on_hold','work_released','in_progress','completed','actuals_reconciled',
                             'declined','cancelled','lost')),
  urgent                   boolean not null default false,
  outcome                  text check (outcome is null or outcome in ('won','declined','cancelled','lost')),
  loss_reason              text,
  loss_category            text check (loss_category is null or loss_category in ('internal_coverage','internal_decision_delay','internal_handoff','customer','other')),
  program                  text not null default 'M2 bridge',
  notes                    text,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text
);
comment on table public.bridge_opportunities is
  'One row per high-value lead considered — including rejected and lost ones, so conversion and '
  'lost-opportunity measures are not biased toward successes (brief §5). status is the lifecycle; '
  'work_released, visit_authorized and actuals_reconciled can only be reached through approvals or '
  'reconciliation (trigger), never by editing the row.';
create index if not exists bridge_opp_status_idx on public.bridge_opportunities(status);
create index if not exists bridge_opp_intake_idx on public.bridge_opportunities(intake_date);
alter table public.bridge_opportunities enable row level security;
drop policy if exists bopp_rw on public.bridge_opportunities;
create policy bopp_rw on public.bridge_opportunities for all to authenticated using (is_bridge_member()) with check (is_bridge_member());

-- =====================================================================
-- 5. Events — append-only lifecycle and audit, written by triggers only
-- =====================================================================
create table if not exists public.bridge_events(
  id             bigserial primary key,
  opportunity_id uuid references public.bridge_opportunities(id) on delete cascade,
  at             timestamptz not null default now(),
  actor_email    text,
  kind           text not null,
  from_status    text, to_status text,
  payload        jsonb
);
comment on table public.bridge_events is
  'Every lifecycle change and every approval, append-only. Written only by the triggers below '
  '(security definer); no client role can insert, update or delete. Read by members.';
alter table public.bridge_events enable row level security;
drop policy if exists bev_read on public.bridge_events;
create policy bev_read on public.bridge_events for select to authenticated using (is_bridge_member());

-- BEFORE, not AFTER: it defaults `outcome`, and an AFTER row trigger's changes to NEW are silently
-- discarded. Column defaults (id) are filled in before BEFORE triggers, so the event rows below are valid.
create or replace function public.bridge_opp_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare internal boolean := coalesce(current_setting('bridge.internal', true), '') = '1';
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if not internal and new.status in ('visit_authorized','work_released','actuals_reconciled') then
      raise exception '% is reached only through an approval or reconciliation, not by editing the job.', new.status;
    end if;
    if new.status in ('declined','cancelled','lost') then
      if new.outcome is null then new.outcome := case new.status when 'declined' then 'declined' when 'cancelled' then 'cancelled' else 'lost' end; end if;
      if new.status = 'lost' and nullif(btrim(coalesce(new.loss_reason,'')),'') is null then
        raise exception 'A lost opportunity needs a loss reason (brief §7: losses by reason).';
      end if;
    end if;
    insert into public.bridge_events(opportunity_id, actor_email, kind, from_status, to_status)
    values (new.id, auth.email(), 'status', old.status, new.status);
  end if;
  if tg_op = 'INSERT' then
    insert into public.bridge_events(opportunity_id, actor_email, kind, from_status, to_status)
    values (new.id, auth.email(), 'created', null, new.status);
  end if;
  return new;
end $$;
drop trigger if exists bopp_stamp_t on public.bridge_opportunities;
create trigger bopp_stamp_t before insert or update on public.bridge_opportunities for each row execute function public.bridge_stamp();
drop trigger if exists bopp_guard_t on public.bridge_opportunities;
create trigger bopp_guard_t before insert or update on public.bridge_opportunities for each row execute function public.bridge_opp_guard();

-- =====================================================================
-- 6. Assignments — versioned staffing by route
-- =====================================================================
create table if not exists public.bridge_assignments(
  id                     uuid primary key default gen_random_uuid(),
  opportunity_id         uuid not null references public.bridge_opportunities(id) on delete cascade,
  version                int  not null,
  route                  text not null check (route in ('combined','sagi')),
  salesperson            text,
  performing_technician  text,                          -- combined route: one responsible technician (technicians.name)
  installer_name         text, installer_capability text, installer_availability text,   -- sagi route
  installer_approved     boolean not null default false,
  installer_approved_by  text, installer_approved_at timestamptz,
  helpers                jsonb not null default '[]'::jsonb,   -- [{name, payer: company|sagi}]
  note                   text,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text,
  unique (opportunity_id, version)
);
comment on table public.bridge_assignments is
  'Who sells and who performs, versioned per opportunity. Combined route: one responsible technician '
  'with both capabilities; helpers do not become approved installers by assisting. Sagi route: the '
  'installer identity, capability, availability and a SEPARATE approval by the manager (brief §3.3). '
  'The helper payer is recorded explicitly — never assume an installer subcontracted by Sagi is company-paid.';
alter table public.bridge_assignments enable row level security;
drop policy if exists bas_rw on public.bridge_assignments;
create policy bas_rw on public.bridge_assignments for all to authenticated using (is_bridge_member()) with check (is_bridge_member());
create or replace function public.bridge_assignment_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if new.installer_approved and (tg_op = 'INSERT' or not old.installer_approved) then
    if coalesce(bridge_role(),'') <> 'manager' then raise exception 'Only the manager can approve an installer (brief §3.3; approver proposed: Luka).'; end if;
    if nullif(btrim(coalesce(new.installer_name,'')),'') is null then raise exception 'Name the installer before approving.'; end if;
    new.installer_approved_by := auth.email(); new.installer_approved_at := now();
  end if;
  if not new.installer_approved then new.installer_approved_by := null; new.installer_approved_at := null; end if;
  return new;
end $$;
drop trigger if exists bas_guard_t on public.bridge_assignments;
create trigger bas_guard_t before insert or update on public.bridge_assignments for each row execute function public.bridge_assignment_guard();
drop trigger if exists bas_stamp_t on public.bridge_assignments;
create trigger bas_stamp_t before insert or update on public.bridge_assignments for each row execute function public.bridge_stamp();

-- =====================================================================
-- 7. Estimates — versioned; a version is never edited except to record acceptance
-- =====================================================================
create table if not exists public.bridge_estimates(
  id                   uuid primary key default gen_random_uuid(),
  opportunity_id       uuid not null references public.bridge_opportunities(id) on delete cascade,
  version              int  not null,
  scope                jsonb not null default '[]'::jsonb,   -- [{service, description, price_cents}]
  customer_price_cents bigint not null check (customer_price_cents >= 0),
  discounts_cents      bigint not null default 0 check (discounts_cents >= 0),
  payment_terms        text, financing text, previous_price_ref text,
  customer_accepted    boolean not null default false,
  customer_accepted_at timestamptz,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text,
  unique (opportunity_id, version)
);
comment on table public.bridge_estimates is
  'Estimate versions. Customer acceptance is separate from internal permission to start work '
  '(brief §3.2). Any change to scope or price is a new version; the only UPDATE allowed is recording acceptance.';
alter table public.bridge_estimates enable row level security;
drop policy if exists best_rw on public.bridge_estimates;
create policy best_rw on public.bridge_estimates for all to authenticated using (is_bridge_member()) with check (is_bridge_member());
create or replace function public.bridge_estimate_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if tg_op = 'UPDATE' then
    if to_jsonb(new) - 'customer_accepted' - 'customer_accepted_at' - 'updated_at' - 'updated_by'
       <> to_jsonb(old) - 'customer_accepted' - 'customer_accepted_at' - 'updated_at' - 'updated_by' then
      raise exception 'An estimate version is never edited. Create a new version.';
    end if;
    if new.customer_accepted and not old.customer_accepted then new.customer_accepted_at := coalesce(new.customer_accepted_at, now()); end if;
  end if;
  return new;
end $$;
drop trigger if exists best_guard_t on public.bridge_estimates;
create trigger best_guard_t before update on public.bridge_estimates for each row execute function public.bridge_estimate_guard();
drop trigger if exists best_stamp_t on public.bridge_estimates;
create trigger best_stamp_t before insert or update on public.bridge_estimates for each row execute function public.bridge_stamp();

-- =====================================================================
-- 8. Economics — versioned snapshots; an approved version is immutable
-- =====================================================================
create table if not exists public.bridge_economics(
  id                          uuid primary key default gen_random_uuid(),
  opportunity_id              uuid not null references public.bridge_opportunities(id) on delete cascade,
  version                     int  not null,
  estimate_id                 uuid references public.bridge_estimates(id),
  estimate_version            int,
  route                       text not null check (route in ('combined','sagi')),
  agreement_id                uuid references public.bridge_comp_agreements(id),
  job_level_comp_cents        bigint check (job_level_comp_cents is null or job_level_comp_cents >= 0),
  job_level_comp_note         text,                 -- inclusions, payer, scope (brief §9 last paragraph)
  job_level_comp_approved_by  text, job_level_comp_approved_at timestamptz,
  costs                       jsonb not null default '[]'::jsonb,
    -- [{category, amount_cents, payer: company|sagi|technician, status: estimated|actual|unknown, ref, reduces_commission_base, included_in_other_payment}]
  service_split               jsonb not null default '[]'::jsonb,   -- [{service, revenue_cents, direct_cost_cents}]
  r_cents bigint, d_cents bigint, c_cents bigint, k_cents bigint, gross_profit_cents bigint,
  margin                      numeric(12,8),
  gate                        text check (gate in ('meets_target','below_target_above_floor','below_floor','invalid')),
  validation_issues           jsonb not null default '[]'::jsonb,
  status                      text not null default 'draft' check (status in ('draft','approved','superseded')),
  approved_by                 text, approved_at timestamptz,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text,
  unique (opportunity_id, version)
);
comment on table public.bridge_economics is
  'The approved economics snapshot the brief requires (§4): inputs and the computed R, D, C, K, gross '
  'profit, margin and gate, per version. Approving freezes the row; a later change to scope, price, '
  'discount, commission or company cost is a NEW version and pulls the job back to economics_review. '
  'The original approved projection is never overwritten by actuals — those live in bridge_actuals.';
alter table public.bridge_economics enable row level security;
drop policy if exists beco_rw on public.bridge_economics;
create policy beco_rw on public.bridge_economics for all to authenticated using (is_bridge_member()) with check (is_bridge_member());
create or replace function public.bridge_economics_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare v_gate text;
begin
  if tg_op = 'UPDATE' and old.status = 'approved' then
    if new.status = 'superseded' and to_jsonb(new) - 'status' - 'updated_at' - 'updated_by' = to_jsonb(old) - 'status' - 'updated_at' - 'updated_by' then return new; end if;
    raise exception 'An approved economics version is immutable. Save a new version.';
  end if;
  if new.job_level_comp_approved_by is distinct from coalesce(old.job_level_comp_approved_by, null) and new.job_level_comp_approved_by is not null then
    if coalesce(bridge_role(),'') <> 'manager' then raise exception 'Only the manager can approve a job-level compensation amount.'; end if;
    if new.job_level_comp_cents is null or nullif(btrim(coalesce(new.job_level_comp_note,'')),'') is null then
      raise exception 'A job-level amount needs the amount and a note stating inclusions, payer and scope (brief §9).';
    end if;
    new.job_level_comp_approved_by := auth.email(); new.job_level_comp_approved_at := now();
  end if;
  if new.status = 'approved' and (tg_op = 'INSERT' or old.status <> 'approved') then
    if coalesce(bridge_role(),'') <> 'manager' then raise exception 'Only the manager can approve an economics version.'; end if;
    if jsonb_array_length(new.validation_issues) > 0 then raise exception 'This version has validation issues and cannot be approved: %', new.validation_issues; end if;
    if new.gate is null or new.gate = 'invalid' then raise exception 'This version is not computable and cannot be approved.'; end if;
    if new.r_cents is null or new.r_cents <= 0 then raise exception 'Zero revenue gives no valid margin (brief §4).'; end if;
    new.approved_by := auth.email(); new.approved_at := now();
    -- supersede earlier approved versions of the same opportunity
    perform set_config('bridge.internal','1',true);
    update public.bridge_economics set status = 'superseded' where opportunity_id = new.opportunity_id and status = 'approved' and id <> new.id;
  end if;
  return new;
end $$;
drop trigger if exists beco_guard_t on public.bridge_economics;
create trigger beco_guard_t before insert or update on public.bridge_economics for each row execute function public.bridge_economics_guard();
drop trigger if exists beco_stamp_t on public.bridge_economics;
create trigger beco_stamp_t before insert or update on public.bridge_economics for each row execute function public.bridge_stamp();

-- A new draft version after an approval pulls the job back to review and keeps both versions.
create or replace function public.bridge_economics_after() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if tg_op = 'INSERT' and new.status = 'draft' then
    if exists (select 1 from public.bridge_opportunities where id = new.opportunity_id and status in ('work_released','in_progress')) then
      perform set_config('bridge.internal','1',true);
      update public.bridge_opportunities set status = 'economics_review' where id = new.opportunity_id;
      insert into public.bridge_events(opportunity_id, actor_email, kind, payload)
      values (new.opportunity_id, auth.email(), 'release_invalidated', jsonb_build_object('economics_version', new.version));
    end if;
  end if;
  return new;
end $$;
drop trigger if exists beco_after_t on public.bridge_economics;
create trigger beco_after_t after insert on public.bridge_economics for each row execute function public.bridge_economics_after();

-- =====================================================================
-- 9. Decision requests — the one-hour clock
-- =====================================================================
create table if not exists public.bridge_requests(
  id                        uuid primary key default gen_random_uuid(),
  opportunity_id            uuid not null references public.bridge_opportunities(id) on delete cascade,
  type                      text not null check (type in ('visit_approval','work_release')),
  submitted_at              timestamptz not null default now(),   -- first submission; never reset
  resubmitted_at            timestamptz,
  urgent                    boolean not null default false,
  economics_version         int,
  missing_info_requested_at timestamptz, missing_info_text text,
  decided_at                timestamptz, decision text check (decision is null or decision in ('approve','hold','reject')),
  decided_by                text,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text
);
comment on table public.bridge_requests is
  'A request for a manager decision. submitted_at is the FIRST submission and cannot change: resubmitting '
  'after missing information does not erase elapsed time (brief §5). A request pending beyond the SLA is a '
  'miss, not absent from the denominator. Never auto-approved.';
alter table public.bridge_requests enable row level security;
drop policy if exists breq_rw on public.bridge_requests;
create policy breq_rw on public.bridge_requests for all to authenticated using (is_bridge_member()) with check (is_bridge_member());
create or replace function public.bridge_request_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if tg_op = 'UPDATE' then
    if new.submitted_at <> old.submitted_at then raise exception 'submitted_at is the first submission and cannot change.'; end if;
    if old.decided_at is not null and coalesce(current_setting('bridge.internal', true),'') <> '1'
       and (new.decided_at is distinct from old.decided_at or new.decision is distinct from old.decision) then
      raise exception 'A decided request is not edited. Submit a new request.';
    end if;
  end if;
  return new;
end $$;
drop trigger if exists breq_guard_t on public.bridge_requests;
create trigger breq_guard_t before update on public.bridge_requests for each row execute function public.bridge_request_guard();
drop trigger if exists breq_stamp_t on public.bridge_requests;
create trigger breq_stamp_t before insert or update on public.bridge_requests for each row execute function public.bridge_stamp();

-- Submitting a request moves the job into the pending state.
create or replace function public.bridge_request_after() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  perform set_config('bridge.internal','1',true);
  -- A visit request is asked from intake or a hold. A release request may come from ANY open, unreleased
  -- state — a returning customer who pre-approves their prior price never needs an estimate visit (brief §3.2).
  if new.type = 'visit_approval' then
    update public.bridge_opportunities set status = 'visit_approval_pending' where id = new.opportunity_id and status in ('intake','on_hold');
  else
    update public.bridge_opportunities set status = 'economics_review' where id = new.opportunity_id
       and status not in ('work_released','in_progress','completed','actuals_reconciled','declined','cancelled','lost','economics_review');
  end if;
  return new;
end $$;
drop trigger if exists breq_after_t on public.bridge_requests;
create trigger breq_after_t after insert on public.bridge_requests for each row execute function public.bridge_request_after();

-- =====================================================================
-- 10. Approvals — append-only; actor from the JWT; the release gate lives here
-- =====================================================================
create table if not exists public.bridge_approvals(
  id                uuid primary key default gen_random_uuid(),
  opportunity_id    uuid not null references public.bridge_opportunities(id) on delete cascade,
  request_id        uuid references public.bridge_requests(id),
  type              text not null check (type in ('visit_approval','work_release','margin_exception','hold','reject','reopen')),
  decision          text not null check (decision in ('approve','hold','reject','record')),
  actor_email       text, actor_role text,
  at                timestamptz not null default now(),
  economics_version int, estimate_version int,
  reason            text,
  on_behalf_of      text, confirmed_via text check (confirmed_via is null or confirmed_via in ('text','call')),
  confirmation_ref  text, confirmed_at timestamptz
);
comment on table public.bridge_approvals is
  'Every approval decision, append-only. actor_email and actor_role are set by trigger from the JWT — '
  'a value sent by the client is ignored. work_release runs the release gate (§5B). margin_exception is '
  'recorded by the manager ON SARDOR''S BEHALF and must carry confirmed_via and confirmation_ref '
  '(Luka''s decision 2026-09-18); Sardor''s exception alone never releases work, and Luka''s release '
  'alone never releases a below-floor job.';
create index if not exists bappr_opp_idx on public.bridge_approvals(opportunity_id, at desc);
alter table public.bridge_approvals enable row level security;
drop policy if exists bappr_read   on public.bridge_approvals;
drop policy if exists bappr_insert on public.bridge_approvals;
create policy bappr_read   on public.bridge_approvals for select to authenticated using (is_bridge_member());
create policy bappr_insert on public.bridge_approvals for insert to authenticated with check (is_bridge_member());

create or replace function public.bridge_approval_gate() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare
  v_opp   public.bridge_opportunities%rowtype;
  v_econ  public.bridge_economics%rowtype;
  v_est   public.bridge_estimates%rowtype;
  v_asg   public.bridge_assignments%rowtype;
  v_agr   public.bridge_comp_agreements%rowtype;
  v_rules jsonb;
  v_svc   text;
begin
  new.actor_email := auth.email();
  new.actor_role  := bridge_role();
  new.at          := now();
  if coalesce(new.actor_role,'') <> 'manager' then
    raise exception 'Only the manager can record approvals, holds, rejections or exceptions.';
  end if;
  select * into v_opp from public.bridge_opportunities where id = new.opportunity_id;
  if v_opp.id is null then raise exception 'Unknown opportunity'; end if;

  if new.type = 'margin_exception' then
    if new.on_behalf_of is distinct from 'Sardor' then raise exception 'A margin exception is recorded on Sardor''s behalf (on_behalf_of = ''Sardor'').'; end if;
    if new.confirmed_via is null or nullif(btrim(coalesce(new.confirmation_ref,'')),'') is null then
      raise exception 'Sardor''s confirmation is required: how (text / call) and a reference to it.';
    end if;
    if new.economics_version is null then raise exception 'Name the economics version the exception applies to.'; end if;
    new.decision := 'record'; new.confirmed_at := coalesce(new.confirmed_at, now());
    return new;
  end if;

  if new.type = 'work_release' and new.decision = 'approve' then
    if new.economics_version is null then raise exception 'Release must name the economics version it approves.'; end if;
    select * into v_econ from public.bridge_economics where opportunity_id = new.opportunity_id and version = new.economics_version;
    if v_econ.id is null then raise exception 'Economics version % does not exist.', new.economics_version; end if;
    if v_econ.status <> 'approved' then raise exception 'Economics version % is not approved — approve it first, or fix its issues.', new.economics_version; end if;
    if v_econ.gate = 'invalid' or jsonb_array_length(v_econ.validation_issues) > 0 then raise exception 'Economics are incomplete; the job stays on hold (brief §5B.4).'; end if;
    if v_econ.gate = 'below_floor' and not exists (
         select 1 from public.bridge_approvals a where a.opportunity_id = new.opportunity_id
            and a.type = 'margin_exception' and a.economics_version = new.economics_version) then
      raise exception 'Margin is below its floor. Renegotiate, or record Sardor''s exception for version % first (brief §5B.5).', new.economics_version;
    end if;
    -- unknown costs never count as zero
    if exists (select 1 from jsonb_array_elements(v_econ.costs) c where c->>'status' = 'unknown') then
      raise exception 'A cost is still unknown. Unknown is not zero (brief §4).';
    end if;
    -- customer acceptance of the estimate this version priced
    select * into v_est from public.bridge_estimates where id = v_econ.estimate_id;
    if v_est.id is null then raise exception 'Economics version % is not tied to an estimate version.', new.economics_version; end if;
    if not v_est.customer_accepted then raise exception 'The customer has not accepted estimate v%. Acceptance and internal release are both required (brief §5B.1).', v_est.version; end if;
    -- every service classified with a rule
    select value into v_rules from public.bridge_config where key = 'service_rules';
    for v_svc in select distinct s->>'service' from jsonb_array_elements(v_est.scope) s loop
      if v_svc is null or v_svc = 'other' or not (coalesce(v_rules,'{}'::jsonb) ? v_svc) then
        raise exception 'Service "%" has no margin rule. Classify it and set its rule in Settings before release (brief §3.4).', coalesce(v_svc,'(none)');
      end if;
    end loop;
    -- staffing
    select * into v_asg from public.bridge_assignments where opportunity_id = new.opportunity_id order by version desc limit 1;
    if v_asg.id is null then raise exception 'No assignment: name who performs the work.'; end if;
    if v_econ.route = 'sagi' then
      if not v_asg.installer_approved then raise exception 'Sagi-route installer is not approved (brief §3.3).'; end if;
      if v_econ.job_level_comp_cents is not null then
        if v_econ.job_level_comp_approved_by is null then raise exception 'Sagi''s job-level compensation amount is not approved.'; end if;
      elsif v_econ.agreement_id is not null then
        select * into v_agr from public.bridge_comp_agreements where id = v_econ.agreement_id;
        if v_agr.status <> 'approved' or v_agr.route <> 'sagi' then raise exception 'Sagi''s compensation agreement is not approved.'; end if;
      else
        raise exception 'Sagi''s compensation is unresolved: an explicit approved job-level amount is required before release (brief §2, §9.2).';
      end if;
    else
      if nullif(btrim(coalesce(v_asg.performing_technician,'')),'') is null then raise exception 'Name the performing technician.'; end if;
      if v_econ.job_level_comp_cents is null then
        select * into v_agr from public.bridge_comp_agreements where id = v_econ.agreement_id;
        if v_agr.id is null or v_agr.status <> 'approved' then raise exception 'The combined-route compensation agreement is not approved (deduction list unresolved — brief §9.1).'; end if;
      elsif v_econ.job_level_comp_approved_by is null then
        raise exception 'The job-level compensation amount is not approved.';
      end if;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists bappr_gate_t on public.bridge_approvals;
create trigger bappr_gate_t before insert on public.bridge_approvals for each row execute function public.bridge_approval_gate();

create or replace function public.bridge_approval_after() returns trigger
language plpgsql security definer set search_path = public, auth as $$
declare v_to text;
begin
  perform set_config('bridge.internal','1',true);
  if new.request_id is not null then
    update public.bridge_requests set decided_at = new.at, decision = case when new.type in ('visit_approval','work_release') then 'approve' else new.decision end, decided_by = new.actor_email
     where id = new.request_id and decided_at is null;
  end if;
  v_to := case
    when new.type = 'visit_approval' and new.decision = 'approve' then 'visit_authorized'
    when new.type = 'work_release'   and new.decision = 'approve' then 'work_released'
    when new.type = 'hold'   then 'on_hold'
    when new.type = 'reject' then 'declined'
    when new.type = 'reopen' then 'economics_review'
    else null end;
  if v_to is not null then
    update public.bridge_opportunities set status = v_to where id = new.opportunity_id;
  end if;
  insert into public.bridge_events(opportunity_id, actor_email, kind, payload)
  values (new.opportunity_id, new.actor_email, 'approval', jsonb_build_object('type', new.type, 'decision', new.decision,
          'economics_version', new.economics_version, 'reason', new.reason, 'on_behalf_of', new.on_behalf_of,
          'confirmed_via', new.confirmed_via, 'confirmation_ref', new.confirmation_ref));
  return new;
end $$;
drop trigger if exists bappr_after_t on public.bridge_approvals;
create trigger bappr_after_t after insert on public.bridge_approvals for each row execute function public.bridge_approval_after();

-- =====================================================================
-- 11. Completion and actuals — reconciliation, never overwriting the projection
-- =====================================================================
create table if not exists public.bridge_actuals(
  opportunity_id      uuid primary key references public.bridge_opportunities(id) on delete cascade,
  completed_at        timestamptz, evidence_ref text,
  final_revenue_cents bigint check (final_revenue_cents is null or final_revenue_cents >= 0),
  actual_costs        jsonb not null default '[]'::jsonb,
  final_comp_cents    bigint,
  payment_status      text check (payment_status is null or payment_status in ('unpaid','partial','paid','refunded')),
  actual_margin       numeric(12,8),
  callback            jsonb, refund jsonb,
  reconciled          boolean not null default false,
  reconciled_by       text, reconciled_at timestamptz,
  note                text,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text
);
comment on table public.bridge_actuals is
  'Final revenue, actual costs, final compensation, payment status and actual margin per completed job, '
  'for Luka''s weekly reconciliation (brief §5B.8, §7). Unreconciled costs never count as zero.';
alter table public.bridge_actuals enable row level security;
drop policy if exists bact_rw on public.bridge_actuals;
create policy bact_rw on public.bridge_actuals for all to authenticated using (is_bridge_member()) with check (is_bridge_member());
create or replace function public.bridge_actuals_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if new.reconciled and (tg_op = 'INSERT' or not old.reconciled) then
    if coalesce(bridge_role(),'') <> 'manager' then raise exception 'Only the manager reconciles a job.'; end if;
    if new.final_revenue_cents is null then raise exception 'Final revenue is required to reconcile.'; end if;
    if exists (select 1 from jsonb_array_elements(new.actual_costs) c where c->>'status' = 'unknown') then raise exception 'An actual cost is still unknown — it does not count as zero.'; end if;
    new.reconciled_by := auth.email(); new.reconciled_at := now();
  end if;
  return new;
end $$;
drop trigger if exists bact_guard_t on public.bridge_actuals;
create trigger bact_guard_t before insert or update on public.bridge_actuals for each row execute function public.bridge_actuals_guard();
drop trigger if exists bact_stamp_t on public.bridge_actuals;
create trigger bact_stamp_t before insert or update on public.bridge_actuals for each row execute function public.bridge_stamp();
create or replace function public.bridge_actuals_after() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  perform set_config('bridge.internal','1',true);
  if new.reconciled and (tg_op = 'INSERT' or not old.reconciled) then
    update public.bridge_opportunities set status = 'actuals_reconciled' where id = new.opportunity_id;
  elsif new.completed_at is not null and (tg_op = 'INSERT' or old.completed_at is null) then
    update public.bridge_opportunities set status = 'completed' where id = new.opportunity_id and status in ('work_released','in_progress');
  end if;
  return new;
end $$;
drop trigger if exists bact_after_t on public.bridge_actuals;
create trigger bact_after_t after insert or update on public.bridge_actuals for each row execute function public.bridge_actuals_after();

-- =====================================================================
-- 12. Coverage register — permanent coverage, never counted from bridge jobs
-- =====================================================================
create table if not exists public.bridge_coverage_register(
  id                  uuid primary key default gen_random_uuid(),
  territory           text not null,
  service             text not null,
  primary_name        text, backup_name text,
  capability_evidence text, availability text,
  shared_dependencies text,
  accepted            boolean not null default false,
  accepted_by         text, accepted_at timestamptz,
  note                text,
  created_at timestamptz not null default now(), created_by text,
  updated_at timestamptz not null default now(), updated_by text,
  unique (territory, service)
);
comment on table public.bridge_coverage_register is
  'Territory × service → approved primary and independent backup able to both sell and perform (brief §8). '
  'Bridge jobs never increment this. Coverage % is computed only once coverage_denominator_agreed is true. '
  'Two backups sharing one indispensable installer are not independent capacity.';
alter table public.bridge_coverage_register enable row level security;
drop policy if exists bcov_rw on public.bridge_coverage_register;
create policy bcov_rw on public.bridge_coverage_register for all to authenticated using (is_bridge_member()) with check (is_bridge_member());
create or replace function public.bridge_coverage_guard() returns trigger
language plpgsql security definer set search_path = public, auth as $$
begin
  if new.accepted and (tg_op = 'INSERT' or not old.accepted) then
    if coalesce(bridge_role(),'') <> 'manager' then raise exception 'Only the manager accepts coverage.'; end if;
    if nullif(btrim(coalesce(new.primary_name,'')),'') is null or nullif(btrim(coalesce(new.backup_name,'')),'') is null then raise exception 'Acceptance needs a primary and a backup.'; end if;
    if lower(btrim(new.primary_name)) = lower(btrim(new.backup_name)) then raise exception 'Primary and backup must be different people.'; end if;
    new.accepted_by := auth.email(); new.accepted_at := now();
  end if;
  if not new.accepted then new.accepted_by := null; new.accepted_at := null; end if;
  return new;
end $$;
drop trigger if exists bcov_guard_t on public.bridge_coverage_register;
create trigger bcov_guard_t before insert or update on public.bridge_coverage_register for each row execute function public.bridge_coverage_guard();
drop trigger if exists bcov_stamp_t on public.bridge_coverage_register;
create trigger bcov_stamp_t before insert or update on public.bridge_coverage_register for each row execute function public.bridge_stamp();

-- =====================================================================
-- 13. Privileges — anon gets nothing; no client role deletes; history is append-only
-- =====================================================================
revoke all on public.bridge_roles, public.bridge_config, public.bridge_comp_agreements, public.bridge_opportunities,
  public.bridge_events, public.bridge_assignments, public.bridge_estimates, public.bridge_economics,
  public.bridge_requests, public.bridge_approvals, public.bridge_actuals, public.bridge_coverage_register
  from anon, authenticated;
grant select, insert, update on public.bridge_config, public.bridge_comp_agreements, public.bridge_opportunities,
  public.bridge_assignments, public.bridge_estimates, public.bridge_economics, public.bridge_requests,
  public.bridge_actuals, public.bridge_coverage_register to authenticated;
grant select on public.bridge_roles, public.bridge_events to authenticated;
grant select, insert on public.bridge_approvals to authenticated;
grant usage on sequence public.bridge_events_id_seq to authenticated;
grant usage on sequence public.bridge_opportunities_seq_seq to authenticated;

-- =====================================================================
-- 14. First members — only if the accounts already exist
-- =====================================================================
insert into public.bridge_roles(user_id, email, role, added_by)
select u.id, lower(u.email), 'manager', 'bridge_schema.sql' from auth.users u where lower(u.email) = 'luka.m@homealliance.com'
on conflict (user_id) do nothing;
insert into public.bridge_roles(user_id, email, role, added_by)
select u.id, lower(u.email), 'dispatcher', 'bridge_schema.sql' from auth.users u where lower(u.email) = 'vasyl.k@homealliance.com'
on conflict (user_id) do nothing;

commit;

-- =====================================================================
-- VERIFY (run after committing)
-- =====================================================================
-- 1. Roles seeded (expect 2 rows once the accounts exist):   select email, role from bridge_roles;
-- 2. anon sees nothing (impersonate, roll back):
--      begin; set local role anon; select count(*) from bridge_opportunities; rollback;   -- expect 42501
-- 3. A release with no approved economics is refused (as a signed-in manager, from the app or with
--    `set local request.jwt.claims`): insert into bridge_approvals(opportunity_id,type,decision,economics_version)
--    values ('<id>','work_release','approve',1);  -- expect "not approved — approve it first"
-- 4. A Sardor exception without a reference is refused:
--      insert into bridge_approvals(opportunity_id,type,decision,economics_version,on_behalf_of,confirmed_via)
--      values ('<id>','margin_exception','record',1,'Sardor','text');   -- expect "confirmation is required"
-- 5. History is append-only:   update bridge_approvals set reason='x';   -- expect 42501 for authenticated
-- 6. The combined agreement cannot be approved while its deduction list is NULL:
--      update bridge_comp_agreements set status='approved' where id='11111111-1111-4111-8111-000000000001';
--      -- expect "deduction list is unresolved"
