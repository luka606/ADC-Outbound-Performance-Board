-- Apply after qualification_linked_jobs.sql. Automatic intake uses existing source permissions.
-- Existing visits are queued for review; no scores, decisions, sales or costs are backfilled.
begin;
create table if not exists public.qual_assignment_auto_settings(
 id boolean primary key default true check(id), enabled boolean not null default true,
 started_at timestamptz not null default clock_timestamp()
);
insert into public.qual_assignment_auto_settings(id) values(true) on conflict do nothing;
alter table public.qual_assignment_auto_settings enable row level security;
drop policy if exists qual_auto_settings_read on public.qual_assignment_auto_settings;
create policy qual_auto_settings_read on public.qual_assignment_auto_settings for select to authenticated using(public.is_bridge_member());
revoke all on public.qual_assignment_auto_settings from public,anon,authenticated;
grant select on public.qual_assignment_auto_settings to authenticated;

alter table public.qual_assignment_links add column if not exists link_method text not null default 'manual';
alter table public.qual_assignment_links add column if not exists source_job_ref text;
alter table public.qual_assignment_links add column if not exists source_date date;
alter table public.qual_assignment_links add column if not exists source_technician text;
update public.qual_assignment_links x set source_job_ref=coalesce(o.job_ref,l.lead_ref),source_date=a.date,source_technician=a.technician
from public.job_assignment_outcomes o join public.job_assignments a on a.id=o.assignment_id,public.qual_leads l
where x.outcome_id=o.id and x.lead_id=l.id and x.source_date is null;

alter table public.qual_leads add column if not exists service_confirmed boolean not null default true;

create table if not exists public.qual_assignment_intake(
 id uuid not null unique default gen_random_uuid(),
 outcome_id uuid primary key references public.job_assignment_outcomes(id) on delete cascade,
 team_id uuid references public.qual_teams(id) on delete set null,
 state text not null default 'review' check(state in ('review','linked')),
 reason text not null default 'legacy_review',
 can_create boolean not null default false,
 first_seen_at timestamptz not null default clock_timestamp(),
 updated_at timestamptz not null default clock_timestamp(),
 detail text
);
alter table public.qual_assignment_intake enable row level security;
drop policy if exists qual_assignment_intake_read on public.qual_assignment_intake;
create policy qual_assignment_intake_read on public.qual_assignment_intake for select to authenticated using(public.is_bridge_member());
revoke all on public.qual_assignment_intake from public,anon,authenticated;
grant select on public.qual_assignment_intake to authenticated;
insert into public.qual_assignment_intake(outcome_id,reason) select id,case when job_ref is null then 'missing_reference' else 'legacy_review' end from public.job_assignment_outcomes on conflict do nothing;

create or replace function public.qual_link_source_stamp() returns trigger language plpgsql security definer set search_path=public,auth as $$
begin
 select coalesce(o.job_ref,l.lead_ref),a.date,a.technician into new.source_job_ref,new.source_date,new.source_technician
 from public.job_assignment_outcomes o join public.job_assignments a on a.id=o.assignment_id join public.qual_leads l on l.id=new.lead_id where o.id=new.outcome_id;
 return new;
end $$;
drop trigger if exists qual_link_source_stamp_t on public.qual_assignment_links;
create trigger qual_link_source_stamp_t before insert on public.qual_assignment_links for each row execute function public.qual_link_source_stamp();

