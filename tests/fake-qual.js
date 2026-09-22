/* In-memory stand-in for supabase-js v2 with the M4 qualification database rules emulated
   (qualification_schema.sql triggers + RLS), plus auth + rpc('bridge_role'). Same builder shape as fake-bridge.js. */
(function(root){
function makeFake(db){
  const uid=()=>'id-'+Math.random().toString(36).slice(2,10); const now=()=>new Date().toISOString();
  const todayPT=()=>{const d=new Date(new Date().toLocaleString('en-US',{timeZone:'America/Los_Angeles'}));return `${d.getFullYear()}-${String(d.getMonth()+1).padStart(2,'0')}-${String(d.getDate()).padStart(2,'0')}`;};
  let S=null, listeners=[]; const email=()=>S&&S.user&&S.user.email||null;
  const roleOf=()=>{const r=(db.bridge_roles||[]).find(x=>x.email===email());return r?r.role:null;};
  const isMgr=()=>roleOf()==='manager'; const ERR=m=>({data:null,error:{message:m}}); const blank=s=>String(s==null?'':s).trim()==='';
  const audit=(t,row,op)=>{(db.qual_audit=db.qual_audit||[]).push({id:db.qual_audit.length+1,at:now(),actor_email:email(),table_name:t,row_id:row.id,action:op});};
  const MGR_ONLY=new Set(['qual_metric_versions','qual_restrictions']);
  const INSERT_ONLY=new Set(['qual_snapshots','qual_decisions','qual_job_reschedules','qual_reviews']);
  const D={qual_metric_versions:{status:'draft',gates:[],critical_events:[],used_in_decision:false},qual_teams:{status:'prospective',team_type:'candidate',former_technician:false,territories:[],services:[],entry_review:{}},
    qual_team_members:{role:'technician',credentials:[],approval_status:'pending'},qual_availability:{available:true,retroactive:false},qual_leads:{service:'cleaning',qualified:true,status:'pending'},qual_lead_estimates:{outcome:'pending'},
    qual_appointments:{outcome:'scheduled'},qual_jobs:{service:'cleaning',service_mix:[],costs:[],cancelled:false},qual_coverage_events:{response:'pending',eligible:false,eligibility:{},fulfilled:false},qual_quality_events:{severity:'low',substantiation:'pending',status:'open'},
    qual_compliance_checks:{critical:false,result:'missing'},qual_exclusions:{status:'pending'},qual_supervised_jobs:{notes:{}},qual_incidents:{status:'suspected'},qual_restrictions:{kind:'no_new_assignments',affects_core_coverage:false},qual_actions:{status:'open'},qual_reviews:{kind:'weekly'}};
  function validateVersion(v){const cats=v.categories||[];if(!Array.isArray(cats)||!cats.length)return 'categories must be a non-empty array';let total=0;const seen=new Set();
    for(const c of cats){if(!c.key)return 'Category has no key';if(seen.has(c.key))return `Duplicate category key ${c.key}`;seen.add(c.key);if(c.weight_pct==null)return `Category ${c.key} has no weight_pct`;total+=Number(c.weight_pct);
      const b=c.bands||{};const p100=Number(b.p100),p70=Number(b.p70),p40=Number(b.p40);if([p100,p70,p40].some(isNaN))return `Category ${c.key}: bands need p100, p70 and p40 thresholds`;
      const dir=c.direction||'higher';if(dir==='higher'&&!(p100>p70&&p70>p40))return `Category ${c.key}: bands overlap or leave a gap — for a higher-is-better metric p100 > p70 > p40 is required (got ${p100}, ${p70}, ${p40})`;
      if(dir==='lower'&&!(p100<p70&&p70<p40))return `Category ${c.key}: bands overlap or leave a gap — for a lower-is-better metric p100 < p70 < p40 is required (got ${p100}, ${p70}, ${p40})`;}
    if(Math.abs(total-100)>1e-9)return `Category weights total ${total} — they must total exactly 100 (brief §4.1, §16.2). Nothing is normalised silently.`;return null;}
  function before(t,op,row,old){
    if(!t.startsWith('qual_'))return null;
    if(!email())return 'permission denied (anon)';
    if(t==='qual_audit')return 'permission denied for table qual_audit';
    if(op!=='insert'&&INSERT_ONLY.has(t))return `permission denied for table ${t}`;
    if(MGR_ONLY.has(t)&&!isMgr())return `new row violates row-level security policy for table "${t}"`;
    if(t==='qual_exclusions'&&op==='update'&&!isMgr())return 'new row violates row-level security policy for table "qual_exclusions"';
    if((t==='qual_snapshots'||t==='qual_decisions')&&!isMgr())return `new row violates row-level security policy for table "${t}"`;
    if(op==='insert'){row.created_by=email();row.created_at=row.created_at||now();const d=D[t]||{};for(const k in d)if(row[k]===undefined)row[k]=JSON.parse(JSON.stringify(d[k]));}
    if(op==='update'&&t!=='qual_snapshots'){row.updated_by=email();row.updated_at=now();}
    if(t==='qual_metric_versions'){
      if(op==='update'){if(old.used_in_decision){const strip=r=>{const c={...r};['status','updated_at','updated_by','used_in_decision'].forEach(k=>delete c[k]);return JSON.stringify(c);};if(!(row.status==='superseded'&&strip(row)===strip(old)))return `Version ${old.version} has been used in an official decision and is immutable. Create a new version; this one can only be superseded (brief §9, §16.18).`;}
        if(old.status==='superseded'&&row.status!=='superseded')return 'A superseded version is not reactivated. Create a new version.';}
      const e=validateVersion(row);if(e)return e;
      if(row.status==='active'&&(op==='insert'||old.status!=='active')){if(!isMgr())return 'Only the manager activates a metric version (brief §11).';if(blank(row.change_note))return 'Activation needs a change note (brief §10.5).';row.approved_by=email();row.approved_at=now();row.activated_at=now();row.effective_from=row.effective_from||todayPT();db.qual_metric_versions.filter(v=>v.status==='active'&&v.id!==row.id).forEach(v=>v.status='superseded');}
      if(op==='insert'&&db.qual_metric_versions.some(v=>v.version===row.version))return 'duplicate key value violates unique constraint "qual_metric_versions_version_key"';}
    if(t==='qual_teams'){if(op==='insert')row.seq=(db.__tseq=(db.__tseq||0)+1);
      if(row.entry_review_complete_at&&(op==='insert'||!old.entry_review_complete_at)){if(!isMgr())return 'Only the manager completes an entry review (brief §8.A, §11).';row.entry_reviewed_by=email();}
      if(op==='update'&&['active','disqualified'].includes(row.status)&&old.status!==row.status&&!db.__internal)return `A team becomes ${row.status} only through an official decision (brief §7). Record the decision; the status follows.`;}
    if(t==='qual_team_members'){if(row.approval_status==='approved'&&(op==='insert'||old.approval_status!=='approved')){if(!isMgr())return 'Only the manager approves a team member (brief §11).';row.approved_by=email();row.approved_at=now();}if(row.approval_status!=='approved'){row.approved_by=null;row.approved_at=null;}}
    if(t==='qual_availability'){
      if(op==='update'){if(old.locked_at&&!db.__internal)return 'This availability row is locked — an offer was already made against it. Record a correction as a new row with a reason (brief §13).';if(row.avail_date!==old.avail_date||row.team_id!==old.team_id)return 'Move availability by adding a new row, not by editing the date.';}
      if(op==='insert'){row.submitted_at=now();row.retroactive=row.avail_date<todayPT();const offers=(db.qual_coverage_events||[]).filter(e=>e.team_id===row.team_id&&e.job_date===row.avail_date).length;
        if(offers>0||row.supersedes){if(blank(row.change_reason))return `Offers already exist for ${row.avail_date} — a later availability change needs a reason and the manager's approval. Eligibility already recorded on those offers does not change.`;if(!isMgr())return 'Only the manager approves an availability change after offers were made (brief §11).';row.approved_by=email();row.approved_at=now();}}}
    if(t==='qual_leads'){if(op==='update'&&row.assigned_at!==old.assigned_at)return 'assigned_at is the assignment cohort and never moves (brief §4.2).';if(row.status!=='pending'&&!row.decision_at)row.decision_at=now();
      if(row.status==='won'&&row.sold_revenue_cents==null)return 'new row for relation "qual_leads" violates check constraint "ql_won_needs_revenue"';if(row.status==='team_failed'&&blank(row.failure_reason))return 'new row for relation "qual_leads" violates check constraint "ql_failed_needs_reason"';}
    if(t==='qual_lead_estimates'&&op==='update'){if(row.price_cents!==old.price_cents||row.version!==old.version||row.lead_id!==old.lead_id)return 'An estimate version is never edited — add the next version (brief §4.2). Only its outcome may change.';}
    if(t==='qual_lead_estimates'&&op==='insert'&&db.qual_lead_estimates.some(e=>e.lead_id===row.lead_id&&e.version===row.version))return 'duplicate key value violates unique constraint "qual_lead_estimates_lead_id_version_key"';
    if(t==='qual_appointments'&&['customer_reschedule','company_cancel','force_majeure'].includes(row.outcome)&&blank(row.reason))return 'new row for relation "qual_appointments" violates check constraint "qap_excl_needs_reason"';
    if(t==='qual_jobs'){if(op==='insert')row.current_promise_date=row.promised_date;if(op==='update'){if(row.promised_date!==old.promised_date)return 'The original promise date is immutable — record a customer-approved reschedule instead (brief §4.2).';if(row.current_promise_date!==old.current_promise_date&&!db.__internal)return 'The promise date moves only through a recorded reschedule (qual_job_reschedules).';}
      if(row.cancelled&&blank(row.cancel_reason))return 'new row for relation "qual_jobs" violates check constraint "qj_cancel_needs_reason"';}
    if(t==='qual_coverage_events'){
      if(op==='update'){if(row.eligible!==old.eligible||JSON.stringify(row.eligibility)!==JSON.stringify(old.eligibility)||row.job_date!==old.job_date||row.team_id!==old.team_id||(row.territory||'')!==(old.territory||'')||(row.service||'')!==(old.service||'')||row.offered_at!==old.offered_at)return 'The offer and its eligibility are frozen at the time it was made. Only the response, contact and fulfilment fields change.';}
      else{row.offered_at=row.offered_at||now();const tm=db.qual_teams.find(x=>x.id===row.team_id);if(!tm)return 'insert or update on table "qual_coverage_events" violates foreign key constraint "qual_coverage_events_team_id_fkey"';
        const terrOk=row.territory==null||!(tm.territories||[]).length||tm.territories.includes(row.territory);const svcOk=row.service==null||!(tm.services||[]).length||tm.services.includes(row.service);
        const avOk=(db.qual_availability||[]).some(a=>a.team_id===row.team_id&&a.avail_date===row.job_date&&a.available&&!a.retroactive&&a.submitted_at<=row.offered_at&&(a.territory==null||row.territory==null||a.territory===row.territory)&&(a.service==null||row.service==null||a.service===row.service));
        const reasons=[];if(!terrOk)reasons.push('outside approved territory');if(!svcOk)reasons.push('outside service capability');if(!avOk)reasons.push('no availability declared before the offer for this date');
        row.eligible=terrOk&&svcOk&&avOk;row.eligibility={territory_ok:terrOk,service_ok:svcOk,availability_ok:avOk,reasons,evaluated_at:now()};
        if(row.coverage_log_id&&db.qual_coverage_events.some(e=>e.team_id===row.team_id&&e.coverage_log_id===row.coverage_log_id))return 'duplicate key value violates unique constraint "qual_coverage_events_team_id_coverage_log_id_key"';}
      row.fulfilled=row.response==='accepted'&&row.contact_met===true;
      if(['declined','no_response','reassigned'].includes(row.response)&&blank(row.failure_reason))return `A ${row.response} needs its reason recorded separately (brief §4.2).`;}
    if(t==='qual_quality_events'){if(row.substantiation!=='pending'&&(op==='insert'||old.substantiation==='pending')&&!isMgr())return 'Only the manager rules a customer issue substantiated or unsubstantiated (brief §11).';row.closed_at=row.status==='closed'?(row.closed_at||now()):null;if(!db.qual_jobs.some(j=>j.id===row.job_id))return 'insert or update on table "qual_quality_events" violates foreign key constraint "qual_quality_events_job_id_fkey"';}
    if(t==='qual_compliance_checks'&&row.result==='pass'&&blank(row.evidence))return 'new row for relation "qual_compliance_checks" violates check constraint "qcc_pass_needs_evidence"';
    if(t==='qual_exclusions'){if(op==='insert'){row.requested_by=email();row.requested_at=now();if(row.status!=='pending'&&!isMgr())return 'Only the manager approves an exclusion (brief §11). Submit it as pending.';if(db.qual_exclusions.some(x=>x.source_table===row.source_table&&x.source_id===row.source_id))return 'duplicate key value violates unique constraint "qual_exclusions_source_table_source_id_key"';}
      if(row.status!=='pending'&&(op==='insert'||old.status==='pending')){if(!isMgr())return 'Only the manager approves or rejects an exclusion (brief §11).';row.decided_by=email();row.decided_at=now();}
      if(op==='update'&&old.status!=='pending'&&row.status!==old.status)return 'A decided exclusion is not reopened. Request a new one.';if(blank(row.reason))return 'An exclusion needs a reason.';}
    if(t==='qual_supervised_jobs'&&row.reviewed_at&&(op==='insert'||!old.reviewed_at)){if(!isMgr())return 'Only the manager signs off a supervised job (brief §8.B).';if(!row.result)return 'Record the result before signing off.';row.reviewed_by=email();}
    if(t==='qual_incidents'){if(['confirmed','dismissed'].includes(row.status)&&(op==='insert'||!['confirmed','dismissed'].includes(old.status))){if(!isMgr())return 'Only the manager confirms or dismisses a critical event after documented review (brief §7, §11).';if(blank(row.review_note))return 'A confirmed or dismissed incident needs the review note.';row.reviewed_by=email();row.reviewed_at=now();}
      if(op==='update'&&['confirmed','dismissed'].includes(old.status)&&row.status!==old.status)return 'A reviewed incident is not reopened. Record a new incident.';}
    if(t==='qual_restrictions'){if(op==='insert'){row.imposed_by=email();row.imposed_at=now();row.lifted_at=null;row.lifted_by=null;}if(op==='update'&&row.lifted_at&&!old.lifted_at){if(blank(row.lift_reason))return 'Lifting a restriction needs a reason (brief §13: overrides carry reason, actor, time).';row.lifted_by=email();row.lifted_at=now();}}
    if(t==='qual_decisions'){
      if(!isMgr())return 'Only the manager records an official qualification decision (brief §7, §11).';
      const s=db.qual_snapshots.find(x=>x.id===row.snapshot_id);if(!s)return 'Unknown snapshot.';if(s.team_id!==row.team_id)return 'That snapshot belongs to another team.';
      const v=db.qual_metric_versions.find(x=>x.id===s.version_id);if(!v||v.status!=='active')return `The snapshot was computed with metric version ${v?v.version:'?'}, which is not the active version. Refresh the snapshot with the active version (brief §13: one version per official cycle).`;
      row.version_id=s.version_id;row.period_start=s.period_start;row.period_end=s.period_end;row.recommended_outcome=s.recommended_outcome;row.reviewer_email=email();row.reviewer_role=roleOf();row.decided_at=now();row.kind=row.kind||'official';
      if(blank(row.reason))return 'A decision needs a reason.';
      const gatesFailed=((s.computed||{}).gates||[]).filter(g=>g.passed===false).length;
      if(row.official_outcome==='pass'){if(s.evidence_state!=='decision_eligible')return `Pass refused: the team is ${s.evidence_state} — minimum evidence is not satisfied (brief §7, §16.6).`;if(s.weighted_score==null)return 'Pass refused: the weighted score is not definitive (a category is N/A or the revenue baseline is unresolved) (brief §13, §16.7).';if(gatesFailed)return `Pass refused: ${gatesFailed} critical gate(s) failed in the snapshot (brief §4, §16.5).`;
        const pm=Number((v.outcome_rules||{}).pass_min??80);if(Number(s.weighted_score)<pm)return `Pass refused: weighted score ${s.weighted_score} is below the Pass minimum ${pm}.`;if(((s.computed||{}).categories||[]).some(c=>c.points===0))return 'Pass refused: a category sits in the 0-point band (brief §7).';}
      if(['coaching','probation'].includes(row.official_outcome)&&(blank(row.issue)||blank(row.action_text)||blank(row.action_owner)||!row.action_due||!row.next_review_date))return `${row.official_outcome[0].toUpperCase()+row.official_outcome.slice(1)} requires a named issue, a corrective action, an owner, a due date and a next review date (brief §7, §16.20).`;}
    if(t==='qual_actions'){if(row.status!=='open'&&(op==='insert'||old.status==='open')){if(!isMgr())return 'Only the manager closes a corrective action after reviewing its completion evidence (brief §12).';if(row.status==='done'&&blank(row.completion_evidence))return 'Closing an action needs completion evidence.';row.closed_by=email();row.closed_at=now();}if(row.status==='open'){row.closed_by=null;row.closed_at=null;}}
    return null;
  }
  function after(t,op,row,old){
    if(t==='qual_job_reschedules'&&op==='insert'){db.__internal=1;const j=db.qual_jobs.find(x=>x.id===row.job_id);if(j)j.current_promise_date=row.to_date;db.__internal=0;}
    if(t==='qual_coverage_events'&&op==='insert'){db.__internal=1;(db.qual_availability||[]).forEach(a=>{if(a.team_id===row.team_id&&a.avail_date===row.job_date&&!a.locked_at)a.locked_at=now();});db.__internal=0;}
    if(t==='qual_decisions'&&op==='insert'){db.__internal=1;const v=db.qual_metric_versions.find(x=>x.id===row.version_id);if(v)v.used_in_decision=true;
      if(['coaching','probation'].includes(row.official_outcome))db.qual_actions.push({id:uid(),team_id:row.team_id,decision_id:row.id,metric_key:row.issue,action:row.action_text,owner:row.action_owner,due_date:row.action_due,next_review_date:row.next_review_date,status:'open',created_at:now(),created_by:email()});
      const tm=db.qual_teams.find(x=>x.id===row.team_id);if(tm){if(row.official_outcome==='pass'){tm.status='active';tm.active_from=tm.active_from||row.period_end;}if(row.official_outcome==='disqualify'){tm.status='disqualified';tm.active_to=tm.active_to||todayPT();}}db.__internal=0;}
    if(['qual_metric_versions','qual_teams','qual_team_members','qual_availability','qual_exclusions','qual_incidents','qual_restrictions','qual_decisions','qual_actions'].includes(t))audit(t,row,op.toUpperCase());
  }
  class Qb{
    constructor(t){this.t=t;this.op='select';this.f=[];this.one=false;this.payload=null;this.lim=null;this.sorts=[];}
    select(){return this;} insert(p){this.op='insert';this.payload=p;return this;} update(p){this.op='update';this.payload=p;return this;} delete(){this.op='delete';return this;}
    eq(k,v){this.f.push(r=>String(r[k])===String(v));return this;} neq(k,v){this.f.push(r=>String(r[k])!==String(v));return this;} in(k,vs){this.f.push(r=>vs.map(String).includes(String(r[k])));return this;} is(k,v){this.f.push(r=>v===null?r[k]==null:r[k]===v);return this;}
    gte(k,v){this.f.push(r=>r[k]>=v);return this;} lte(k,v){this.f.push(r=>r[k]<=v);return this;} order(k,o){this.sorts.push([k,!(o&&o.ascending===false)]);return this;} limit(n){this.lim=n;return this;} single(){this.one=true;return this;} maybeSingle(){this.one=true;return this;}
    _rows(){return (db[this.t]||[]).filter(r=>this.f.every(fn=>fn(r)));}
    _run(){
      if(!(this.t in db))return ERR(`Could not find the table 'public.${this.t}' in the schema cache`);
      if((this.t.startsWith('qual_')||this.t.startsWith('bridge_'))&&!email())return ERR('permission denied (anon)');
      let data=null;
      if(this.op==='select'){data=this._rows().slice();for(const [k,asc] of this.sorts.slice().reverse())data.sort((a,b)=>{const x=a[k]??'',y=b[k]??'';return (x<y?-1:x>y?1:0)*(asc?1:-1);});if(this.lim!=null)data=data.slice(0,this.lim);if(this.one)data=data[0]||null;}
      else if(this.op==='insert'){const arr=Array.isArray(this.payload)?this.payload:[this.payload];const out=[];for(const p of arr){const r={id:uid(),...p};const err=before(this.t,'insert',r,null);if(err)return ERR(err);db[this.t].push(r);after(this.t,'insert',r,null);out.push(r);}data=this.one?out[0]:out;}
      else if(this.op==='update'){const rows=this._rows();const staged=[];for(const r of rows){const nr={...r,...this.payload};const err=before(this.t,'update',nr,r);if(err)return ERR(err);staged.push([r,nr]);}staged.forEach(([r,nr])=>{const old={...r};Object.assign(r,nr);after(this.t,'update',r,old);});data=this.one?rows[0]||null:rows;}
      else if(this.op==='delete'){if(!['qual_team_members','qual_availability'].includes(this.t))return ERR(`permission denied for table ${this.t}`);if(!email())return ERR('permission denied (anon)');const rows=this._rows();db[this.t]=db[this.t].filter(r=>!rows.includes(r));data=rows;}
      return {data,error:null};
    }
    then(res,rej){return Promise.resolve().then(()=>this._run()).then(res,rej);}
  }
  const auth={getSession:async()=>({data:{session:S},error:null}),onAuthStateChange(cb){listeners.push(cb);return {data:{subscription:{unsubscribe(){listeners=listeners.filter(x=>x!==cb);}}}};},
    signInWithOtp:async({email:e})=>{db.__otp=e;return {data:{},error:null};},signOut:async()=>{S=null;listeners.forEach(cb=>cb('SIGNED_OUT',null));return {error:null};},
    __set(session){S=session;listeners.forEach(cb=>cb(session?'SIGNED_IN':'SIGNED_OUT',session));}};
  async function rpc(name){if(name==='bridge_role')return {data:roleOf(),error:null};if(name==='is_bridge_member')return {data:!!roleOf(),error:null};if(name==='qual_is_manager')return {data:isMgr(),error:null};return ERR('unknown rpc '+name);}
  return {from:t=>new Qb(t),auth,rpc,__db:db};
}
root.__makeFakeQual=makeFake;
if(typeof module!=='undefined'&&module.exports)module.exports={makeFake};
})(typeof globalThis!=='undefined'?globalThis:this);
