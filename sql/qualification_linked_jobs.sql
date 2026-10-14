-- Apply after qualification_schema.sql and job_assignment_outcomes.sql.
-- Links existing assigned visits; no backfill, score/decision rewrite, or new anon grants.
begin;
alter table public.qual_leads drop constraint if exists qual_leads_status_check;
alter table public.qual_leads add constraint qual_leads_status_check check(status in ('pending','won','declined','team_failed','cancelled'));
alter table public.qual_leads add column if not exists cancel_reason text;
alter table public.qual_leads add column if not exists cancellation_origin text;
alter table public.qual_leads drop constraint if exists qual_lead_cancellation_check;
alter table public.qual_leads add constraint qual_lead_cancellation_check check(status <> 'cancelled' or (coalesce(btrim(cancel_reason),'') <> '' and coalesce(cancellation_origin,'') in ('customer','company','team')));
alter table public.qual_appointments drop constraint if exists qual_appointments_outcome_check;
alter table public.qual_appointments add constraint qual_appointments_outcome_check check(outcome in ('scheduled','visited','rescheduled','attended','late','no_show','cancelled','customer_reschedule','company_cancel','force_majeure'));

alter table public.qual_appointments add column if not exists schedule_time_known boolean not null default true;
alter table public.qual_appointments drop constraint if exists qual_appointment_timing_check;
alter table public.qual_appointments add constraint qual_appointment_timing_check check(schedule_time_known or outcome not in ('attended','late'));

create table if not exists public.qual_assignment_links(
 id uuid primary key default gen_random_uuid(),
 outcome_id uuid not null unique references public.job_assignment_outcomes(id) on delete restrict,
 team_id uuid not null references public.qual_teams(id) on delete restrict,
 lead_id uuid not null references public.qual_leads(id) on delete restrict,
 appointment_id uuid not null unique references public.qual_appointments(id) on delete restrict,
 job_id uuid references public.qual_jobs(id) on delete restrict,
 mapping_note text,
 revision bigint not null default 1,
 created_at timestamptz not null default now(), created_by text,
 updated_at timestamptz not null default now()
);
create index if not exists qual_assignment_links_lead_idx on public.qual_assignment_links(lead_id);
create index if not exists qual_assignment_links_job_idx on public.qual_assignment_links(job_id);
alter table public.qual_assignment_links enable row level security;
drop policy if exists qual_assignment_links_read on public.qual_assignment_links;
create policy qual_assignment_links_read on public.qual_assignment_links for select to authenticated using(public.is_bridge_member());
revoke all on public.qual_assignment_links from public,anon,authenticated;
grant select on public.qual_assignment_links to authenticated;
comment on table public.qual_assignment_links is 'An assigned visit linked once to its qualification opportunity, appointment and sold work. Return visits may share the same opportunity/work. Writes only through member RPCs.';