create or replace function public.qual_link_assignment_core(p_team uuid,p_outcome uuid,p_existing_lead uuid default null,p_job_ref text default null,p_service text default 'cleaning',p_territory text default null,p_mapping_note text default null)
returns public.qual_assignment_links language plpgsql security definer set search_path=public,auth as $$
declare src record; t public.qual_teams; l public.qual_leads; a public.qual_appointments; j public.qual_jobs; link public.qual_assignment_links; ref text; matched boolean; count_jobs integer; count_appts integer;
begin
 select o.*,ja.date,ja.technician into src from public.job_assignment_outcomes o join public.job_assignments ja on ja.id=o.assignment_id where o.id=p_outcome for update of o;
 if not found then raise exception 'Assigned visit no longer exists. Refresh Job Assignment.'; end if;
 select * into link from public.qual_assignment_links where outcome_id=p_outcome;
 if found then
  if link.team_id<>p_team or (p_existing_lead is not null and link.lead_id<>p_existing_lead) then raise exception 'This visit is already linked. Open its existing team record.'; end if;
  return link;
 end if;
 ref:=nullif(upper(btrim(coalesce(src.job_ref,p_job_ref))), '');
 if ref is null then raise exception 'Add the job reference once to identify this assignment.'; end if;
 if src.job_ref is not null and p_job_ref is not null and upper(btrim(p_job_ref))<>ref then raise exception 'The entered reference differs from Job Assignment. Correct the source reference first.'; end if;
 if length(ref)>80 then raise exception 'Job reference is too long.'; end if;
 perform pg_advisory_xact_lock(hashtextextended('qual-job:'||ref,0));
 select * into t from public.qual_teams where id=p_team for update;
 if not found or t.status in ('inactive','disqualified') then raise exception 'Choose a current team.'; end if;
 matched:=lower(btrim(coalesce(t.leader_name,'')))=lower(btrim(src.technician)) or exists(
 select 1 from public.qual_team_members m left join public.technicians tech on tech.id=m.technician_id where m.team_id=t.id and m.active_from<=src.date and (m.active_to is null or m.active_to>=src.date) and (lower(btrim(m.person_name))=lower(btrim(src.technician)) or lower(btrim(tech.name))=lower(btrim(src.technician))));
 if not matched and (not public.qual_is_manager() or coalesce(btrim(p_mapping_note),'')='') then raise exception 'Technician does not match this team on the assignment date. A manager must confirm the mapping with a reason.'; end if;
 if p_existing_lead is not null then
  perform pg_advisory_xact_lock(hashtextextended('qual-lead:'||p_existing_lead::text,0));
  select * into l from public.qual_leads where id=p_existing_lead and team_id=t.id for update;
  if not found then raise exception 'Existing opportunity must belong to this team.'; end if;
  if upper(btrim(l.lead_ref))<>ref and coalesce(btrim(p_mapping_note),'')='' then raise exception 'Explain why this is a return visit for the selected opportunity.'; end if;
 else
  if exists(select 1 from public.qual_leads where upper(btrim(lead_ref))=ref) then raise exception 'This job reference already has an opportunity. Select that existing record; do not create it again.'; end if;
  if p_service not in ('installation','cleaning','mixed','other') then raise exception 'Choose a service.'; end if;
  insert into public.qual_leads(team_id,lead_ref,source,territory,service,assigned_at,qualified)
  values(t.id,ref,'Job Assignment',p_territory,p_service,(src.date::timestamp+interval '12 hours') at time zone 'America/Los_Angeles',true) returning * into l;
 end if;
 select count(*) into count_jobs from public.qual_jobs where lead_id=l.id;
 if count_jobs>1 then raise exception 'This opportunity has multiple work records. Reconcile them before linking; no record was changed.'; end if;
 select * into j from public.qual_jobs where lead_id=l.id;
 -- Reuse a single matching older visit only after the caller explicitly chose its opportunity.
 select count(*) into count_appts from public.qual_appointments qa where qa.lead_id=l.id
 and (qa.scheduled_at at time zone 'America/Los_Angeles')::date=src.date
 and not exists(select 1 from public.qual_assignment_links x where x.appointment_id=qa.id)
 and ((src.outcome='completed' and qa.outcome in ('visited','attended','late')) or qa.outcome=case src.outcome when 'pending' then 'scheduled' else src.outcome end);
 if count_appts>1 then raise exception 'Multiple older visits match this date. Reconcile those visit records before linking.'; end if;
 if count_appts=1 then
  select * into a from public.qual_appointments qa where qa.lead_id=l.id
  and (qa.scheduled_at at time zone 'America/Los_Angeles')::date=src.date
  and not exists(select 1 from public.qual_assignment_links x where x.appointment_id=qa.id)
  and ((src.outcome='completed' and qa.outcome in ('visited','attended','late')) or qa.outcome=case src.outcome when 'pending' then 'scheduled' else src.outcome end) for update;
  if a.team_id<>t.id or (a.job_id is not null and a.job_id is distinct from j.id) then raise exception 'The older visit has a conflicting team or work record. Review it first.'; end if;
  if a.job_id is null and j.id is not null then update public.qual_appointments set job_id=j.id where id=a.id returning * into a;end if;
 else
 -- A finished visit does not establish a sale, punctual arrival, or completed work.
 insert into public.qual_appointments(team_id,lead_id,job_id,scheduled_at,territory,service,outcome,reason,schedule_time_known)
 values(t.id,l.id,j.id,(src.date::timestamp+interval '12 hours') at time zone 'America/Los_Angeles',l.territory,l.service,
 case src.outcome when 'completed' then 'visited' when 'cancelled' then 'cancelled' when 'rescheduled' then 'rescheduled' else 'scheduled' end,
 case when src.outcome in ('cancelled','rescheduled') then src.comment else null end,false) returning * into a;
 end if;
 insert into public.qual_assignment_links(outcome_id,team_id,lead_id,appointment_id,job_id,mapping_note,created_by)
 values(src.id,t.id,l.id,a.id,j.id,nullif(btrim(p_mapping_note),''),auth.email()) returning * into link;
 if src.job_ref is null then update public.job_assignment_outcomes set job_ref=ref where id=src.id;select * into link from public.qual_assignment_links where id=link.id;end if;
 insert into public.qual_audit(actor_email,table_name,row_id,action,detail) values(auth.email(),'qual_assignment_links',link.id::text,'LINK',to_jsonb(link));
 return link;
