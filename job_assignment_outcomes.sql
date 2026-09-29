-- ADC Outbound Performance Board · Job Assignment · job outcomes (the "where did the jobs go" guardrail)
-- Every expected job on job_assignments (jobs = the expected count) becomes one line here, created and kept in step by a
-- trigger. The dispatcher marks each line completed / cancelled / rescheduled / other from the Daily Meeting's day view;
-- anything but completed needs a comment saying what happened. Derived, never stored: actual = lines completed,
-- lost = cancelled + rescheduled + other, pending = untouched. The sum of lines always equals the expected count.
--
-- Attribution: the board is anonymous (no Supabase Auth); updated_by is the device's agent name or 'Dispatcher (board)',
-- the same standing as coverage_log.created_by. Lowering the expected count past a recorded outcome is refused on purpose.
-- Idempotent. Run after jobs_schema.sql. Backfills lines for existing rows (all pending).
begin;
create table if not exists public.job_assignment_outcomes(
  id            uuid primary key default gen_random_uuid(),
  assignment_id uuid not null references public.job_assignments(id) on delete cascade,
  seq           integer not null check (seq >= 1),
  outcome       text not null default 'pending' check (outcome in ('pending','completed','cancelled','rescheduled','other')),
  comment       text,
  job_ref       text,
  updated_by    text,
  updated_at    timestamptz not null default now(),
  created_at    timestamptz not null default now(),
  unique (assignment_id, seq),
  constraint jao_lost_needs_comment check (outcome in ('pending','completed') or coalesce(btrim(comment),'') <> '')
);
create index if not exists jao_assignment_idx on public.job_assignment_outcomes(assignment_id);
comment on table public.job_assignment_outcomes is 'One line per expected job (job_assignments.jobs). Outcome + comment recorded by the dispatcher; cancelled/rescheduled/other require a comment. Lines are created and trimmed by job_assignments_sync_outcomes().';

create or replace function public.jao_stamp() returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' or new.outcome is distinct from old.outcome or new.comment is distinct from old.comment or new.job_ref is distinct from old.job_ref then
    new.updated_at := now();
  end if;
  if new.job_ref is not null then new.job_ref := nullif(upper(btrim(new.job_ref)), ''); end if;
  return new;
end $$;
drop trigger if exists jao_stamp_t on public.job_assignment_outcomes;
create trigger jao_stamp_t before insert or update on public.job_assignment_outcomes for each row execute function public.jao_stamp();

-- Lines follow the expected count. security definer: the trigger deletes trimmed lines, and anon has no delete on the table.
create or replace function public.job_assignments_sync_outcomes() returns trigger language plpgsql security definer set search_path = public as $$
declare n integer := greatest(coalesce(new.jobs, 0), 0); recorded integer;
begin
  if tg_op = 'UPDATE' and new.jobs = old.jobs then return null; end if;
  select count(*) into recorded from public.job_assignment_outcomes where assignment_id = new.id and seq > n and outcome <> 'pending';
  if recorded > 0 then
    raise exception '% of these jobs already have an outcome recorded; clear them before lowering the expected count', recorded;
  end if;
  delete from public.job_assignment_outcomes where assignment_id = new.id and seq > n;
  insert into public.job_assignment_outcomes(assignment_id, seq)
    select new.id, s from generate_series(1, n) s
    on conflict (assignment_id, seq) do nothing;
  return null;
end $$;
drop trigger if exists job_assignments_sync_outcomes_t on public.job_assignments;
create trigger job_assignments_sync_outcomes_t after insert or update of jobs on public.job_assignments
  for each row execute function public.job_assignments_sync_outcomes();

-- backfill: every existing expected job gets its pending line
insert into public.job_assignment_outcomes(assignment_id, seq)
  select a.id, s from public.job_assignments a, generate_series(1, greatest(coalesce(a.jobs, 0), 0)) s
  on conflict (assignment_id, seq) do nothing;

-- access: the board's anon key reads, inserts and updates; never deletes (the trigger does); authenticated gets nothing
alter table public.job_assignment_outcomes enable row level security;
drop policy if exists jao_anon_read   on public.job_assignment_outcomes;
drop policy if exists jao_anon_insert on public.job_assignment_outcomes;
drop policy if exists jao_anon_update on public.job_assignment_outcomes;
create policy jao_anon_read   on public.job_assignment_outcomes for select to anon using (true);
create policy jao_anon_insert on public.job_assignment_outcomes for insert to anon with check (true);
create policy jao_anon_update on public.job_assignment_outcomes for update to anon using (true) with check (true);
revoke all on public.job_assignment_outcomes from authenticated, public;
grant select, insert, update on public.job_assignment_outcomes to anon;
commit;
-- VERIFY (read-only):
-- select (select coalesce(sum(greatest(jobs,0)),0) from job_assignments) as expected_lines, (select count(*) from job_assignment_outcomes) as lines;   -- equal
-- Rollback: drop trigger job_assignments_sync_outcomes_t on job_assignments; drop function job_assignments_sync_outcomes(); drop table job_assignment_outcomes;