create or replace function public.qual_link_assignment(p_team uuid,p_outcome uuid,p_existing_lead uuid default null,p_job_ref text default null,p_service text default 'cleaning',p_territory text default null,p_mapping_note text default null)
returns public.qual_assignment_links language plpgsql security definer set search_path=public,auth as $$
declare src record; t public.qual_teams; l public.qual_leads; a public.qual_appointments; j public.qual_jobs; link public.qual_assignment_links; ref text; matched boolean; count_jobs integer;
begin
 if not public.is_bridge_member() then raise exception 'Sign in with a Bridge role.'; end if;
 select o.*,ja.date,ja.technician into src from public.job_assignment_outcomes o join public.job_assignments ja on ja.id=o.assignment_id where o.id=p_outcome for update of o;
 if not found then raise exception 'Assigned visit no longer exists. Refresh Job Assignment.'; end if;
 select * into link from public.qual_assignment_links where outcome_id=p_outcome;
 if found then
  if link.team_id<>p_team or (p_existing_lead is not null and link.lead_id<>p_existing_lead) then raise exception 'This visit is already linked. Open its existing team record.'; end if;
  return link;
 end if;
 select * into t from public.qual_teams where id=p_team for update;
 if not found or t.status in ('inactive','disqualified') then raise exception 'Choose a current team.'; end if;
 matched:=lower(btrim(coalesce(t.leader_name,'')))=lower(btrim(src.technician)) or exists(
 select 1 from public.qual_team_members m left join public.technicians tech on tech.id=m.technician_id where m.team_id=t.id and m.active_from<=src.date and (m.active_to is null or m.active_to>=src.date) and (lower(btrim(m.person_name))=lower(btrim(src.technician)) or lower(btrim(tech.name))=lower(btrim(src.technician))));
 if not matched and (not public.qual_is_manager() or coalesce(btrim(p_mapping_note),'')='') then raise exception 'Technician does not match this team on the assignment date. A manager must confirm the mapping with a reason.'; end if;
 ref:=nullif(upper(btrim(coalesce(src.job_ref,p_job_ref))), '');
 if ref is null then raise exception 'Add the job reference once to identify this assignment.'; end if;
 if src.job_ref is not null and p_job_ref is not null and upper(btrim(p_job_ref))<>ref then raise exception 'The entered reference differs from Job Assignment. Correct the source reference first.'; end if;
 if length(ref)>80 then raise exception 'Job reference is too long.'; end if;
 perform pg_advisory_xact_lock(hashtextextended('qual-job:'||ref,0));
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
 -- A finished visit does not establish a sale, punctual arrival, or completed work.
 insert into public.qual_appointments(team_id,lead_id,job_id,scheduled_at,territory,service,outcome,reason,schedule_time_known)
 values(t.id,l.id,j.id,(src.date::timestamp+interval '12 hours') at time zone 'America/Los_Angeles',l.territory,l.service,
 case src.outcome when 'completed' then 'visited' when 'cancelled' then 'cancelled' when 'rescheduled' then 'rescheduled' else 'scheduled' end,
 case when src.outcome in ('cancelled','rescheduled') then src.comment else null end,false) returning * into a;
 insert into public.qual_assignment_links(outcome_id,team_id,lead_id,appointment_id,job_id,mapping_note,created_by)
 values(src.id,t.id,l.id,a.id,j.id,nullif(btrim(p_mapping_note),''),auth.email()) returning * into link;
 if src.job_ref is null then update public.job_assignment_outcomes set job_ref=ref where id=src.id;select * into link from public.qual_assignment_links where id=link.id;end if;
 insert into public.qual_audit(actor_email,table_name,row_id,action,detail) values(auth.email(),'qual_assignment_links',link.id::text,'LINK',to_jsonb(link));
 return link;
end $$;
revoke all on function public.qual_link_assignment(uuid,uuid,uuid,text,text,text,text) from public,anon;
grant execute on function public.qual_link_assignment(uuid,uuid,uuid,text,text,text,text) to authenticated;

-- Changes in Job Assignment update the linked visit only, never a sale or work completion.
create or replace function public.qual_source_visit_sync() returns trigger
language plpgsql security definer set search_path=public,auth as $$
declare link public.qual_assignment_links;
begin
 select * into link from public.qual_assignment_links where outcome_id=new.id;
 if not found then return new; end if;
 perform pg_advisory_xact_lock(hashtextextended('qual-lead:'||link.lead_id::text,0));
 if new.outcome is distinct from old.outcome then
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
drop trigger if exists qual_source_visit_sync_t on public.job_assignment_outcomes;
create trigger qual_source_visit_sync_t after update of outcome,comment,job_ref on public.job_assignment_outcomes for each row
 when (old.outcome is distinct from new.outcome or old.comment is distinct from new.comment or old.job_ref is distinct from new.job_ref) execute function public.qual_source_visit_sync();

-- Related-record edits invalidate an open unified form, including edits from legacy views.
create or replace function public.qual_link_touch() returns trigger
language plpgsql security definer set search_path=public,auth as $$
begin
 update public.qual_assignment_links set revision=revision+1,updated_at=clock_timestamp()
 where (tg_table_name='qual_leads' and lead_id=new.id) or (tg_table_name='qual_jobs' and job_id=new.id) or (tg_table_name='qual_appointments' and appointment_id=new.id);
 return new;
end $$;
drop trigger if exists qual_link_touch_t on public.qual_leads;
create trigger qual_link_touch_t after update on public.qual_leads for each row execute function public.qual_link_touch();
drop trigger if exists qual_link_touch_t on public.qual_jobs;
create trigger qual_link_touch_t after update on public.qual_jobs for each row execute function public.qual_link_touch();
drop trigger if exists qual_link_touch_t on public.qual_appointments;
create trigger qual_link_touch_t after update on public.qual_appointments for each row execute function public.qual_link_touch();