end $$;
revoke all on function public.qual_link_assignment_core(uuid,uuid,uuid,text,text,text,text) from public,anon,authenticated;

-- The manual endpoint keeps its role gate; the internal helper is never exposed.
create or replace function public.qual_link_assignment(p_team uuid,p_outcome uuid,p_existing_lead uuid default null,p_job_ref text default null,p_service text default 'cleaning',p_territory text default null,p_mapping_note text default null)
returns public.qual_assignment_links language plpgsql security definer set search_path=public,auth as $$
declare result public.qual_assignment_links;
begin
 if not public.is_bridge_member() then raise exception 'Sign in with a Bridge role.'; end if;
 result:=public.qual_link_assignment_core(p_team,p_outcome,p_existing_lead,p_job_ref,p_service,p_territory,p_mapping_note);
 update public.qual_assignment_intake set state='linked',reason='linked',team_id=result.team_id,detail=null,updated_at=clock_timestamp() where outcome_id=p_outcome;
 return result;
end $$;
revoke all on function public.qual_link_assignment(uuid,uuid,uuid,text,text,text,text) from public,anon;
grant execute on function public.qual_link_assignment(uuid,uuid,uuid,text,text,text,text) to authenticated;

create or replace function public.qual_assignment_candidates(p_assignment uuid) returns setof uuid
language sql stable security definer set search_path=public,auth as $$
 select t.id from public.qual_teams t join public.job_assignments a on a.id=p_assignment
 where t.status not in ('inactive','disqualified') and (t.active_from is null or t.active_from<=a.date) and (t.active_to is null or t.active_to>=a.date)
 and (lower(btrim(t.leader_name))=lower(btrim(a.technician)) or exists(
 select 1 from public.qual_team_members m left join public.technicians tech on tech.id=m.technician_id
 where m.team_id=t.id and m.approval_status='approved' and m.active_from<=a.date and (m.active_to is null or m.active_to>=a.date)
 and (lower(btrim(m.person_name))=lower(btrim(a.technician)) or lower(btrim(tech.name))=lower(btrim(a.technician)))))
$$;
revoke all on function public.qual_assignment_candidates(uuid) from public,anon,authenticated;

create or replace function public.qual_auto_process_assignment(p_outcome uuid) returns text
language plpgsql security definer set search_path=public,auth as $$
declare src record; intake public.qual_assignment_intake; link public.qual_assignment_links; t public.qual_teams;
 ref text; candidates uuid[]; leads uuid[]; existing uuid; why text; err text; started timestamptz; enabled boolean;
