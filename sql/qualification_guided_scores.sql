-- Apply after qualification_auto_assignment.sql. No historical scores or decisions are rewritten.
begin;

create or replace function public.qual_availability_guard() returns trigger
language plpgsql security definer set search_path=public,auth as $$
declare offers integer;
begin
 if tg_op='UPDATE' then
  if new.team_id is distinct from old.team_id or new.avail_date is distinct from old.avail_date then raise exception 'Record availability for a different day as a new declaration.';end if;
  if new.submitted_at is distinct from old.submitted_at or new.retroactive is distinct from old.retroactive then raise exception 'The original availability declaration time cannot be changed.';end if;
  if (to_jsonb(new)-array['locked_at','updated_at','updated_by']) is distinct from (to_jsonb(old)-array['locked_at','updated_at','updated_by']) then raise exception 'Availability declarations are locked against rewriting. Record a new declaration; after offers exist a manager must give a correction reason.';end if;
  if new.locked_at is distinct from old.locked_at and pg_trigger_depth()=1 then raise exception 'Availability locking is maintained by recorded offers.';end if;
 else
  new.submitted_at:=clock_timestamp();new.retroactive:=new.avail_date<(now() at time zone 'America/Los_Angeles')::date;
  new.locked_at:=null;new.approved_at:=null;new.approved_by:=null;
  if new.supersedes is not null and not exists(select 1 from public.qual_availability where id=new.supersedes and team_id=new.team_id and avail_date=new.avail_date) then raise exception 'A correction must refer to this same team and date.';end if;
  select count(*) into offers from public.qual_coverage_events where team_id=new.team_id and job_date=new.avail_date;
  if offers>0 or new.supersedes is not null then
   if coalesce(btrim(new.change_reason),'')='' then raise exception 'An availability correction after offers exist needs a reason.';end if;
   if not public.qual_is_manager() then raise exception 'Only a manager records availability corrections after offers exist.';end if;
   new.approved_by:=auth.email();new.approved_at:=clock_timestamp();
  end if;
 end if;
 return new;
end $$;

create or replace function public.qual_availability_delete_guard() returns trigger
language plpgsql security definer set search_path=public,auth as $$
begin
 if old.locked_at is not null then raise exception 'Availability used by an offer cannot be deleted. Record a correction.';end if;
 return old;
end $$;
drop trigger if exists qav_delete_guard_t on public.qual_availability;
create trigger qav_delete_guard_t before delete on public.qual_availability for each row execute function public.qual_availability_delete_guard();
revoke all on function public.qual_availability_delete_guard() from public,anon,authenticated;

create or replace function public.qual_coverage_before() returns trigger
language plpgsql security definer set search_path=public,auth as $$
declare t public.qual_teams; av public.qual_availability;terr_ok boolean;svc_ok boolean;av_ok boolean;reasons text[]:='{}';
begin
 if tg_op='UPDATE' then
  if new.eligible is distinct from old.eligible or new.eligibility is distinct from old.eligibility or new.job_date is distinct from old.job_date or new.team_id is distinct from old.team_id or new.territory is distinct from old.territory or new.service is distinct from old.service or new.offered_at is distinct from old.offered_at or new.coverage_log_id is distinct from old.coverage_log_id or new.lead_ref is distinct from old.lead_ref then raise exception 'The offer identity and eligibility are frozen. Update only its response, contact confirmation or notes.';end if;
 else
  select * into t from public.qual_teams where id=new.team_id;
  terr_ok:=new.territory is not null and new.territory=any(t.territories);
  svc_ok:=new.service is not null and new.service=any(t.services);
  select * into av from public.qual_availability a where a.team_id=new.team_id and a.avail_date=new.job_date and not a.retroactive and a.submitted_at<=new.offered_at
   and (a.territory is null or a.territory=new.territory) and (a.service is null or a.service=new.service)
   order by a.submitted_at desc,a.created_at desc,a.id limit 1;
  av_ok:=coalesce(av.available,false);
  if not terr_ok then reasons:=array_append(reasons,'territory is missing or outside approved coverage');end if;
  if not svc_ok then reasons:=array_append(reasons,'service is missing or outside approved capabilities');end if;
  if not av_ok then reasons:=array_append(reasons,case when av.id is null then 'no availability declared before the offer for this date' else 'latest declaration before the offer says unavailable' end);end if;
  new.eligible:=terr_ok and svc_ok and av_ok;
  new.eligibility:=jsonb_build_object('territory_ok',terr_ok,'service_ok',svc_ok,'availability_ok',av_ok,'availability_id',av.id,'reasons',to_jsonb(reasons),'evaluated_at',clock_timestamp());
 end if;
 new.fulfilled:=new.response='accepted' and coalesce(new.contact_met,false);
 if new.response in ('declined','no_response','reassigned') and coalesce(btrim(new.failure_reason),'')='' then raise exception 'A % needs its reason recorded.',new.response;end if;
 return new;
end $$;

