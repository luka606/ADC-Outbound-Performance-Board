/* In-memory stand-in for supabase-js v2 with the M2 Bridge's database rules emulated
   (bridge_schema.sql triggers), plus auth + rpc. Same query-builder shape as fake-supabase.js. */
(function(root){
function makeFake(db, opts){
  opts=opts||{}; const uid=()=>'id-'+Math.random().toString(36).slice(2,10); const now=()=>new Date().toISOString();
  let S=null, listeners=[]; const email=()=>S&&S.user&&S.user.email||null;
  const roleOf=()=>{const r=(db.bridge_roles||[]).find(x=>x.email===email());return r?r.role:null;};
  const isMgr=()=>roleOf()==='manager';
  const cfg=k=>{const r=(db.bridge_config||[]).find(x=>x.key===k);return r?r.value:undefined;};
  const ev=(opp,kind,from,to,payload)=>{
    if(opp!=null&&!(db.bridge_opportunities||[]).some(r=>String(r.id)===String(opp)))
      throw new Error('insert or update on table "bridge_events" violates foreign key constraint "bridge_events_opportunity_id_fkey"');
    db.bridge_events.push({id:db.bridge_events.length+1,opportunity_id:opp,at:now(),actor_email:email(),kind,from_status:from??null,to_status:to??null,payload:payload||null});};
  const setStatus=(oppId,st)=>{const o=db.bridge_opportunities.find(x=>x.id===oppId);if(!o||o.status===st)return;const f=o.status;o.status=st;o.updated_at=now();ev(oppId,'status',f,st);};
  const ERR=m=>({data:null,error:{message:m}});
  const GATED=new Set(['visit_authorized','work_released','actuals_reconciled']);
  // per-table rule emulation. returns error string or null; may mutate `row` (the row as it will be stored)
  // Foreign keys the real schema declares. The dispatcher's lead was rejected in production by exactly
  // one of these (bridge_events.opportunity_id) because an event was written from a BEFORE INSERT
  // trigger, before its parent row existed — so the fake enforces them.
  const FK={bridge_events:['opportunity_id','bridge_opportunities'],bridge_assignments:['opportunity_id','bridge_opportunities'],
    bridge_estimates:['opportunity_id','bridge_opportunities'],bridge_economics:['opportunity_id','bridge_opportunities'],
    bridge_requests:['opportunity_id','bridge_opportunities'],bridge_approvals:['opportunity_id','bridge_opportunities'],
    bridge_actuals:['opportunity_id','bridge_opportunities']};
  function fkCheck(t,row){
    const fk=FK[t]; if(!fk) return null;
    const [col,parent]=fk; const v=row[col];
    if(v==null) return null;
    if(!(db[parent]||[]).some(r=>String(r.id)===String(v)))
      return `insert or update on table "${t}" violates foreign key constraint "${t}_${col}_fkey"`;
    return null;
  }
  function before(t,op,row,old){
    if(!(t.startsWith('bridge_')))return null;
    if(!email())return 'permission denied (anon)';
    if(op==='insert'){row.created_by=email();row.created_at=row.created_at||now();
      // column defaults, as bridge_schema.sql declares them
      const D={bridge_opportunities:{status:'intake',urgent:false,indicators:[],expected_revenue_unknown:false,program:'M2 bridge'},bridge_assignments:{installer_approved:false,helpers:[]},
        bridge_estimates:{customer_accepted:false,discounts_cents:0,scope:[]},bridge_economics:{status:'draft',validation_issues:[],costs:[],service_split:[]},bridge_requests:{urgent:false,submitted_at:now()},
        bridge_actuals:{reconciled:false,actual_costs:[]},bridge_coverage_register:{accepted:false},bridge_comp_agreements:{status:'draft',components:[],version:1}}[t]||{};
      for(const k in D)if(row[k]===undefined)row[k]=JSON.parse(JSON.stringify(D[k]));}
    row.updated_by=email();row.updated_at=now();
    if(t==='bridge_config'&&!isMgr())return 'new row violates row-level security policy for table "bridge_config"';
    if(t==='bridge_opportunities'){ if(op==='insert'){row.seq=(db.__seq=(db.__seq||0)+1);row.status=row.status||'intake';row.program='M2 bridge';}
      if(op==='update'&&row.status!==old.status){ if(GATED.has(row.status)&&!db.__internal)return `${row.status} is reached only through an approval or reconciliation, not by editing the job.`;
        if(row.status==='lost'&&!String(row.loss_reason||'').trim())return 'A lost opportunity needs a loss reason (brief §7: losses by reason).';
        if(['declined','cancelled','lost'].includes(row.status)&&!row.outcome)row.outcome=row.status; } }
    if(t==='bridge_comp_agreements'){ if(op==='update'&&old.status==='approved'&&!(row.status==='superseded'))return 'An approved agreement is immutable. Create a new version and supersede this one.';
      if(row.status==='approved'&&(op==='insert'||old.status!=='approved')){ if(!isMgr())return 'Only the manager can approve an agreement.'; if(!(row.components||[]).length)return 'An agreement needs at least one component.'; if(row.route==='combined'&&row.deduction_categories==null)return 'The combined-route deduction list is unresolved (brief §9.1). Set it explicitly before approving.'; row.approved_by=email();row.approved_at=now(); } }
    if(t==='bridge_assignments'){ if(row.installer_approved&&(op==='insert'||!old.installer_approved)){ if(!isMgr())return 'Only the manager can approve an installer (brief §3.3; approver proposed: Luka).'; if(!String(row.installer_name||'').trim())return 'Name the installer before approving.'; row.installer_approved_by=email();row.installer_approved_at=now(); } if(!row.installer_approved){row.installer_approved_by=null;row.installer_approved_at=null;} }
    if(t==='bridge_estimates'&&op==='update'){ const strip=r=>{const c={...r};['customer_accepted','customer_accepted_at','updated_at','updated_by'].forEach(k=>delete c[k]);return JSON.stringify(c);}; if(strip(row)!==strip(old))return 'An estimate version is never edited. Create a new version.'; if(row.customer_accepted&&!old.customer_accepted)row.customer_accepted_at=row.customer_accepted_at||now(); }
    if(t==='bridge_economics'){ if(op==='update'&&old.status==='approved'&&row.status!=='superseded')return 'An approved economics version is immutable. Save a new version.';
      if(row.job_level_comp_approved_by&&(op==='insert'||!old.job_level_comp_approved_by)){ if(!isMgr())return 'Only the manager can approve a job-level compensation amount.'; if(row.job_level_comp_cents==null||!String(row.job_level_comp_note||'').trim())return 'A job-level amount needs the amount and a note stating inclusions, payer and scope (brief §9).'; row.job_level_comp_approved_by=email();row.job_level_comp_approved_at=now(); }
      if(row.status==='approved'&&(op==='insert'||old.status!=='approved')){ if(!isMgr())return 'Only the manager can approve an economics version.'; if((row.validation_issues||[]).length)return 'This version has validation issues and cannot be approved: '+JSON.stringify(row.validation_issues); if(!row.gate||row.gate==='invalid')return 'This version is not computable and cannot be approved.'; if(!(row.r_cents>0))return 'Zero revenue gives no valid margin (brief §4).'; row.approved_by=email();row.approved_at=now(); db.bridge_economics.filter(e=>e.opportunity_id===row.opportunity_id&&e.status==='approved'&&e.id!==row.id).forEach(e=>e.status='superseded'); } }
    if(t==='bridge_requests'&&op==='update'){ if(row.submitted_at!==old.submitted_at)return 'submitted_at is the first submission and cannot change.'; if(old.decided_at&&!db.__internal&&(row.decided_at!==old.decided_at||row.decision!==old.decision))return 'A decided request is not edited. Submit a new request.'; }
    if(t==='bridge_actuals'){ if(row.reconciled&&(op==='insert'||!old.reconciled)){ if(!isMgr())return 'Only the manager reconciles a job.'; if(row.final_revenue_cents==null)return 'Final revenue is required to reconcile.'; if((row.actual_costs||[]).some(c=>c.status==='unknown'))return 'An actual cost is still unknown — it does not count as zero.'; row.reconciled_by=email();row.reconciled_at=now(); } }
    if(t==='bridge_coverage_register'){ if(row.accepted&&(op==='insert'||!old.accepted)){ if(!isMgr())return 'Only the manager accepts coverage.'; if(!String(row.primary_name||'').trim()||!String(row.backup_name||'').trim())return 'Acceptance needs a primary and a backup.'; if(row.primary_name.trim().toLowerCase()===row.backup_name.trim().toLowerCase())return 'Primary and backup must be different people.'; row.accepted_by=email();row.accepted_at=now(); } if(!row.accepted){row.accepted_by=null;row.accepted_at=null;} }
    if(t==='bridge_approvals'){ if(op!=='insert')return 'permission denied for table bridge_approvals'; row.actor_email=email();row.actor_role=roleOf();row.at=now();
      if(row.actor_role!=='manager')return 'Only the manager can record approvals, holds, rejections or exceptions.';
      const opp=db.bridge_opportunities.find(o=>o.id===row.opportunity_id); if(!opp)return 'Unknown opportunity';
      if(row.type==='margin_exception'){ if(row.on_behalf_of!=='Sardor')return "A margin exception is recorded on Sardor's behalf (on_behalf_of = 'Sardor')."; if(!row.confirmed_via||!String(row.confirmation_ref||'').trim())return "Sardor's confirmation is required: how (text / call) and a reference to it."; if(row.economics_version==null)return 'Name the economics version the exception applies to.'; row.decision='record';row.confirmed_at=row.confirmed_at||now(); return null; }
      if(row.type==='work_release'&&row.decision==='approve'){ if(row.economics_version==null)return 'Release must name the economics version it approves.';
        const econ=db.bridge_economics.find(e=>e.opportunity_id===opp.id&&e.version===row.economics_version); if(!econ)return `Economics version ${row.economics_version} does not exist.`;
        if(econ.status!=='approved')return `Economics version ${row.economics_version} is not approved — approve it first, or fix its issues.`;
        if(econ.gate==='invalid'||(econ.validation_issues||[]).length)return 'Economics are incomplete; the job stays on hold (brief §5B.4).';
        if(econ.gate==='below_floor'&&!db.bridge_approvals.some(a=>a.opportunity_id===opp.id&&a.type==='margin_exception'&&a.economics_version===row.economics_version))return `Margin is below its floor. Renegotiate, or record Sardor's exception for version ${row.economics_version} first (brief §5B.5).`;
        if((econ.costs||[]).some(c=>c.status==='unknown'))return 'A cost is still unknown. Unknown is not zero (brief §4).';
        const est=db.bridge_estimates.find(e=>e.id===econ.estimate_id); if(!est)return `Economics version ${row.economics_version} is not tied to an estimate version.`;
        if(!est.customer_accepted)return `The customer has not accepted estimate v${est.version}. Acceptance and internal release are both required (brief §5B.1).`;
        const rules=cfg('service_rules')||{}; for(const s of new Set((est.scope||[]).map(x=>x.service))){ if(!s||s==='other'||!rules[s])return `Service "${s||'(none)'}" has no margin rule. Classify it and set its rule in Settings before release (brief §3.4).`; }
        const asg=db.bridge_assignments.filter(a=>a.opportunity_id===opp.id).sort((a,b)=>b.version-a.version)[0]; if(!asg)return 'No assignment: name who performs the work.';
        if(econ.route==='sagi'){ if(!asg.installer_approved)return 'Sagi-route installer is not approved (brief §3.3).'; if(econ.job_level_comp_cents!=null){ if(!econ.job_level_comp_approved_by)return "Sagi's job-level compensation amount is not approved."; } else if(econ.agreement_id){ const ag=db.bridge_comp_agreements.find(a=>a.id===econ.agreement_id); if(!ag||ag.status!=='approved'||ag.route!=='sagi')return "Sagi's compensation agreement is not approved."; } else return "Sagi's compensation is unresolved: an explicit approved job-level amount is required before release (brief §2, §9.2)."; }
        else { if(!String(asg.performing_technician||'').trim())return 'Name the performing technician.'; if(econ.job_level_comp_cents==null){ const ag=db.bridge_comp_agreements.find(a=>a.id===econ.agreement_id); if(!ag||ag.status!=='approved')return 'The combined-route compensation agreement is not approved (deduction list unresolved — brief §9.1).'; } else if(!econ.job_level_comp_approved_by)return 'The job-level compensation amount is not approved.'; }
      } }
    return null;
  }
  function after(t,op,row,old){
    if(t==='bridge_opportunities'){ if(op==='insert')ev(row.id,'created',null,row.status); else if(row.status!==old.status&&!row.__evd)ev(row.id,'status',old.status,row.status); }
    if(t==='bridge_economics'&&op==='insert'&&row.status==='draft'){ const o=db.bridge_opportunities.find(x=>x.id===row.opportunity_id); if(o&&(o.status==='work_released'||o.status==='in_progress')){db.__internal=1;setStatus(o.id,'economics_review');db.__internal=0;ev(o.id,'release_invalidated',null,null,{economics_version:row.version});} }
    if(t==='bridge_requests'&&op==='insert'){ const o=db.bridge_opportunities.find(x=>x.id===row.opportunity_id); db.__internal=1; if(row.type==='visit_approval'&&['intake','on_hold'].includes(o.status))setStatus(o.id,'visit_approval_pending'); if(row.type==='work_release'&&!['work_released','in_progress','completed','actuals_reconciled','declined','cancelled','lost','economics_review'].includes(o.status))setStatus(o.id,'economics_review'); db.__internal=0; }
    if(t==='bridge_approvals'&&op==='insert'){ db.__internal=1; if(row.request_id){const r=db.bridge_requests.find(x=>x.id===row.request_id); if(r&&!r.decided_at){r.decided_at=row.at;r.decision=['visit_approval','work_release'].includes(row.type)?'approve':row.decision;r.decided_by=row.actor_email;}}
      const to=row.type==='visit_approval'&&row.decision==='approve'?'visit_authorized':row.type==='work_release'&&row.decision==='approve'?'work_released':row.type==='hold'?'on_hold':row.type==='reject'?'declined':row.type==='reopen'?'economics_review':null; if(to)setStatus(row.opportunity_id,to); db.__internal=0;
      ev(row.opportunity_id,'approval',null,null,{type:row.type,decision:row.decision,economics_version:row.economics_version,reason:row.reason,on_behalf_of:row.on_behalf_of,confirmed_via:row.confirmed_via,confirmation_ref:row.confirmation_ref}); }
    if(t==='bridge_actuals'){ db.__internal=1; if(row.reconciled&&(op==='insert'||!old.reconciled))setStatus(row.opportunity_id,'actuals_reconciled'); else if(row.completed_at&&(op==='insert'||!old.completed_at)){const o=db.bridge_opportunities.find(x=>x.id===row.opportunity_id); if(o&&['work_released','in_progress'].includes(o.status))setStatus(o.id,'completed');} db.__internal=0; }
  }
  class Q{
    constructor(t){this.t=t;this.op='select';this.f=[];this.single=false;this.payload=null;this.conflict=[];this.lim=null;this.sorts=[];}
    select(){return this;} insert(p){this.op='insert';this.payload=p;return this;} update(p){this.op='update';this.payload=p;return this;}
    upsert(p,o){this.op='upsert';this.payload=p;this.conflict=String((o&&o.onConflict)||'').split(',').map(x=>x.trim()).filter(Boolean);return this;}
    delete(){this.op='delete';return this;} eq(k,v){this.f.push(r=>String(r[k])===String(v));return this;} neq(k,v){this.f.push(r=>String(r[k])!==String(v));return this;}
    gte(k,v){this.f.push(r=>r[k]>=v);return this;} lte(k,v){this.f.push(r=>r[k]<=v);return this;} lt(k,v){this.f.push(r=>r[k]<v);return this;} gt(k,v){this.f.push(r=>r[k]>v);return this;}
    in(k,vs){this.f.push(r=>vs.map(String).includes(String(r[k])));return this;} is(k,v){this.f.push(r=>v===null?r[k]==null:r[k]===v);return this;}
    order(k,o){this.sorts.push([k,!(o&&o.ascending===false)]);return this;} limit(n){this.lim=n;return this;} maybeSingle(){this.single=true;return this;}
    _rows(){return (db[this.t]||[]).filter(r=>this.f.every(fn=>fn(r)));}
    _run(){
      if(!(this.t in db))return ERR(`Could not find the table 'public.${this.t}' in the schema cache`);
      if(this.t.startsWith('bridge_')&&!email())return ERR('permission denied (anon)');
      if(this.t==='bridge_events'&&this.op!=='select')return ERR('permission denied for table bridge_events');
      let data=null;
      if(this.op==='select'){data=this._rows().slice();for(const [k,asc] of this.sorts.slice().reverse())data.sort((a,b)=>{const x=a[k]??'',y=b[k]??'';return (x<y?-1:x>y?1:0)*(asc?1:-1);});if(this.lim!=null)data=data.slice(0,this.lim);if(this.single)data=data[0]||null;}
      else if(this.op==='insert'){const arr=Array.isArray(this.payload)?this.payload:[this.payload];const out=[];for(const p of arr){const r={id:uid(),...p};const err=before(this.t,'insert',r,null)||fkCheck(this.t,r);if(err)return ERR(err);db[this.t].push(r);try{after(this.t,'insert',r,null);}catch(ex){db[this.t].pop();return ERR(String(ex.message||ex));}out.push(r);}data=out;}
      else if(this.op==='update'){const rows=this._rows();const staged=[];for(const r of rows){const nr={...r,...this.payload};const err=before(this.t,'update',nr,r);if(err)return ERR(err);staged.push([r,nr]);}staged.forEach(([r,nr])=>{const old={...r};Object.assign(r,nr);after(this.t,'update',r,old);});data=rows;}
      else if(this.op==='upsert'){const arr=Array.isArray(this.payload)?this.payload:[this.payload];const out=[];for(const p of arr){const hit=(db[this.t]||[]).find(r=>this.conflict.length&&this.conflict.every(k=>String(r[k])===String(p[k])));if(hit){const nr={...hit,...p};const err=before(this.t,'update',nr,hit);if(err)return ERR(err);const old={...hit};Object.assign(hit,nr);after(this.t,'update',hit,old);out.push(hit);}else{const r={id:uid(),...p};const err=before(this.t,'insert',r,null);if(err)return ERR(err);db[this.t].push(r);after(this.t,'insert',r,null);out.push(r);}}data=out;}
      else if(this.op==='delete'){return ERR('permission denied (no delete)');}
      return {data,error:null};
    }
    then(res,rej){return Promise.resolve().then(()=>this._run()).then(res,rej);}
  }
  const auth={
    getSession:async()=>({data:{session:S},error:null}),
    onAuthStateChange(cb){listeners.push(cb);return {data:{subscription:{unsubscribe(){listeners=listeners.filter(x=>x!==cb);}}}};},
    signInWithOtp:async({email:e})=>{db.__otp=e;return {data:{},error:null};},
    signOut:async()=>{S=null;listeners.forEach(cb=>cb('SIGNED_OUT',null));return {error:null};},
    __set(session){S=session;listeners.forEach(cb=>cb(session?'SIGNED_IN':'SIGNED_OUT',session));}
  };
  async function rpc(name,args){
    args=args||{};
    if(name==='bridge_role')return {data:roleOf(),error:null};
    if(name==='is_bridge_member')return {data:!!roleOf(),error:null};
    if(name==='grant_bridge'){ if(email()&&!isMgr())return ERR('Not authorised. Only the Bridge manager can grant a role.'); const e=String(args.target_email||'').trim().toLowerCase(); if(!e.includes('@'))return ERR('Enter an email address.'); const u=(db.__users||[]).find(x=>x.email===e); if(!u)return ERR(`No account for ${e}. Create it first: Supabase → Authentication → Users → Add user (Auto Confirm), then grant it here.`); const ex=db.bridge_roles.find(r=>r.email===e); if(ex)ex.role=args.target_role; else db.bridge_roles.push({user_id:u.id,email:e,role:args.target_role,added_at:now(),added_by:email()}); return {data:`${e} is a Bridge ${args.target_role} from their next sign-in.`,error:null}; }
    if(name==='revoke_bridge'){ if(email()&&!isMgr())return ERR('Not authorised. Only the Bridge manager can revoke a role.'); const e=String(args.target_email||'').trim().toLowerCase(); if(!db.bridge_roles.some(r=>r.role==='manager'&&r.email!==e))return ERR('Refusing: that would leave the Bridge with no manager. Grant another manager first.'); db.bridge_roles=db.bridge_roles.filter(r=>r.email!==e); return {data:`${e} no longer has the Bridge.`,error:null}; }
    return ERR('unknown rpc '+name);
  }
  return {from:t=>new Q(t),auth,rpc,__db:db};
}
root.__makeFakeBridge=makeFake;
if(typeof module!=='undefined'&&module.exports)module.exports={makeFake};
})(typeof globalThis!=='undefined'?globalThis:this);