begin
 select o.*,a.date,a.technician into src from public.job_assignment_outcomes o join public.job_assignments a on a.id=o.assignment_id where o.id=p_outcome for update of o;
 if not found then return 'missing_source'; end if;
 insert into public.qual_assignment_intake(outcome_id) values(p_outcome) on conflict do nothing;
 select * into intake from public.qual_assignment_intake where outcome_id=p_outcome for update;
 select * into link from public.qual_assignment_links where outcome_id=p_outcome;
 if found then
  perform pg_advisory_xact_lock(hashtextextended('qual-lead:'||link.lead_id::text,0));
  if upper(btrim(coalesce(src.job_ref,''))) is distinct from upper(btrim(coalesce(link.source_job_ref,''))) or src.date is distinct from link.source_date or lower(btrim(src.technician)) is distinct from lower(btrim(link.source_technician)) then why:='source_changed';
  else
   if intake.reason='source_changed' then
    update public.qual_appointments set outcome=case src.outcome when 'completed' then case when outcome in ('attended','late') then outcome else 'visited' end when 'cancelled' then 'cancelled' when 'rescheduled' then 'rescheduled' else 'scheduled' end,
    reason=case when src.outcome in ('cancelled','rescheduled','other') then src.comment else reason end where id=link.appointment_id;
   end if;
   update public.qual_assignment_intake set state='linked',reason='linked',team_id=link.team_id,detail=null,updated_at=clock_timestamp() where outcome_id=p_outcome; return 'linked'; end if;
 else
  select s.enabled,s.started_at into enabled,started from public.qual_assignment_auto_settings s where id=true;
  select array_agg(c) into candidates from public.qual_assignment_candidates(src.assignment_id) c;
  if cardinality(candidates)=1 then select * into t from public.qual_teams where id=candidates[1]; end if;
  ref:=nullif(upper(btrim(src.job_ref)),'');
  if not coalesce(enabled,false) then why:='paused';
  elsif exists(select 1 from public.qual_assignment_links x join public.job_assignment_outcomes sibling on sibling.id=x.outcome_id where sibling.assignment_id=src.assignment_id and (x.source_date is distinct from src.date or lower(btrim(x.source_technician)) is distinct from lower(btrim(src.technician)))) then why:='source_changed';
  elsif ref is null then why:='missing_reference';
  elsif coalesce(cardinality(candidates),0)=0 then why:='team_not_found';
  elsif cardinality(candidates)>1 then why:='ambiguous_team';
  elsif not intake.can_create or src.date<(started at time zone 'America/Los_Angeles')::date then why:='legacy_review';
  else
   perform pg_advisory_xact_lock(hashtextextended('qual-job:'||ref,0));
   select array_agg(id) into leads from public.qual_leads where upper(btrim(lead_ref))=ref;
   if coalesce(cardinality(leads),0)>1 then why:='reference_conflict';
   elsif cardinality(leads)=1 then
    existing:=leads[1];
    if not exists(select 1 from public.qual_leads where id=existing and team_id=t.id) then why:='reference_conflict';
    elsif not exists(select 1 from public.qual_assignment_links where lead_id=existing) then why:='legacy_review';
    end if;
   end if;
   if why is null then
    begin
     link:=public.qual_link_assignment_core(t.id,src.id,existing,null,case when cardinality(t.services)=1 then t.services[1] else 'other' end,case when cardinality(t.territories)=1 then t.territories[1] else null end,null);
     update public.qual_assignment_links set link_method='automatic' where id=link.id;
     if existing is null then update public.qual_leads set service_confirmed=cardinality(t.services)=1 where id=link.lead_id;end if;
     update public.qual_assignment_intake set state='linked',reason='linked',team_id=t.id,detail=null,updated_at=clock_timestamp() where outcome_id=src.id;
     insert into public.qual_audit(actor_email,table_name,row_id,action,detail) values(auth.email(),'qual_assignment_links',link.id::text,'AUTO_LINK',jsonb_build_object('outcome_id',src.id,'reference',ref,'reused_opportunity',existing is not null));
     return 'linked';
    exception when others then get stacked diagnostics err=MESSAGE_TEXT; why:='sync_error'; end;
   end if;
  end if;
 end if;
 update public.qual_assignment_intake set state='review',reason=why,team_id=coalesce(link.team_id,t.id),detail=err,updated_at=clock_timestamp() where outcome_id=src.id;
 return why;
end $$;
revoke all on function public.qual_auto_process_assignment(uuid) from public,anon,authenticated;

create or replace function public.qual_auto_source_intake() returns trigger language plpgsql security definer set search_path=public,auth as $$
begin
 insert into public.qual_assignment_intake(outcome_id,can_create) values(new.id,tg_op='INSERT') on conflict do nothing;
 perform public.qual_auto_process_assignment(new.id);return new;
end $$;
drop trigger if exists qual_auto_source_intake_t on public.job_assignment_outcomes;
create trigger qual_auto_source_intake_t after insert or update of job_ref,outcome,comment on public.job_assignment_outcomes for each row execute function public.qual_auto_source_intake();

create or replace function public.qual_auto_assignment_change() returns trigger language plpgsql security definer set search_path=public,auth as $$
declare visits uuid[]; visit uuid;
begin
 select array_agg(id) into visits from (select id from public.job_assignment_outcomes where assignment_id=new.id order by seq for update skip locked) locked;
 foreach visit in array coalesce(visits,'{}'::uuid[]) loop perform public.qual_auto_process_assignment(visit);end loop;return new;
end $$;
drop trigger if exists qual_auto_assignment_change_t on public.job_assignments;
create trigger qual_auto_assignment_change_t after update of date,technician on public.job_assignments for each row when(old.date is distinct from new.date or old.technician is distinct from new.technician) execute function public.qual_auto_assignment_change();