create or replace function public.qual_link_identity_guard() returns trigger
language plpgsql security definer set search_path=public,auth as $$
begin
 if tg_table_name='qual_jobs' and exists(select 1 from public.qual_assignment_links where lead_id=(to_jsonb(new)->>'lead_id')::uuid) then
  if exists(select 1 from public.qual_jobs j where j.lead_id=(to_jsonb(new)->>'lead_id')::uuid and j.id<>new.id) then raise exception 'This linked opportunity already has its work record. Open that record instead of creating another.'; end if;
  if not exists(select 1 from public.qual_leads l where l.id=(to_jsonb(new)->>'lead_id')::uuid and l.team_id=new.team_id) then raise exception 'Linked work belongs to the opportunity team.'; end if;
 end if;
 if exists(select 1 from public.qual_assignment_links x where
 (tg_table_name='qual_leads' and x.lead_id=old.id and (new.team_id<>old.team_id or to_jsonb(new)->'lead_ref' is distinct from to_jsonb(old)->'lead_ref')) or
 (tg_table_name='qual_jobs' and x.job_id=old.id and (new.team_id<>old.team_id or to_jsonb(new)->'lead_id' is distinct from to_jsonb(old)->'lead_id' or to_jsonb(new)->'job_ref' is distinct from to_jsonb(old)->'job_ref')) or
 (tg_table_name='qual_appointments' and x.appointment_id=old.id and (new.team_id<>old.team_id or to_jsonb(new)->'lead_id' is distinct from to_jsonb(old)->'lead_id' or (x.job_id is not null and (to_jsonb(new)->>'job_id')::uuid is distinct from x.job_id))))
 then raise exception 'Linked identity cannot be changed. Review the assignment mapping instead.'; end if;
 return new;
end $$;
drop trigger if exists qual_link_identity_guard_t on public.qual_leads;
create trigger qual_link_identity_guard_t before update on public.qual_leads for each row execute function public.qual_link_identity_guard();
drop trigger if exists qual_link_identity_guard_t on public.qual_jobs;
create trigger qual_link_identity_guard_t before insert or update on public.qual_jobs for each row execute function public.qual_link_identity_guard();
drop trigger if exists qual_link_identity_guard_t on public.qual_appointments;
create trigger qual_link_identity_guard_t before update on public.qual_appointments for each row execute function public.qual_link_identity_guard();

-- One action, one transaction. Only supplied fields change; costs and history survive other actions.
create or replace function public.qual_save_linked_job(p_link uuid,p_revision bigint,p_action text,p_values jsonb)
returns public.qual_assignment_links language plpgsql security definer set search_path=public,auth as $$
declare link public.qual_assignment_links; l public.qual_leads; j public.qual_jobs; a public.qual_appointments; src public.job_assignment_outcomes; amount bigint; before_state jsonb; ev text; new_out text; origin text; n integer;
begin
 if not public.is_bridge_member() then raise exception 'Sign in with a Bridge role.'; end if;
 if jsonb_typeof(p_values)<>'object' then raise exception 'Values must be an object.'; end if;
 select * into link from public.qual_assignment_links where id=p_link;
 if not found then raise exception 'Unknown linked visit.'; end if;
 select * into src from public.job_assignment_outcomes where id=link.outcome_id for update;
 perform pg_advisory_xact_lock(hashtextextended('qual-lead:'||link.lead_id::text,0));
 select * into l from public.qual_leads where id=link.lead_id for update;
 select * into link from public.qual_assignment_links where id=p_link for update;
 if p_revision is null or link.revision is distinct from p_revision then raise exception 'This job changed while the form was open. Refresh and review before saving.'; end if;
 select * into a from public.qual_appointments where id=link.appointment_id for update;
 select * into j from public.qual_jobs where id=link.job_id for update;
 before_state:=jsonb_build_object('lead',to_jsonb(l),'job',to_jsonb(j),'appointment',to_jsonb(a),'source_visit',to_jsonb(src));
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
revoke all on function public.qual_save_linked_job(uuid,bigint,text,jsonb) from public,anon;
grant execute on function public.qual_save_linked_job(uuid,bigint,text,jsonb) to authenticated;
-- Trigger helpers are not callable endpoints.
revoke all on function public.qual_source_visit_sync() from public,anon,authenticated;
revoke all on function public.qual_link_touch() from public,anon,authenticated;
revoke all on function public.qual_link_identity_guard() from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
