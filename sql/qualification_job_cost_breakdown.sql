-- Apply after the existing Qualification migrations. Existing cost histories are untouched.
-- Only cost rows explicitly saved with this calculation marker use the technician share.
begin;
create or replace function public.qual_job_cost_breakdown_guard() returns trigger
language plpgsql set search_path=public as $$
declare pay jsonb; item jsonb; rate numeric; expenses numeric:=0; basis numeric; amount numeric; unknown_expense boolean:=false; total numeric;
begin
 if not exists(select 1 from jsonb_array_elements(new.costs) c where c->>'calculation'='adc_technician_share_v1') then return new;end if;
 if (select count(*) from jsonb_array_elements(new.costs) c where c->>'category'='technician_pay')<>1
 or (select count(*) from jsonb_array_elements(new.costs) c where c->>'calculation'='adc_technician_share_v1')<>1 then
  raise exception 'Save one technician pay calculation for this job.';
 end if;
 select c into pay from jsonb_array_elements(new.costs) c where c->>'calculation'='adc_technician_share_v1';
 if pay->>'category'<>'technician_pay' or pay->>'basis' is distinct from 'after_materials_assistant' then raise exception 'Technician pay uses the sale less materials and assistant expenses.';end if;
 rate:=(pay->>'rate_pct')::numeric;
 if rate is null or rate<0 or rate>100 or rate*100<>trunc(rate*100) then raise exception 'Enter a technician percentage from 0 to 100 with at most two decimal places.';end if;
 if coalesce(pay->>'pay_status','') not in ('actual','estimated') then raise exception 'Choose actual or estimated costs.';end if;
 for item in select c from jsonb_array_elements(new.costs) c loop
  if jsonb_typeof(item)<>'object' or coalesce(btrim(item->>'category'),'')='' or coalesce(item->>'status','') not in ('actual','estimated','unknown') then raise exception 'Use a named cost with a valid cost status.';end if;
  if item->>'calculation'='adc_technician_share_v1' then continue;end if;
  amount:=(item->>'amount_cents')::numeric;
  if amount is not null and (amount<0 or amount<>trunc(amount) or amount>9007199254740991) then raise exception 'Costs must be nonnegative whole cents.';end if;
  if item->>'category' in ('materials','assistant') then
   if item->>'status'='unknown' or amount is null then unknown_expense:=true;else expenses:=expenses+amount;end if;
  end if;
 end loop;
 if new.revenue_cents is null or unknown_expense then basis:=null;amount:=null;
 else basis:=greatest(new.revenue_cents-expenses,0);amount:=round(basis*rate/100);end if;
 pay:=pay||jsonb_build_object('basis_cents',basis,'amount_cents',amount,'status',case when amount is null then 'unknown' else pay->>'pay_status' end);
 select jsonb_agg(case when c->>'calculation'='adc_technician_share_v1' then pay else c end order by n) into new.costs from jsonb_array_elements(new.costs) with ordinality a(c,n);
 -- A changed total invalidates an older allocation instead of showing stale service margins.
 if new.service='mixed' and jsonb_array_length(new.service_mix)>0 then
  select sum((c->>'amount_cents')::numeric) into total from jsonb_array_elements(new.costs) c;
  if amount is null or exists(select 1 from jsonb_array_elements(new.costs) c where c->>'status'='unknown' or c->>'amount_cents' is null)
   or (select sum((c->>'revenue_cents')::numeric) from jsonb_array_elements(new.service_mix) c) is distinct from new.revenue_cents::numeric
   or (select sum((c->>'cost_cents')::numeric) from jsonb_array_elements(new.service_mix) c) is distinct from total then new.service_mix:='[]';end if;
 end if;
 return new;
end $$;
drop trigger if exists qj_cost_breakdown_t on public.qual_jobs;
create trigger qj_cost_breakdown_t before insert or update of costs,revenue_cents on public.qual_jobs for each row execute function public.qual_job_cost_breakdown_guard();
revoke all on function public.qual_job_cost_breakdown_guard() from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