create or replace function public.qual_sync_assignments(p_start date,p_end date) returns jsonb language plpgsql security definer set search_path=public,auth as $$
declare visits uuid[]; visit uuid; linked integer:=0; reviewed integer:=0; result text; enabled boolean;
begin
 if not public.is_bridge_member() then raise exception 'Sign in with a Bridge role.'; end if;
 if p_start is null or p_end is null or p_end<p_start or p_end-p_start>92 then raise exception 'Choose a reporting window of at most 93 days.'; end if;
 select s.enabled into enabled from public.qual_assignment_auto_settings s where id=true;
 select array_agg(id) into visits from (
 select o.id from public.job_assignment_outcomes o join public.job_assignments a on a.id=o.assignment_id left join public.qual_assignment_intake i on i.outcome_id=o.id
 where a.date between p_start and p_end and (i.state is null or i.state<>'linked' or exists(select 1 from public.qual_assignment_links x where x.outcome_id=o.id and (x.source_date is distinct from a.date or lower(btrim(x.source_technician)) is distinct from lower(btrim(a.technician)) or upper(btrim(x.source_job_ref)) is distinct from upper(btrim(o.job_ref)))))
 order by coalesce(i.can_create,false) desc,i.updated_at nulls first,a.date,o.seq,o.id limit 500 for update of o skip locked) locked;
 foreach visit in array coalesce(visits,'{}'::uuid[]) loop
  result:=public.qual_auto_process_assignment(visit);if result='linked' then linked:=linked+1;else reviewed:=reviewed+1;end if;
 end loop;
 return jsonb_build_object('enabled',coalesce(enabled,false),'linked',linked,'reviewed',reviewed);
end $$;
revoke all on function public.qual_sync_assignments(date,date) from public,anon;
grant execute on function public.qual_sync_assignments(date,date) to authenticated;
revoke all on function public.qual_link_source_stamp() from public,anon,authenticated;
revoke all on function public.qual_auto_source_intake() from public,anon,authenticated;
revoke all on function public.qual_auto_assignment_change() from public,anon,authenticated;
create or replace function public.qual_source_visit_sync() returns trigger
language plpgsql security definer set search_path=public,auth as $$
declare link public.qual_assignment_links; parent public.job_assignments;
begin
 select * into link from public.qual_assignment_links where outcome_id=new.id;
 if not found then return new; end if;
 select * into parent from public.job_assignments where id=new.assignment_id;
 if upper(btrim(coalesce(new.job_ref,''))) is distinct from upper(btrim(coalesce(link.source_job_ref,''))) or parent.date is distinct from link.source_date or lower(btrim(parent.technician)) is distinct from lower(btrim(link.source_technician)) then return new; end if;
 perform pg_advisory_xact_lock(hashtextextended('qual-lead:'||link.lead_id::text,0));
 if new.outcome is distinct from old.outcome or new.job_ref is distinct from old.job_ref then
  update public.qual_appointments set outcome=case new.outcome
    when 'completed' then case when outcome in ('attended','late') then outcome else 'visited' end
    when 'cancelled' then 'cancelled' when 'rescheduled' then 'rescheduled'
    when 'pending' then 'scheduled' else 'scheduled' end,
    reason=case when new.outcome in ('cancelled','rescheduled','other') then new.comment else reason end
  where id=link.appointment_id;
 end if;
 if new.comment is distinct from old.comment and new.outcome in ('cancelled','rescheduled','other') then update public.qual_appointments set reason=new.comment where id=link.appointment_id; end if;
 update public.qual_assignment_links set revision=revision+1,updated_at=clock_timestamp() where id=link.id;
 insert into public.qual_audit(actor_email,table_name,row_id,action,detail) values(auth.email(),'qual_assignment_links',link.id::text,'SOURCE_VISIT_UPDATE',jsonb_build_object('old_source',to_jsonb(old),'new_source',to_jsonb(new)));
 return new;
