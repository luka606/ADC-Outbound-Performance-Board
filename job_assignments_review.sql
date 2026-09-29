-- ADC Outbound Performance Board · Job Assignment · the Daily Meeting's "Correct" verdict
-- Adds the admin's review of each technician-day assignment to job_assignments, exactly as the AR LE Tower keeps
-- assignments.justified: 'Yes' / 'No' / null, stamped with who and when.
--
-- Attribution: the board is anonymous (no Supabase Auth), so justified_by is written by the page as 'Admin (board)'
-- behind the client-side admin PIN — the same standing as technicians.approved_by. The stamp trigger guarantees
-- justified_at / justified_by follow the verdict and are never rewritten by an unrelated edit.
-- Also seeds app_settings.job_overload_threshold (4, the Tower's value) which the Meeting reads for the overload flag.
-- Idempotent. Run after jobs_schema.sql. No policy change: the existing anon policies cover the new columns.
begin;
alter table public.job_assignments
  add column if not exists justified text,
  add column if not exists justified_by text,
  add column if not exists justified_at timestamptz;
alter table public.job_assignments drop constraint if exists job_assignments_justified_ck;
alter table public.job_assignments add constraint job_assignments_justified_ck check (justified is null or justified in ('Yes','No'));
create or replace function public.job_assignments_justified_stamp() returns trigger language plpgsql as $$
begin
  if new.justified is distinct from old.justified then
    new.justified_at := case when new.justified is null then null else now() end;
    if new.justified is null then new.justified_by := null; end if;
  else
    new.justified_by := old.justified_by; new.justified_at := old.justified_at;   -- a non-verdict edit never rewrites the stamp
  end if;
  return new;
end $$;
drop trigger if exists job_assignments_justified_stamp on public.job_assignments;
create trigger job_assignments_justified_stamp before update on public.job_assignments
  for each row execute function public.job_assignments_justified_stamp();
insert into public.app_settings(key,value) values ('job_overload_threshold','4') on conflict (key) do nothing;
commit;
-- VERIFY (read-only):
-- select column_name from information_schema.columns where table_name='job_assignments' and column_name like 'justified%';   -- 3 rows
-- select value from app_settings where key='job_overload_threshold';                                                          -- 4
-- Rollback: drop trigger job_assignments_justified_stamp on job_assignments; drop function job_assignments_justified_stamp();
--           alter table job_assignments drop column justified, drop column justified_by, drop column justified_at;