-- One explicit offer save. Reusing a Coverage log job/date is idempotent; status changes are not new offers.
create or replace function public.qual_record_coverage_offer(p_team uuid,p_source uuid,p_values jsonb)
returns public.qual_coverage_events language plpgsql security definer set search_path=public,auth as $$
declare t public.qual_teams;src public.coverage_log;result public.qual_coverage_events;ref text;visit_date date;offered timestamptz;matches integer;
begin
 if not public.is_bridge_member() then raise exception 'Sign in with a Bridge role.';end if;
 if jsonb_typeof(p_values) is distinct from 'object' then raise exception 'Offer values must be an object.';end if;
 ref:=nullif(upper(btrim(p_values->>'lead_ref')),'');visit_date:=(p_values->>'job_date')::date;offered:=(p_values->>'offered_at')::timestamptz;
 if ref is null or length(ref)>80 or visit_date is null or offered is null then raise exception 'Record the job reference, date and actual offer time.';end if;
 if offered>clock_timestamp() then raise exception 'The offer time cannot be in the future.';end if;
 if nullif(p_values->>'territory','') is null or coalesce(p_values->>'service','') not in ('cleaning','installation','mixed','other') then raise exception 'Choose the territory and service.';end if;
 select * into t from public.qual_teams where id=p_team;
 if not found or t.status in ('inactive','disqualified') then raise exception 'Choose a current team.';end if;
 perform pg_advisory_xact_lock(hashtextextended('qual-coverage:'||p_team||':'||ref||':'||visit_date,0));
 if p_source is not null then
  select * into src from public.coverage_log where id=p_source;
  if not found or upper(btrim(src.lead_ref)) is distinct from ref or coalesce(src.job_date,src.log_date) is distinct from visit_date then raise exception 'The reference and job date must match the selected Coverage log record.';end if;
  if not exists(select 1 from unnest(src.offered_names) n where lower(btrim(n))=lower(btrim(t.leader_name)) or exists(
   select 1 from public.qual_team_members m left join public.technicians tech on tech.id=m.technician_id where m.team_id=t.id and m.approval_status='approved' and m.active_from<=visit_date and (m.active_to is null or m.active_to>=visit_date) and (lower(btrim(m.person_name))=lower(btrim(n)) or lower(btrim(tech.name))=lower(btrim(n))))) then raise exception 'This team has no confirmed technician in the selected offer.';end if;
  select count(*) into matches from public.qual_coverage_events where team_id=p_team and (coverage_log_id=p_source or (coverage_log_id is not null and upper(btrim(lead_ref))=ref and qual_coverage_events.job_date=visit_date));
  if matches>1 then raise exception 'Several older coverage records match. Reconcile them before reusing this offer.';end if;
  select * into result from public.qual_coverage_events where team_id=p_team and (coverage_log_id=p_source or (coverage_log_id is not null and upper(btrim(lead_ref))=ref and qual_coverage_events.job_date=visit_date));
  if found then return result;end if;
 end if;
 insert into public.qual_coverage_events(team_id,coverage_log_id,lead_ref,job_date,offered_at,territory,service,response,contact_met,failure_reason,notes)
 values(p_team,p_source,ref,visit_date,offered,p_values->>'territory',p_values->>'service',coalesce(p_values->>'response','pending'),(p_values->>'contact_met')::boolean,nullif(btrim(p_values->>'failure_reason'),''),case when p_source is not null then 'Reused Coverage log; response and contact recorded explicitly.' else null end) returning * into result;
 return result;
end $$;
revoke all on function public.qual_record_coverage_offer(uuid,uuid,jsonb) from public,anon;
grant execute on function public.qual_record_coverage_offer(uuid,uuid,jsonb) to authenticated;

create or replace function public.qual_record_team_guard() returns trigger
language plpgsql security definer set search_path=public,auth as $$
begin
 if new.job_id is not null and not exists(select 1 from public.qual_jobs where id=new.job_id and team_id=new.team_id) then raise exception 'Choose a job belonging to this team.';end if;
 if tg_table_name='qual_compliance_checks' then
  if new.lead_id is not null and not exists(select 1 from public.qual_leads where id=new.lead_id and team_id=new.team_id) then raise exception 'Choose a lead belonging to this team.';end if;
 end if;
 if tg_table_name='qual_quality_events' and tg_op='UPDATE' then
  if new.status='closed' and old.status is distinct from new.status and coalesce(btrim(new.resolution),'')='' then raise exception 'Describe the resolution before closing this issue.';end if;
 end if;
 return new;
end $$;
-- Separate functions avoid referencing fields absent from another table's row type.
create or replace function public.qual_supervised_guard() returns trigger
language plpgsql security definer set search_path=public,auth as $$
begin
 if tg_op='UPDATE' and old.reviewed_at is not null and not public.qual_is_manager() and (to_jsonb(new)-array['updated_at','updated_by']) is distinct from (to_jsonb(old)-array['updated_at','updated_by']) then raise exception 'Only a manager changes a signed-off observation.';end if;
 if new.reviewed_at is not null and (tg_op='INSERT' or old.reviewed_at is null or new.job_id is distinct from old.job_id or new.result is distinct from old.result) then
  if not public.qual_is_manager() then raise exception 'Only a manager signs off a supervised job.';end if;
  if new.job_id is null or new.result is null then raise exception 'Choose the real job and result before signing off.';end if;
  if new.observed_at>(now() at time zone 'America/Los_Angeles')::date then raise exception 'An observation cannot be in the future.';end if;
  new.reviewed_by:=auth.email();
 end if;
 return new;
end $$;
drop trigger if exists qrecord_team_qe_t on public.qual_quality_events;
create trigger qrecord_team_qe_t before insert or update on public.qual_quality_events for each row execute function public.qual_record_team_guard();
drop trigger if exists qrecord_team_cc_t on public.qual_compliance_checks;
create trigger qrecord_team_cc_t before insert or update on public.qual_compliance_checks for each row execute function public.qual_record_team_guard();
drop trigger if exists qrecord_team_sup_t on public.qual_supervised_jobs;
create trigger qrecord_team_sup_t before insert or update on public.qual_supervised_jobs for each row execute function public.qual_record_team_guard();
revoke all on function public.qual_record_team_guard() from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