end $$;
create or replace function public.qual_save_linked_job(p_link uuid,p_revision bigint,p_action text,p_values jsonb)
returns public.qual_assignment_links language plpgsql security definer set search_path=public,auth as $$
declare link public.qual_assignment_links; l public.qual_leads; j public.qual_jobs; a public.qual_appointments; src public.job_assignment_outcomes; amount bigint; before_state jsonb; ev text; new_out text; origin text; n integer; parent public.job_assignments;
begin
 if not public.is_bridge_member() then raise exception 'Sign in with a Bridge role.'; end if;
 if jsonb_typeof(p_values)<>'object' then raise exception 'Values must be an object.'; end if;
 select * into link from public.qual_assignment_links where id=p_link;
 if not found then raise exception 'Unknown linked visit.'; end if;
 select * into src from public.job_assignment_outcomes where id=link.outcome_id for update;
 select * into parent from public.job_assignments where id=src.assignment_id;
 if upper(btrim(coalesce(src.job_ref,''))) is distinct from upper(btrim(coalesce(link.source_job_ref,''))) or parent.date is distinct from link.source_date or lower(btrim(parent.technician)) is distinct from lower(btrim(link.source_technician)) then raise exception 'Assigned visit identity changed. Review its source details before saving.';end if;
 perform pg_advisory_xact_lock(hashtextextended('qual-lead:'||link.lead_id::text,0));
 select * into l from public.qual_leads where id=link.lead_id for update;
 select * into link from public.qual_assignment_links where id=p_link for update;
 if p_revision is null or link.revision is distinct from p_revision then raise exception 'This job changed while the form was open. Refresh and review before saving.'; end if;
 select * into a from public.qual_appointments where id=link.appointment_id for update;
 select * into j from public.qual_jobs where id=link.job_id for update;
 before_state:=jsonb_build_object('lead',to_jsonb(l),'job',to_jsonb(j),'appointment',to_jsonb(a),'source_visit',to_jsonb(src));
 if p_action in ('estimate','sale') and not l.service_confirmed then
  if coalesce(p_values->>'service','') not in ('cleaning','installation','mixed','other') then raise exception 'Choose the service once for this job.';end if;
  update public.qual_leads set service=p_values->>'service',service_confirmed=true where id=l.id returning * into l;
 end if;
 if p_action='visit' then
  ev:=p_values->>'outcome';
  if ev is null or ev not in ('scheduled','visited','cancelled','attended','late','no_show','customer_reschedule','company_cancel','force_majeure') then raise exception 'Choose a visit outcome.'; end if;
  if ev in ('cancelled','no_show','customer_reschedule','company_cancel','force_majeure') and coalesce(btrim(p_values->>'reason'),'')='' then raise exception 'Record the visit reason.'; end if;
  if ev in ('attended','late') and not a.schedule_time_known and nullif(p_values->>'scheduled_at','') is null then raise exception 'Job Assignment records only the date. Enter the scheduled time before evaluating punctuality.'; end if;
  update public.qual_appointments set outcome=ev,schedule_time_known=case when nullif(p_values->>'scheduled_at','') is not null then true else schedule_time_known end,scheduled_at=coalesce(nullif(p_values->>'scheduled_at','')::timestamptz,scheduled_at),arrival_at=nullif(p_values->>'arrival_at','')::timestamptz,reason=nullif(btrim(p_values->>'reason'),'') where id=a.id;
  new_out:=case when ev in ('visited','attended','late') then 'completed' when ev='customer_reschedule' then 'rescheduled' when ev in ('cancelled','company_cancel','force_majeure') then 'cancelled' when ev='no_show' then 'other' else 'pending' end;
  update public.job_assignment_outcomes set outcome=new_out,comment=case when new_out in ('cancelled','rescheduled','other') then p_values->>'reason' else comment end,updated_by=auth.email() where id=src.id;
  -- Preserve the more specific attendance classification after the source trigger.
  update public.qual_appointments set outcome=ev,reason=nullif(btrim(p_values->>'reason'),'') where id=a.id;
 elsif p_action='estimate' then
  amount:=(p_values->>'price_cents')::bigint;
  if amount is null or amount<0 then raise exception 'Enter a nonnegative estimate amount.'; end if;
  select coalesce(max(version),0)+1 into n from public.qual_lead_estimates where lead_id=l.id;
  insert into public.qual_lead_estimates(lead_id,version,price_cents,presented_at) values(l.id,n,amount,coalesce(nullif(p_values->>'presented_at','')::timestamptz,now()));
  update public.qual_assignment_links set revision=revision+1,updated_at=clock_timestamp() where lead_id=l.id;
 elsif p_action='sale' then
  amount:=(p_values->>'revenue_cents')::bigint;
  if amount is null or amount<0 then raise exception 'Enter a nonnegative sale amount.'; end if;
  if l.status='cancelled' or j.cancelled then raise exception 'A cancelled opportunity must be reviewed before recording a sale.'; end if;
  if j.id is null then
   select count(*) into n from public.qual_jobs where lead_id=l.id;
   if n>1 then raise exception 'Multiple work records exist; reconcile them first.'; end if;
   select * into j from public.qual_jobs where lead_id=l.id for update;
  end if;
  if j.id is null then
   if nullif(p_values->>'promised_date','') is null then raise exception 'Enter the work promise date.'; end if;
   insert into public.qual_jobs(team_id,lead_id,job_ref,service,sold_at,promised_date,current_promise_date,revenue_cents)
   values(l.team_id,l.id,l.lead_ref,l.service,coalesce(nullif(p_values->>'sold_at','')::date,((coalesce(nullif(p_values->>'decision_at','')::timestamptz,now())) at time zone 'America/Los_Angeles')::date),(p_values->>'promised_date')::date,(p_values->>'promised_date')::date,amount) returning * into j;
   update public.qual_assignment_links set job_id=j.id,revision=revision+1,updated_at=clock_timestamp() where lead_id=l.id;
   update public.qual_appointments set job_id=j.id where id in(select appointment_id from public.qual_assignment_links where lead_id=l.id);
  else
   update public.qual_jobs set revenue_cents=amount where id=j.id;
  end if;
  update public.qual_lead_estimates set outcome='accepted' where id=(select id from public.qual_lead_estimates where lead_id=l.id order by version desc limit 1) and outcome='pending';
  update public.qual_leads set status='won',sold_revenue_cents=amount,decision_at=coalesce(nullif(p_values->>'decision_at','')::timestamptz,now()) where id=l.id;
 elsif p_action='decline' then
  if j.id is not null or l.status in ('won','cancelled') then raise exception 'Sold or cancelled work cannot be changed to a declined estimate. Use cancellation review.'; end if;
  if coalesce(btrim(p_values->>'reason'),'')='' then raise exception 'Record why the customer declined.'; end if;
  update public.qual_leads set status='declined',notes=p_values->>'reason',decision_at=now() where id=l.id;
 elsif p_action='failure' then
  if j.id is not null or l.status in ('won','cancelled') or coalesce(btrim(p_values->>'reason'),'')='' then raise exception 'Record a reason for a failed unsold opportunity; do not classify cancellation or sold work as a team failure.'; end if;
  update public.qual_leads set status='team_failed',failure_reason=p_values->>'reason',decision_at=now() where id=l.id;
 elsif p_action='collection' then
  amount:=(p_values->>'collected_revenue_cents')::bigint;
  if l.status<>'won' or amount is null or amount<0 then raise exception 'Record collections for a won opportunity using a nonnegative amount.'; end if;
  update public.qual_leads set collected_revenue_cents=amount where id=l.id;
 elsif p_action='work' then
  if j.id is null or j.cancelled or l.status<>'won' then raise exception 'Record the sale before completing work.'; end if;
  if nullif(p_values->>'completed_at','') is null or coalesce(btrim(p_values->>'completion_evidence'),'')='' then raise exception 'Record the completion time and evidence.'; end if;
  if ((p_values->>'completed_at')::timestamptz at time zone 'America/Los_Angeles')::date<j.sold_at then raise exception 'Work completion cannot precede the sale date.'; end if;
  if (p_values->>'completed_at')::timestamptz>now() then raise exception 'Work completion cannot be in the future.'; end if;
  update public.qual_jobs set completed_at=(p_values->>'completed_at')::timestamptz,completion_evidence=p_values->>'completion_evidence' where id=j.id;
 elsif p_action='reschedule' then
  if j.id is null or j.cancelled or j.completed_at is not null then raise exception 'Only unfinished sold work can be rescheduled.'; end if;
  if nullif(p_values->>'to_date','') is null or coalesce(btrim(p_values->>'reason'),'')='' or coalesce((p_values->>'customer_approved')::boolean,false) is false then raise exception 'Record the new date, reason and customer approval.'; end if;
  insert into public.qual_job_reschedules(job_id,from_date,to_date,reason,customer_approved) values(j.id,j.current_promise_date,(p_values->>'to_date')::date,p_values->>'reason',true);
 elsif p_action='costs' then
  if j.id is null or j.cancelled then raise exception 'Record the sale before entering work costs.'; end if;
  if jsonb_typeof(p_values->'costs')<>'array' then raise exception 'Costs must be an array.'; end if;
  if exists(select 1 from jsonb_array_elements(p_values->'costs') c where coalesce(c->>'category','')='' or coalesce(c->>'status','') not in ('actual','estimated','unknown') or (c->>'amount_cents' is not null and ((c->>'amount_cents')::numeric<0 or (c->>'amount_cents')::numeric<>trunc((c->>'amount_cents')::numeric)))) then raise exception 'Use valid cost categories, statuses and nonnegative whole cents.'; end if;
  update public.qual_jobs set costs=p_values->'costs' where id=j.id;
 elsif p_action='cancel' then
  origin:=p_values->>'origin'; ev:=nullif(btrim(p_values->>'reason'),'');
  if ev is null or origin is null or origin not in ('customer','company','team') then raise exception 'Record who cancelled and why.'; end if;
  if j.completed_at is not null then raise exception 'Completed work requires an incident or refund review, not cancellation.'; end if;
  update public.qual_leads set status='cancelled',cancel_reason=ev,cancellation_origin=origin,decision_at=now() where id=l.id;
  if j.id is not null then update public.qual_jobs set cancelled=true,cancel_reason=ev where id=j.id; end if;
  update public.job_assignment_outcomes set outcome='cancelled',comment=ev,updated_by=auth.email() where id=src.id;
  -- A cancellation never approves its own score exclusion.
  if origin in ('customer','company') then
   insert into public.qual_exclusions(team_id,source_table,source_id,category,reason,status)
   values(l.team_id,'qual_leads',l.id,case origin when 'customer' then 'customer_cancel_early' else 'company_cancel' end,ev,'pending') on conflict(source_table,source_id) do nothing;
  end if;
 else raise exception 'Unknown job action.';
 end if;
 insert into public.qual_audit(actor_email,table_name,row_id,action,detail) values(auth.email(),'qual_assignment_links',link.id::text,'UPDATE_'||upper(p_action),jsonb_build_object('values',p_values,'outcome_id',src.id,'before',before_state));
 select * into link from public.qual_assignment_links where id=p_link;
 return link;
end $$;

-- Exception review uses the existing dispatcher/manager roles.
create or replace function public.qual_set_assignment_reference(p_outcome uuid,p_reference text) returns text
language plpgsql security definer set search_path=public,auth as $$
declare ref text; link public.qual_assignment_links;
begin
 if not public.is_bridge_member() then raise exception 'Sign in with a Bridge role.';end if;
 ref:=nullif(upper(btrim(p_reference)),'');if ref is null or length(ref)>80 then raise exception 'Enter a job reference of at most 80 characters.';end if;
 select * into link from public.qual_assignment_links where outcome_id=p_outcome;
 if found and ref is distinct from upper(btrim(link.source_job_ref)) then raise exception 'Restore the original reference for this linked visit or review its mapping with the manager.';end if;
 update public.job_assignment_outcomes set job_ref=ref,updated_by=auth.email() where id=p_outcome;
 if not found then raise exception 'Assigned visit no longer exists.';end if;
 return public.qual_auto_process_assignment(p_outcome);
end $$;
revoke all on function public.qual_set_assignment_reference(uuid,text) from public,anon;
grant execute on function public.qual_set_assignment_reference(uuid,text) to authenticated;

create or replace function public.qual_confirm_assignment_team(p_outcome uuid,p_team uuid,p_reason text) returns text
language plpgsql security definer set search_path=public,auth as $$
declare src record; candidates uuid[]; roster uuid[];
begin
 if not public.qual_is_manager() then raise exception 'Only a manager confirms a technician team.';end if;
 if coalesce(btrim(p_reason),'')='' then raise exception 'Record why this is the technician team.';end if;
 select a.* into src from public.job_assignments a join public.job_assignment_outcomes o on o.assignment_id=a.id where o.id=p_outcome;
 if not found then raise exception 'Assigned visit no longer exists.';end if;
 if not exists(select 1 from public.qual_teams where id=p_team and status not in ('inactive','disqualified') and (active_from is null or active_from<=src.date) and (active_to is null or active_to>=src.date)) then raise exception 'Choose a team current on the assignment date.';end if;
 perform pg_advisory_xact_lock(hashtextextended('qual-technician:'||lower(btrim(src.technician)),0));
 select array_agg(c) into candidates from public.qual_assignment_candidates(src.id) c;
 if exists(select 1 from unnest(candidates) c where c<>p_team) then raise exception 'A different team already matches this technician. Reconcile its leader or roster before confirming another team.';end if;
 if coalesce(cardinality(candidates),0)=0 then
  select array_agg(id) into roster from public.qual_team_members where team_id=p_team and lower(btrim(person_name))=lower(btrim(src.technician)) and active_from<=src.date and (active_to is null or active_to>=src.date);
  if coalesce(cardinality(roster),0)>1 then raise exception 'Multiple roster entries match this technician. Reconcile them first.';end if;
  if cardinality(roster)=1 then update public.qual_team_members set approval_status='approved',note=p_reason where id=roster[1];
  else
  insert into public.qual_team_members(team_id,technician_id,person_name,active_from,approval_status,note)
  values(p_team,(select id from public.technicians where lower(btrim(name))=lower(btrim(src.technician)) limit 1),src.technician,src.date,'approved',p_reason);
  end if;
 end if;
 return public.qual_auto_process_assignment(p_outcome);
end $$;
revoke all on function public.qual_confirm_assignment_team(uuid,uuid,text) from public,anon;
grant execute on function public.qual_confirm_assignment_team(uuid,uuid,text) to authenticated;
notify pgrst,'reload schema';
commit;
