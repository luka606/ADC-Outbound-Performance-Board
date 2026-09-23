/* M4 Team Qualification — acceptance tests (brief §16, numbered T1…T25) + database rules + page flows. Run: npm test */
const {JSDOM,VirtualConsole}=require('jsdom'); const fs=require('fs');
const {makeFake}=require('./fake-qual.js'); const {makeDb}=require('./seed-qual.js');
const html=fs.readFileSync(process.argv[2],'utf8');
const errors=[],cssWarn=[]; const vc=new VirtualConsole();
vc.on('jsdomError',e=>(/Could not parse CSS/.test(e.message)?cssWarn:errors).push('jsdomError: '+e.message.split('\n')[0]));
vc.on('error',(...a)=>errors.push('console.error: '+a.join(' '))); ['warn','log','info','debug'].forEach(k=>vc.on(k,()=>{}));
let db=makeDb(),fake=makeFake(db);
const dom=new JSDOM(html,{url:'http://localhost/qualification.html',runScripts:'dangerously',pretendToBeVisual:true,virtualConsole:vc,beforeParse(w){
  w.localStorage.setItem('adc_supabase_cfg',JSON.stringify({url:'http://fake.local',key:'fake'}));
  w.supabase={createClient:()=>fake}; w.confirm=()=>true; w.prompt=(m,d)=>w.__prompt?w.__prompt(m,d):(d||'test'); w.alert=()=>{}; w.scrollTo=()=>{};
  w.HTMLElement.prototype.scrollIntoView=function(){};
}});
const w=dom.window,d=w.document,$=s=>d.querySelector(s),$$=s=>[...d.querySelectorAll(s)];
const tick=(ms=40)=>new Promise(r=>setTimeout(r,ms));
let pass=0,fail=0; const T=(n,c,x)=>{if(c){pass++;console.log('  ✓',n);}else{fail++;console.log('  ✗',n,x!==undefined?JSON.stringify(x).slice(0,500):'');}};
const setv=(sel,v,root)=>{const e=(root||d).querySelector(sel);e.value=v;e.dispatchEvent(new w.Event('change',{bubbles:true}));}; const toast=()=>$('#toast').textContent;
const vis=sel=>{const e=$(sel);return !!e&&e.style.display!=='none';};
const signIn=email=>{fake.auth.__set({user:{id:'u',email}});};
const em=r=>r.error&&r.error.message||'';
(async()=>{
  await tick(80);
  const C=w.qualCompute,M=w.qualMargin,B=w.qualBand,VV=w.qualValidateVersion;
  const V0=JSON.parse(JSON.stringify(db.qual_metric_versions[0])); V0.status='active';
  const VB=JSON.parse(JSON.stringify(V0)); VB.revenue.baseline_cents={value:100000,status:'confirmed'};   // $1,000 per qualified lead
  const NOW='2026-09-23T20:00:00Z', P={start:'2026-08-27',end:'2026-09-23'};
  const team={id:'T1',name:'Fixture team',status:'provisional',team_type:'incumbent',territories:['LA'],services:['cleaning'],entry_review_complete_at:'2026-08-01T00:00:00Z'};
  let n=0; const id=p=>p+(++n);
  function fixture(o){ // a clean, decision-eligible team: 10 decided leads (6 won), full coverage/attendance/completion/compliance, 5 mature clean jobs
    o=o||{}; const leads=[],jobs=[],appts=[],cov=[],cc=[],qe=[],avail=[];
    const won=o.won??6,total=o.leads??10;
    for(let i=0;i<total;i++){const st=i<won?'won':(o.failStatus||'declined');leads.push({id:id('L'),team_id:'T1',lead_ref:'L'+i,service:'cleaning',territory:'LA',assigned_at:'2026-09-0'+((i%9)+1)+'T17:00:00Z',qualified:true,status:st,decision_at:'2026-09-15T00:00:00Z',sold_revenue_cents:st==='won'?(o.revenueEach??200000):null});}
    for(let i=0;i<(o.offers??20);i++){cov.push({id:id('C'),team_id:'T1',offered_at:'2026-09-10T15:00:00Z',job_date:'2026-09-12',eligible:true,eligibility:{},response:'accepted',contact_met:true,fulfilled:i<(o.fulfilled??(o.offers??20))});}
    for(let i=0;i<(o.appts??20);i++){appts.push({id:id('A'),team_id:'T1',scheduled_at:'2026-09-11T16:00:00Z',outcome:i<(o.attended??(o.appts??20))?'attended':'no_show',reason:o.noShowReason??null});}
    for(let i=0;i<(o.due??5);i++){jobs.push({id:id('J'),team_id:'T1',job_ref:'J'+i,service:'cleaning',promised_date:'2026-09-14',current_promise_date:'2026-09-14',completed_at:i<(o.completedOnTime??(o.due??5))?'2026-09-14T22:00:00Z':null,completion_evidence:'photo',revenue_cents:100000,costs:[{category:'materials',amount_cents:40000,status:'actual'}]});}
    for(let i=0;i<(o.matureJobs??5);i++){jobs.push({id:id('M'),team_id:'T1',job_ref:'M'+i,service:'cleaning',promised_date:'2026-08-10',current_promise_date:'2026-08-10',completed_at:'2026-08-10T20:00:00Z',completion_evidence:'photo',revenue_cents:100000,costs:[{category:'materials',amount_cents:40000,status:'actual'}]});}
    for(let i=0;i<(o.checks??10);i++){cc.push({id:id('K'),team_id:'T1',requirement:'start authorization',critical:i<3,result:'pass',evidence:'ref',checked_at:'2026-09-12T00:00:00Z'});}
    return {members:[],avail,leads,ests:o.ests||[],appts,jobs,resched:[],cov,qe:o.qe||[],cc,ex:o.ex||[],sup:[],inc:o.inc||[],res:o.res||[],snaps:[],dec:o.dec||[],act:[]};
  }
  const calc=(data,V,t)=>C({team:t||team,version:V||VB,period:P,now:NOW,data});
  const cat=(c,k)=>c.categories.find(x=>x.key===k);

  console.log('— engine: bands, weights, evidence, outcomes (brief §16) —');
  let c=calc(fixture());
  T('baseline team: all seven categories have points; weighted score definitive; decision eligible; recommended Pass',c.weighted_score===100&&c.evidence.state==='decision_eligible'&&c.recommended_outcome==='pass',{s:c.weighted_score,e:c.evidence,r:c.reasons});
  T('T1: every team is computed with the same version object (id carried into the result)',calc(fixture()).version.id===calc(fixture(),VB,{...team,id:'T1',team_type:'rebuilt'}).version.id);
  let bad=JSON.parse(JSON.stringify(VB)); bad.categories[0].weight_pct=19;
  T('T2: weights totalling 99 are rejected by the validator',VV(bad).some(e=>/must be exactly 100/.test(e)));
  bad=JSON.parse(JSON.stringify(VB)); bad.categories[0].bands.p70=50;
  T('T2: overlapping bands are rejected',VV(bad).some(e=>/overlap/.test(e)));
  c=calc(fixture({won:5})); T('T3: exactly 50% close rate → 100-point sales band',cat(c,'sales').value===50&&cat(c,'sales').points===100);
  c=calc(fixture({won:4})); T('T4: 40% close rate is not the passing band (70 points, below standard); recommended Coaching, not Pass',cat(c,'sales').points===70&&c.recommended_outcome==='coaching'&&c.below_passing.includes('sales'),c.reasons);
  c=calc(fixture({won:2})); T('T4: 20% close rate → 0-point band → Probation recommended even with a high score elsewhere',cat(c,'sales').points===0&&c.recommended_outcome==='probation',{s:c.weighted_score});
  { const f=fixture(); f.cc[0].result='fail'; c=calc(f);
    T('T5: score high but a critical compliance failure → gate fails, compliance 0 points, Pass not recommended',c.gates.find(g=>g.key==='critical_compliance').passed===false&&cat(c,'compliance').points===0&&c.recommended_outcome!=='pass',{r:c.recommended_outcome,reasons:c.reasons}); }
  c=calc(fixture({leads:4,won:3})); T('T6: 4 estimates (< 10) → Pending Evidence, recommended none, does not count toward the three',c.evidence.state==='pending_evidence'&&c.recommended_outcome==='pending'&&c.qualified_for_rock===false,c.evidence);
  c=calc(fixture({offers:0})); T('T7: zero eligible offers → coverage value N/A (null), no points, weighted score not definitive',cat(c,'coverage').value===null&&cat(c,'coverage').points===null&&c.weighted_score===null&&/N\/A/.test(cat(c,'coverage').notes[0]),cat(c,'coverage'));
  c=calc(fixture(),V0); T('§15: baseline unresolved → revenue shows $/lead but no points; score not definitive; official Pass blocked',cat(c,'revenue').points===null&&cat(c,'revenue').diagnostics.revenue_per_lead_cents===120000&&c.weighted_score===null&&c.recommended_outcome==='pending'&&c.warnings.some(x=>/baseline/.test(x)),cat(c,'revenue').notes);
  let m=M({service:'installation',revenue_cents:1000000,costs:[{category:'materials',amount_cents:null,status:'unknown'}]},VB.margin_rules);
  T('T8: an unknown cost gives no margin (null), with the reason — never zero',m.projected===null&&m.actual===null&&m.issues.some(x=>/unknown/.test(x)));
  m=M({service:'installation',revenue_cents:1000000,costs:[]},VB.margin_rules); T('T8: no costs recorded → margin not calculable, said so',m.projected===null&&m.issues.some(x=>/no costs/.test(x)));
  m=M({service:'installation',revenue_cents:1000000,costs:[{category:'materials',amount_cents:650000,status:'actual'}]},VB.margin_rules); T('T9: installation at exactly 35.00% is at the floor (not below); target 40 shown',m.below_floor===false&&m.floor_pct===35&&m.target_pct===40);
  m=M({service:'installation',revenue_cents:1000000,costs:[{category:'materials',amount_cents:650100,status:'actual'}]},VB.margin_rules); T('T9: installation 34.99% is below floor (integer comparison, unrounded)',m.below_floor===true);
  m=M({service:'cleaning',revenue_cents:1000000,costs:[{category:'materials',amount_cents:550000,status:'actual'}]},VB.margin_rules); T('T9: cleaning at 45.00% meets its own floor',m.below_floor===false&&m.floor_pct===45);
  m=M({service:'mixed',revenue_cents:1000000,costs:[{category:'materials',amount_cents:400000,status:'actual'}],service_mix:[{service:'installation',revenue_cents:600000,cost_cents:400000},{service:'cleaning',revenue_cents:400000,cost_cents:0}]},VB.margin_rules);
  T('T9: mixed job — installation component 33.3% below its floor, cleaning 100% fine → job flagged below floor',m.below_floor===true&&m.components[0].below_floor===true&&m.components[1].below_floor===false,m.components);
  { const f=fixture(); f.jobs[0].costs=[{category:'materials',amount_cents:700000,status:'actual'}]; f.jobs[0].revenue_cents=1000000; f.jobs[0].service='installation'; const c1=calc(f); f.jobs[0].margin_exception_ref='BR-appr-77'; const c2=calc(f); const mm=M(f.jobs[0],VB.margin_rules);
    T('T10: a Sardor exception stays visible as below-floor work and changes no category points or score',mm.below_floor===true&&mm.exception_ref==='BR-appr-77'&&c1.weighted_score===c2.weighted_score&&JSON.stringify(c1.categories.map(x=>x.points))===JSON.stringify(c2.categories.map(x=>x.points))); }
  { const f=fixture(); const L=f.leads[0].id; f.ests=[{id:'e1',lead_id:L,version:1,price_cents:100},{id:'e2',lead_id:L,version:2,price_cents:90},{id:'e3',lead_id:L,version:3,price_cents:80}]; c=calc(f);
    T('T11: three estimate versions on one lead → denominator still 10, estimate_versions diagnostic 3',cat(c,'sales').denominator===10&&cat(c,'revenue').denominator===10&&cat(c,'sales').diagnostics.estimate_versions===3); }
  { const f=fixture(); const J=f.jobs.find(j=>j.job_ref==='M0').id; f.qe=[{id:'q1',team_id:'T1',job_id:J,type:'callback',severity:'low',substantiation:'substantiated',status:'closed',cost_cents:5000},{id:'q2',team_id:'T1',job_id:J,type:'refund',severity:'medium',substantiation:'substantiated',status:'closed',cost_cents:20000}]; c=calc(f);
    T('T12: two substantiated events on one job → numerator 1 of 5 (20%), events_total 2, cost $250 kept',cat(c,'quality').numerator===1&&cat(c,'quality').denominator===5&&cat(c,'quality').diagnostics.events_total===2&&cat(c,'quality').diagnostics.events_cost_cents===25000,cat(c,'quality')); }
  { c=calc(fixture()); T('T13: the 5 jobs completed 9 days ago are immature (shown separately), only the 5 mature ones are in the denominator',cat(c,'quality').diagnostics.immature_jobs===5&&cat(c,'quality').denominator===5,cat(c,'quality').diagnostics);
    const f=fixture({matureJobs:0}); c=calc(f); T('T13: with no mature job the quality rate is N/A and evidence is Pending — immature ≠ issue-free',cat(c,'quality').value===null&&c.evidence.state==='pending_evidence'&&c.evidence.reasons.some(r=>/matured/.test(r)),c.evidence); }
  { const f=fixture(); f.cov.push({id:'CX',team_id:'T1',offered_at:'2026-09-10T15:00:00Z',job_date:'2026-09-12',eligible:false,eligibility:{reasons:['no availability declared before the offer for this date']},response:'declined',failure_reason:'busy',fulfilled:false}); c=calc(f);
    T('T14/§4.2: an ineligible offer is shown separately and never enters the denominator',cat(c,'coverage').denominator===20&&cat(c,'coverage').diagnostics.ineligible_offers===1); }
  { const f=fixture(); f.ex=[{id:'x1',team_id:'T1',source_table:'qual_leads',source_id:f.leads[9].id,status:'approved',reason:'duplicate of L2',category:'duplicate',decided_by:'luka.m@homealliance.com',decided_at:'2026-09-20T00:00:00Z'},{id:'x2',team_id:'T1',source_table:'qual_leads',source_id:f.leads[8].id,status:'pending',reason:'x',category:'other'}]; c=calc(f);
    T('T15/T16: approved exclusion removes one lead (denominator 9) and is listed in excluded_ids; pending one does not count and is a warning',cat(c,'sales').denominator===9&&cat(c,'sales').excluded_ids.includes(f.leads[9].id)&&cat(c,'sales').included_ids.length===9&&c.warnings.some(x=>/exclusion request/.test(x)),{d:cat(c,'sales').denominator,w:c.warnings}); }
  { const f=fixture(); const c1=calc(f); const frozen=JSON.stringify(c1); [0,1,2].forEach(i=>{f.leads[i].status='declined';f.leads[i].sold_revenue_cents=null;}); const c2=calc(f);
    T('T17: correcting source records changes the live score (sales 30% → 40 pts); the frozen snapshot text is unchanged',c2.weighted_score<c1.weighted_score&&JSON.stringify(c1)===frozen&&cat(c2,'sales').numerator===3&&cat(c2,'sales').points===40,{s1:c1.weighted_score,s2:c2.weighted_score}); }
  { const f=fixture({appts:20,attended:19}); c=calc(f); T('attendance: one unexplained no-show caps the band at 70 and is named',cat(c,'attendance').points===70&&cat(c,'attendance').diagnostics.unexplained_no_show===1&&cat(c,'attendance').notes.some(x=>/unexplained/.test(x)));
    const g=fixture({appts:20,attended:19,noShowReason:'customer not home, documented'}); c=calc(g); T('attendance: an explained no-show is 95% → 100 points, no cap',cat(c,'attendance').points===100&&cat(c,'attendance').diagnostics.unexplained_no_show===0); }
  { const f=fixture(); f.appts.push({id:'AP',team_id:'T1',scheduled_at:'2026-09-11T16:00:00Z',outcome:'customer_reschedule',reason:'customer asked to move'}); c=calc(f); T('attendance: a documented customer reschedule is excluded with its reason preserved',cat(c,'attendance').denominator===20&&cat(c,'attendance').excluded===1&&cat(c,'attendance').diagnostics.exclusion_reasons.includes('customer asked to move')); }
  { const f=fixture(); f.jobs[0].completion_evidence=null; c=calc(f); T('completion: a completion without evidence is not compliant (4/5)',cat(c,'completion').numerator===4&&cat(c,'completion').diagnostics.missing_evidence===1); }
  { const f=fixture(); f.jobs[1].current_promise_date='2026-09-20'; f.jobs[1].completed_at='2026-09-19T00:00:00Z'; c=calc(f); T('completion: a rescheduled promise is judged by the new date; the original is preserved in the record',cat(c,'completion').numerator===5&&cat(c,'completion').diagnostics.rescheduled_jobs===1&&f.jobs[1].promised_date==='2026-09-14'); }
  { const f=fixture(); f.res=[{id:'r1',team_id:'T1',kind:'no_new_assignments',reason:'incident review',lifted_at:null}]; f.dec=[{id:'d1',team_id:'T1',official_outcome:'pass',decided_at:'2026-09-20T00:00:00Z',next_review_date:'2026-10-18',kind:'official',snapshot_id:'s1'}]; c=calc(f,VB,{...team,status:'active'});
    T('T22: a Pass team with an active restriction is not qualified for the Rock and Pass is not recommended',c.qualified_for_rock===false&&c.gates.find(g=>g.key==='no_active_restriction').passed===false&&c.recommended_outcome!=='pass');
    f.res=[]; c=calc(f,VB,{...team,status:'active'}); T('the same team without the restriction counts (current Pass, active, eligible)',c.qualified_for_rock===true); }
  { c=calc(fixture(),VB,{...team,team_type:'rebuilt',former_technician:true,entry_review_complete_at:null}); T('T21: a rebuilt team led by the former technician starts at Pending Entry Review with the no-bypass note',c.evidence.state==='pending_entry_review'&&c.warnings.some(x=>/no bypass/.test(x)));
    c=calc(fixture(),VB,{...team,team_type:'rebuilt',former_technician:true}); T('T21: after entry review it needs three supervised jobs like any new team',c.evidence.state==='supervised_trial'&&c.evidence.progress.supervised.min===3);
    const f=fixture(); f.sup=[1,2,3].map(i=>({id:'s'+i,team_id:'T1',reviewed_at:'2026-09-01T00:00:00Z',result:'satisfactory'})); c=calc(f,VB,{...team,team_type:'rebuilt'}); T('T21: with three signed-off supervised jobs and the full sample it becomes Decision Eligible — same thresholds',c.evidence.state==='decision_eligible'&&c.recommended_outcome==='pass'); }
  { const f=fixture(); f.inc=[{id:'i1',team_id:'T1',event_code:'payment_fraud',status:'confirmed',reviewed_at:'2026-09-22T00:00:00Z'}]; c=calc(f); T('§7: a confirmed critical event → recommended Disqualify, final decision still Luka\'s',c.recommended_outcome==='disqualify'&&/final decision remains/.test(c.reasons[0]));
    f.inc[0].status='under_review'; c=calc(f); T('§7: an incident under review fails the severe-incident gate and blocks Pass without deciding anything',c.gates.find(g=>g.key==='no_unresolved_severe').passed===false&&c.recommended_outcome==='probation'); }
  { const f=fixture({won:4}); f.dec=[{id:'d1',team_id:'T1',official_outcome:'coaching',issue:'sales',decided_at:'2026-07-01T00:00:00Z',kind:'official'},{id:'d2',team_id:'T1',official_outcome:'coaching',issue:'sales',decided_at:'2026-08-01T00:00:00Z',kind:'official'}]; c=calc(f);
    T('§7: coaching twice for the same unresolved issue → Probation recommended',c.recommended_outcome==='probation'&&c.reasons.some(r=>/two consecutive/.test(r)));
    const g=fixture({won:2}); g.dec=[{id:'d1',team_id:'T1',official_outcome:'probation',issue:'sales',decided_at:'2026-08-01T00:00:00Z',next_review_date:'2026-09-01',kind:'official'}]; c=calc(g); T('§7: probation review date passed and still at probation level → Disqualify recommended (failed plan)',c.recommended_outcome==='disqualify'&&c.reasons.some(r=>/probation plan failed/.test(r)),c.reasons);
    const h=fixture({won:4}); h.dec=g.dec; c=calc(h); T('§7: at probation end a recovered-to-coaching team is recommended Coaching (Pass/Coaching/Disqualify are all valid ends)',c.recommended_outcome==='coaching'); }
  { c=calc(fixture({won:6})); const s=c.weighted_score; const f=fixture({won:6,offers:20,fulfilled:18}); c=calc(f); T('score arithmetic: coverage 90% → 70 pts × 15% = 10.5 contribution; total 95.5',cat(c,'coverage').points===70&&cat(c,'coverage').contribution===10.5&&c.weighted_score===95.5&&s===100); }
  T('T23: the engine has no network, DOM or page-state dependency (pure function of its input)',typeof C==='function'&&!/\bsbb\b|\bsb\./.test(C.toString())&&!/\bdocument\.|\bwindow\.|\bQ\./.test(C.toString()));

  console.log('— database rules (fake mirrors qualification_schema.sql) —');
  signIn('luka.m@homealliance.com'); await tick(150);
  let r=await fake.from('qual_metric_versions').insert({version:9,label:'bad',categories:[{key:'a',weight_pct:99,bands:{p100:50,p70:40,p40:30}}],evidence:{},windows:{},revenue:{},outcome_rules:{},margin_rules:{}}); T('T2 DB: weights 99 refused',/must total exactly 100/.test(em(r)));
  r=await fake.from('qual_metric_versions').update({status:'active',change_note:''}).eq('id','ver-1'); T('DB: activation without a change note refused',/change note/.test(em(r)));
  r=await fake.from('qual_teams').insert({name:'Alpha',team_type:'candidate',territories:['LA'],services:['cleaning']}); const alpha=r.data[0]; T('team created as prospective with a stable code',alpha&&alpha.status==='prospective'&&alpha.seq===1);
  r=await fake.from('qual_teams').update({status:'active'}).eq('id',alpha.id); T('DB: a team cannot be set active by hand',/only through an official decision/.test(em(r)));
  r=await fake.from('qual_availability').insert({team_id:alpha.id,avail_date:'2026-10-01'}); const av1=r.data[0];
  r=await fake.from('qual_coverage_events').insert({team_id:alpha.id,job_date:'2026-10-01',territory:'LA',service:'cleaning'}); const off1=r.data[0]; T('offer inside territory/service with prior availability → eligible',off1.eligible===true);
  r=await fake.from('qual_coverage_events').insert({team_id:alpha.id,job_date:'2026-10-02',territory:'LA',service:'cleaning'}); T('offer on a date without declared availability → not eligible, reason stored',r.data[0].eligible===false&&/no availability/.test(r.data[0].eligibility.reasons[0]));
  r=await fake.from('qual_coverage_events').insert({team_id:alpha.id,job_date:'2026-10-01',territory:'OC',service:'cleaning'}); T('offer outside territory → not eligible',r.data[0].eligible===false&&/territory/.test(r.data[0].eligibility.reasons[0]));
  r=await fake.from('qual_availability').update({available:false}).eq('id',av1.id); T('T14 DB: the availability row is locked after the offer — edit refused',/locked/.test(em(r)));
  r=await fake.from('qual_availability').insert({team_id:alpha.id,avail_date:'2026-10-01',available:false}); T('T14 DB: a retroactive availability row for that date needs a reason (and the manager)',/needs a reason/.test(em(r)));
  r=await fake.from('qual_availability').insert({team_id:alpha.id,avail_date:'2026-10-01',available:false,change_reason:'sick day recorded late'}); T('T14 DB: with a reason the manager may add it — and the earlier offer stays eligible',!r.error&&r.data[0].approved_by==='luka.m@homealliance.com'&&db.qual_coverage_events.find(x=>x.id===off1.id).eligible===true);
  r=await fake.from('qual_coverage_events').update({eligible:false}).eq('id',off1.id); T('T14 DB: eligibility on an offer is frozen',/frozen/.test(em(r)));
  r=await fake.from('qual_coverage_events').update({response:'declined'}).eq('id',off1.id); T('DB: a decline needs its reason',/reason/.test(em(r)));
  r=await fake.from('qual_jobs').insert({team_id:alpha.id,job_ref:'J1',promised_date:'2026-10-05',current_promise_date:'2026-10-05',revenue_cents:100000}); const j1=r.data[0];
  r=await fake.from('qual_jobs').update({promised_date:'2026-10-09'}).eq('id',j1.id); T('DB: original promise date immutable',/immutable/.test(em(r)));
  r=await fake.from('qual_jobs').update({current_promise_date:'2026-10-09'}).eq('id',j1.id); T('DB: current promise date moves only via a reschedule',/reschedule/.test(em(r)));
  r=await fake.from('qual_job_reschedules').insert({job_id:j1.id,from_date:'2026-10-05',to_date:'2026-10-09',reason:'customer travelling'}); T('DB: reschedule recorded → current promise 10-09, original 10-05 kept',!r.error&&db.qual_jobs[0].current_promise_date==='2026-10-09'&&db.qual_jobs[0].promised_date==='2026-10-05');
  r=await fake.from('qual_compliance_checks').insert({team_id:alpha.id,requirement:'start authorization',critical:true,result:'pass'}); T('DB: a pass without evidence is refused',/qcc_pass_needs_evidence/.test(em(r)));
  r=await fake.from('qual_leads').insert({team_id:alpha.id,lead_ref:'L1',status:'won'}); T('DB: won without revenue refused',/ql_won_needs_revenue/.test(em(r)));
  r=await fake.from('qual_leads').insert({team_id:alpha.id,lead_ref:'L1',status:'team_failed'}); T('DB: team failure without reason refused',/ql_failed_needs_reason/.test(em(r)));
  r=await fake.from('qual_leads').insert({team_id:alpha.id,lead_ref:'L1',assigned_at:'2026-09-01T00:00:00Z'}); const l1=r.data[0]; r=await fake.from('qual_leads').update({assigned_at:'2026-09-20T00:00:00Z'}).eq('id',l1.id); T('DB: assignment cohort never moves',/cohort/.test(em(r)));
  r=await fake.from('qual_lead_estimates').insert({lead_id:l1.id,version:1,price_cents:50000}); const e1=r.data[0]; r=await fake.from('qual_lead_estimates').update({price_cents:40000}).eq('id',e1.id); T('T11 DB: an estimate version is never edited (new version instead)',/never edited/.test(em(r)));
  r=await fake.from('qual_exclusions').insert({team_id:alpha.id,source_table:'qual_leads',source_id:l1.id,category:'duplicate',reason:''}); T('DB: exclusion needs a reason',/reason/.test(em(r)));
  // snapshot + decision gates
  r=await fake.from('qual_snapshots').insert({team_id:alpha.id,version_id:'ver-1',period_start:P.start,period_end:P.end,computed:{categories:[],gates:[]},weighted_score:85,evidence_state:'decision_eligible',recommended_outcome:'pass'}); const snapDraft=r.data[0];
  r=await fake.from('qual_decisions').insert({team_id:alpha.id,snapshot_id:snapDraft.id,version_id:'ver-1',official_outcome:'pass',reason:'x'}); T('T1 DB: a decision on a snapshot from a non-active version is refused',/not the active version/.test(em(r)));
  r=await fake.from('qual_metric_versions').update({status:'active',change_note:'Activated for the test'}).eq('id','ver-1'); T('manager activates v1 with a change note; approver stamped',!r.error&&db.qual_metric_versions[0].status==='active'&&db.qual_metric_versions[0].approved_by==='luka.m@homealliance.com');
  r=await fake.from('qual_snapshots').insert({team_id:alpha.id,version_id:'ver-1',period_start:P.start,period_end:P.end,computed:{categories:[{key:'sales',points:100}],gates:[{key:'critical_compliance',passed:false}]},weighted_score:85,evidence_state:'decision_eligible',recommended_outcome:'probation'}); const snapGate=r.data[0];
  r=await fake.from('qual_decisions').insert({team_id:alpha.id,snapshot_id:snapGate.id,version_id:'ver-1',official_outcome:'pass',reason:'x'}); T('T5 DB: Pass refused when a gate failed in the snapshot',/gate/.test(em(r)));
  r=await fake.from('qual_snapshots').insert({team_id:alpha.id,version_id:'ver-1',period_start:P.start,period_end:P.end,computed:{categories:[],gates:[]},weighted_score:null,evidence_state:'pending_evidence',recommended_outcome:'pending'}); const snapPend=r.data[0];
  r=await fake.from('qual_decisions').insert({team_id:alpha.id,snapshot_id:snapPend.id,version_id:'ver-1',official_outcome:'pass',reason:'x'}); T('T6 DB: Pass refused for a Pending Evidence team',/pending_evidence/.test(em(r)));
  r=await fake.from('qual_decisions').insert({team_id:alpha.id,snapshot_id:snapPend.id,version_id:'ver-1',official_outcome:'coaching',reason:'thin sample, attendance issue'}); T('T20 DB: Coaching without issue/action/owner/due/review refused',/requires a named issue/.test(em(r)));
  r=await fake.from('qual_decisions').insert({team_id:alpha.id,snapshot_id:snapPend.id,version_id:'ver-1',official_outcome:'coaching',reason:'attendance issue',issue:'attendance',action_text:'ride-along and daily check-in',action_owner:'Tom',action_due:'2026-10-07',next_review_date:'2026-10-21'});
  const dec1=r.data&&r.data[0]; T('T19 DB: Coaching recorded with reviewer identity, role, time, period and version from the snapshot',!!dec1&&dec1.reviewer_email==='luka.m@homealliance.com'&&dec1.reviewer_role==='manager'&&!!dec1.decided_at&&dec1.period_start===P.start&&dec1.version_id==='ver-1'&&dec1.recommended_outcome==='pending',dec1);
  T('T20 DB: the corrective action row was created from the decision',db.qual_actions.length===1&&db.qual_actions[0].owner==='Tom'&&db.qual_actions[0].due_date==='2026-10-07');
  r=await fake.from('qual_metric_versions').update({categories:VB.categories}).eq('id','ver-1'); T('T18 DB: the version used in a decision is immutable — thresholds change through a new version',/immutable/.test(em(r))&&db.qual_metric_versions[0].used_in_decision===true);
  r=await fake.from('qual_snapshots').update({weighted_score:99}).eq('id',snapPend.id); T('T17 DB: a snapshot cannot be edited',/permission denied/.test(em(r)));
  r=await fake.from('qual_decisions').update({official_outcome:'pass'}).eq('id',dec1.id); T('DB: a decision cannot be edited',/permission denied/.test(em(r)));
  r=await fake.from('qual_actions').update({status:'done'}).eq('id',db.qual_actions[0].id); T('T24 DB: closing an action needs completion evidence (a ClickUp close changes nothing here)',/completion evidence/.test(em(r)));
  r=await fake.from('qual_actions').update({clickup_task_id:'86eyxxxxx'}).eq('id',db.qual_actions[0].id); T('T24: linking a ClickUp task id leaves the decision and action status untouched',!r.error&&db.qual_actions[0].status==='open'&&db.qual_decisions[0].official_outcome==='coaching');
  // permissions
  signIn('tom@5starair.pro'); await tick(150);
  r=await fake.from('qual_decisions').insert({team_id:alpha.id,snapshot_id:snapPend.id,version_id:'ver-1',official_outcome:'disqualify',reason:'x'}); T('T25: dispatcher cannot record a decision',/row-level security|Only the manager/.test(em(r)));
  r=await fake.from('qual_snapshots').insert({team_id:alpha.id,version_id:'ver-1',period_start:P.start,period_end:P.end,computed:{},evidence_state:'x'}); T('T25: dispatcher cannot freeze a snapshot',/row-level security/.test(em(r)));
  r=await fake.from('qual_metric_versions').insert({version:2,label:'x',categories:VB.categories,evidence:{},windows:{},revenue:{},outcome_rules:{},margin_rules:{}}); T('T25: dispatcher cannot write configuration',/row-level security/.test(em(r)));
  r=await fake.from('qual_exclusions').insert({team_id:alpha.id,source_table:'qual_leads',source_id:l1.id,category:'duplicate',reason:'dup of L0'}); const ex1=r.data&&r.data[0]; T('dispatcher may request an exclusion (pending, requester stamped)',!!ex1&&ex1.status==='pending'&&ex1.requested_by==='tom@5starair.pro');
  r=await fake.from('qual_exclusions').update({status:'approved'}).eq('id',ex1.id); T('T25: dispatcher cannot approve his own exclusion',/row-level security|Only the manager/.test(em(r)));
  r=await fake.from('qual_restrictions').insert({team_id:alpha.id,reason:'x'}); T('T25: dispatcher cannot impose a restriction',/row-level security/.test(em(r)));
  r=await fake.from('qual_incidents').insert({team_id:alpha.id,event_code:'unsafe_work',description:'ladder on a wet roof'}); T('dispatcher may report a suspected incident',!r.error&&r.data[0].status==='suspected');
  r=await fake.from('qual_incidents').update({status:'confirmed',review_note:'x'}).eq('id',r.data[0].id); T('T25: dispatcher cannot confirm an incident',/Only the manager/.test(em(r)));
  r=await fake.from('qual_quality_events').insert({team_id:alpha.id,job_id:j1.id,type:'complaint',substantiation:'substantiated'}); T('T25: dispatcher cannot rule an issue substantiated',/Only the manager/.test(em(r)));
  r=await fake.from('qual_team_members').insert({team_id:alpha.id,person_name:'3 LA Donat',approval_status:'approved'}); T('T25: dispatcher cannot approve a member',/Only the manager/.test(em(r)));
  r=await fake.from('qual_teams').update({entry_review_complete_at:new Date().toISOString()}).eq('id',alpha.id); T('T25: dispatcher cannot complete an entry review',/Only the manager/.test(em(r)));
  await fake.auth.signOut(); await tick(60);
  r=await fake.from('qual_teams').select('*'); T('anon: nothing readable',/permission denied/.test(em(r)));
  signIn('luka.m@homealliance.com'); await tick(120);
  r=await fake.from('qual_exclusions').update({status:'approved',decision_note:'confirmed duplicate'}).eq('id',ex1.id); T('T15 DB: manager approves — approver, time and note recorded',!r.error&&db.qual_exclusions[0].decided_by==='luka.m@homealliance.com'&&!!db.qual_exclusions[0].decided_at);
  r=await fake.from('qual_exclusions').update({status:'pending'}).eq('id',ex1.id); T('DB: a decided exclusion is not reopened',/not reopened/.test(em(r)));
  T('audit: sensitive actions were logged (versions, teams, availability, exclusions, decisions, actions, incidents)',['qual_metric_versions','qual_teams','qual_availability','qual_exclusions','qual_decisions','qual_actions','qual_incidents'].every(t=>db.qual_audit.some(a=>a.table_name===t)),[...new Set(db.qual_audit.map(a=>a.table_name))]);

  console.log('— page: gate, roles, flows (redesign: sheets, section pages, guided entry) —');
  // the page holds the fake created at boot; reset its database IN PLACE so page and assertions read the same rows
  await fake.auth.signOut(); await tick(60);
  Object.keys(db).forEach(k=>delete db[k]); Object.assign(db,makeDb());
  const shown=sel=>{const e=$(sel);return !!e&&!e.classList.contains('hide');};
  const sheetOpen=()=>!!$('#qSheet');
  const sheet=async(values,opts)=>{ // fill the open sheet and press primary (or secondary)
    if(!sheetOpen())throw new Error('no sheet open');
    for(const [k,v] of Object.entries(values||{})){const e=$(`#qSheet [data-f="${k}"]`);if(!e)throw new Error('sheet has no field '+k);e.value=v;e.dispatchEvent(new w.Event('input',{bubbles:true}));e.dispatchEvent(new w.Event('change',{bubbles:true}));}
    $(opts&&opts.secondary?'#qSheetSecondary':'#qSheetPrimary').click(); await tick(220); };
  const sheetNote=()=>($('#qSheetNote')||{}).textContent||'';
  const act=async(sel)=>{const b=$(sel);if(!b)throw new Error('no element '+sel);b.click();await tick(200);};
  const section=async(key)=>{await act(`#qTeam [data-section="${key}"]`);};
  T('no session → sign-in gate, body hidden',shown('#qGate')&&!shown('#qBody')&&shown('#qGateForm'));
  signIn('someone@homealliance.com'); await tick(100); T('non-member told so',shown('#qNotMember')&&!shown('#qBody')&&/Not a member/.test($('#qGateTitle').textContent));
  signIn('luka.m@homealliance.com'); await tick(200);
  T('manager signed in → body shown, identity + role, version badge warns no active version',shown('#qBody')&&/luka\.m · manager/.test($('#qWho').textContent)&&/no active version/.test($('#qVerBadge').textContent)&&$('#qVerBadge').classList.contains('warn'));
  T('why-strip and blockers rendered (§15.12): no active version + baseline unresolved',/Why one scorecard/.test($('.why').textContent)&&/No active metric version/.test($('#qBlockers').textContent)&&/baseline unresolved/i.test($('#qBlockers').textContent));
  T('overview: hero ring says 0 of 3 qualified; outcome and evidence breakdowns present',!!$('#qOver .ring')&&/0/.test($('#qOver .ring .v').textContent)&&/of 3 qualified/.test($('#qOver').textContent)&&/By official outcome/.test($('#qOver').textContent)&&/By evidence state/.test($('#qOver').textContent));
  // new team via sheet
  w.showQualTab('qteams'); await tick(40); $('#qNewTeam').click(); await tick(60);
  T('“+ New team” opens a sheet, not a form',sheetOpen()&&/New team/.test($('#qSheet h2').textContent));
  await sheet({}); T('sheet validation: a team needs a name (sheet stays open, note shown)',sheetOpen()&&/Name the team/.test(sheetNote()));
  await sheet({name:'Donat team',team_type:'incumbent',leader_name:'3 LA Donat',territories:'LA',services_sel:'both'});
  const tm=db.qual_teams[0]; T('team created from the sheet and opened on the Team tab',!!tm&&tm.name==='Donat team'&&tm.territories.join()==='LA'&&tm.services.length===2&&!sheetOpen()&&$('#tab-qteam').classList.contains('on')&&/Donat team/.test($('#qTeam').textContent),toast());
  T('team page: Pending Entry Review, four gates, guided-entry steps, records list',/Pending Entry Review/.test($('#qTeam').textContent)&&$$('#qTeam .gate').length===4&&$$('#qTeam .step').length===4&&$$('#qTeam [data-section]').length===13);
  // roster section: add member, approve, entry review
  await section('roster'); T('records → Roster opens a section page with a back link and “+ Member”',/Roster and entry review/.test($('#qTeam h1').textContent)&&!!$('#qTeam .backlink')&&!!$('#qTeam [data-act="add"][data-id="roster"]'));
  await act('#qTeam [data-act="add"][data-id="roster"]'); await sheet({person_name:'3 LA Donat',role:'leader'});
  T('member added and linked to the board technician',db.qual_team_members.length===1&&db.qual_team_members[0].technician_id==='t2'&&db.qual_team_members[0].role==='leader',toast());
  await act('#qTeam [data-act="approvemember"]'); T('manager approves the member (approver stamped)',db.qual_team_members[0].approval_status==='approved'&&db.qual_team_members[0].approved_by==='luka.m@homealliance.com');
  await act('#qTeam [data-act="completeentry"]'); T('entry review cannot be completed with unchecked items',/Every item/.test(toast()));
  $$('#qEntryReview [data-er]').forEach(cb=>cb.checked=true); await act('#qTeam [data-act="completeentry"]');
  T('entry review complete → team provisional, reviewer stamped',db.qual_teams[0].status==='provisional'&&db.qual_teams[0].entry_reviewed_by==='luka.m@homealliance.com'&&/Completed/.test($('#qEntryReview').textContent));
  // availability + offer + import
  await act('#qTeam .backlink'); await section('avail'); await act('#qTeam [data-act="add"][data-id="avail"]'); await sheet({avail_date:'2026-10-01'}); T('availability declared',db.qual_availability.length===1&&/available/.test($('#qTeam .pill').textContent));
  await act('#qTeam .backlink'); await section('cov'); await act('#qTeam [data-act="add"][data-id="cov"]'); await sheet({job_date:'2026-10-01',territory:'LA',service:'cleaning'});
  T('offer recorded and eligible; availability locked; row says Eligible',db.qual_coverage_events.length===1&&db.qual_coverage_events[0].eligible===true&&!!db.qual_availability[0].locked_at&&/Eligible offer/.test($('#qTeam').textContent),toast());
  await act('#qTeam [data-act="importcov"]'); T('import from the Coverage log: the row naming Donat becomes an offer (accepted, note says verify), deduped by log id',db.qual_coverage_events.length===2&&db.qual_coverage_events[1].coverage_log_id==='cl-1'&&db.qual_coverage_events[1].response==='accepted'&&/verify/.test(db.qual_coverage_events[1].notes),toast());
  await act('#qTeam [data-act="importcov"]'); T('second import finds nothing new',/Nothing new/.test(toast()));
  await act('#qTeam [data-act="covresp"]'); await sheet({response:'declined'}); T('a decline without a reason is refused inside the sheet',sheetOpen()&&/reason is required/.test(sheetNote())); await sheet({failure_reason:'on another job'}); T('decline saved with its reason',db.qual_coverage_events.find(c=>c.response==='declined')?.failure_reason==='on another job');
  // leads section: add via the lead sheet (with estimate), add estimate v2, mark won
  await act('#qTeam .backlink'); await section('leads'); await act('#qTeam [data-act="add"][data-id="leads"]');
  T('“+ Lead” opens the lead sheet (no guided-entry dots outside the flow)',sheetOpen()&&/New lead/.test($('#qSheet h2').textContent)&&!$('#qSheet .dots'));
  await sheet({lead_ref:'A1B2C3',service:'installation',estimate_cents:'7500'}); T('lead recorded (pending, qualified) with estimate v1 from the same sheet',db.qual_leads.length===1&&db.qual_leads[0].status==='pending'&&db.qual_lead_estimates.length===1&&db.qual_lead_estimates[0].price_cents===750000,toast());
  await act('#qTeam [data-act="addest"]'); await sheet({price_cents:'7200'}); T('T11: estimate v2 added — still one lead',db.qual_lead_estimates.length===2&&db.qual_leads.length===1);
  await act('#qTeam [data-act="leadwon"]'); T('Won sheet pre-fills the latest estimate',sheetOpen()&&$('#qSheet [data-f="sold_revenue_cents"]').value==='7200'); await sheet({}); T('lead won at $7,200; latest estimate marked accepted',db.qual_leads[0].status==='won'&&db.qual_leads[0].sold_revenue_cents===720000&&db.qual_lead_estimates.find(e=>e.version===2).outcome==='accepted');
  // jobs: add, costs with unknown, reschedule
  await act('#qTeam .backlink'); await section('jobs'); await act('#qTeam [data-act="add"][data-id="jobs"]'); await sheet({job_ref:'J-100',service:'installation',promised_date:'2026-09-30',revenue_cents:'7200'});
  T('job recorded with current promise = promised',db.qual_jobs.length===1&&db.qual_jobs[0].current_promise_date==='2026-09-30');
  await act('#qTeam [data-act="costs"]'); await sheet({costs_text:'materials, 2000, estimated\nhelper, unknown, estimated'});
  T('T8 page: unknown cost saved as unknown; the row says the margin is not calculable and unknown is not zero',db.qual_jobs[0].costs[1].status==='unknown'&&/not treated as zero/.test($('#qTeam').textContent));
  await act('#qTeam [data-act="resched"]'); await sheet({to_date:'2026-10-03'}); T('reschedule needs a reason (sheet stays open)',sheetOpen()&&/reason is required/.test(sheetNote())); await sheet({reason:'customer travelling'});
  T('reschedule via the sheet: original kept, current moved, shown on the row',db.qual_jobs[0].promised_date==='2026-09-30'&&db.qual_jobs[0].current_promise_date==='2026-10-03'&&/→ Oct 3/.test($('#qTeam').textContent));
  // guided entry chain: lead → appointment → job → completion
  await act('#qTeam .backlink'); await act('#qTeam [data-act="step"][data-id="lead"]'); T('guided entry step 1 opens with progress dots',sheetOpen()&&$$('#qSheet .dots span').length===4&&/step 1 of 4/.test($('#qSheet .eyebrow').textContent));
  await sheet({lead_ref:'B2C3D4',service:'cleaning'}); T('step 1 saved the lead and chained to step 2 (appointment for that lead)',db.qual_leads.length===2&&sheetOpen()&&/Book appointment/.test($('#qSheet h2').textContent)&&$('#qSheet [data-f="lead_id"]').value===db.qual_leads[1].id);
  await sheet({scheduled_at:'2026-09-24T09:00',outcome:'attended'}); T('step 2 saved the appointment and chained to step 3 (job)',db.qual_appointments.length===1&&db.qual_appointments[0].outcome==='attended'&&sheetOpen()&&/Create job/.test($('#qSheet h2').textContent));
  await sheet({job_ref:'J-101',promised_date:'2026-09-25',revenue_cents:'640'}); T('step 3 saved the job and chained to step 4 (completion)',db.qual_jobs.length===2&&sheetOpen()&&/Record completion/.test($('#qSheet h2').textContent));
  await sheet({completed_at:'2026-09-25T15:20',completion_evidence:'photos #7',cost_labor:'200',cost_materials:'80'}); const j2=db.qual_jobs.find(j=>j.job_ref==='J-101');
  T('step 4 recorded completion with evidence and two actual costs; chain ends',!sheetOpen()&&!!j2.completed_at&&j2.completion_evidence==='photos #7'&&j2.costs.length===2&&j2.costs.every(c=>c.status==='actual'),j2);
  T('“Continue where you left off” lists the job with an unknown cost',/Enter costs/.test($('#qTeam').textContent));
  // configuration: activate v1 via sheet, edit draft, clone to v2
  w.showQualTab('qcfg'); await tick(60); T('configuration lists v1 draft with activate/edit and the §18 checklist',/v1/.test($('#qCfg').textContent)&&!!$('#qCfg [data-cfg="activate"]')&&/§18/.test($('#qCfg').textContent)&&/baseline/i.test($('#qCfg').textContent));
  $('#qCfg [data-cfg="edit"]').click(); await tick(40); T('draft editor opens with weights totalling 100 and segmented status controls',/Weights total 100/.test($('#qCfgTotal').textContent)&&$$('#qCfgEditor [data-stseg]').length>0);
  $('#qCfgEditor [data-c="0.weight_pct"]').value='25'; $('#qCfgEditor [data-c="0.weight_pct"]').dispatchEvent(new w.Event('input',{bubbles:true})); T('editor flags a 105 total live',/105/.test($('#qCfgTotal').textContent)&&$('#qCfgTotal').classList.contains('bad'));
  $('#qCfgSave').click(); await tick(100); T('T2 page: saving an invalid draft is refused',/must be exactly 100/.test(toast())&&db.qual_metric_versions[0].categories[0].weight_pct===20);
  $('#qCfgEditor [data-c="0.weight_pct"]').value='20'; $('#qCfgSave').click(); await tick(200); T('valid draft saved',!/must be/.test(toast())&&db.qual_metric_versions.length===1);
  $('#qCfg [data-cfg="activate"]').click(); await tick(60); T('Activate opens a confirmation sheet asking for the change note',sheetOpen()&&/Activate metric v1/.test($('#qSheet h2').textContent));
  await sheet({change_note:''}); T('activation without a note stays in the sheet',sheetOpen()&&/change note is required/.test(sheetNote())); await sheet({change_note:'Activated after review — baseline still unresolved'});
  T('v1 activated by the manager; badge updates; only the baseline blocker remains',db.qual_metric_versions[0].status==='active'&&/metric v1/.test($('#qVerBadge').textContent)&&!$('#qVerBadge').classList.contains('warn')&&!/No active metric version/.test($('#qBlockers').textContent)&&/baseline unresolved/i.test($('#qBlockers').textContent));
  $('#qCfg [data-cfg="clone"]').click(); await tick(40); T('new draft from v1 proposes v2',/New draft v2/.test($('#qCfgEditor').textContent));
  T('§18.1: the draft editor carries the qualified-lead definition as a versioned text value',!!$('#qCfgEditor [data-v="evidence.qualified_lead_definition"]'));
  $('#qCfgEditor [data-v="evidence.qualified_lead_definition"]').value='A lead with a confirmed appointment and a documented duct need'; $('#qCfgEditor [data-stseg="v:evidence.qualified_lead_definition"][data-sv="confirmed"]').click();
  $('#qCfgEditor [data-v="revenue.baseline_cents"]').value='1000'; $('#qCfgEditor [data-stseg="v:revenue.baseline_cents"][data-sv="confirmed"]').click(); $('#qCfgEditor [data-d="label"]').value='v2 — baseline $1,000/lead'; $('#qCfgSave').click(); await tick(250);
  T('T18: v2 draft saved with the baseline in cents and status confirmed; v1 stays active',db.qual_metric_versions.length===2&&db.qual_metric_versions[1].revenue.baseline_cents.value===100000&&db.qual_metric_versions[1].revenue.baseline_cents.status==='confirmed'&&db.qual_metric_versions[1].status==='draft'&&db.qual_metric_versions[0].status==='active');
  T('§18.1: the definition is stored as text with status confirmed, and the checklist ticks it for the calc version',db.qual_metric_versions[1].evidence.qualified_lead_definition.value==='A lead with a confirmed appointment and a documented duct need'&&db.qual_metric_versions[1].evidence.qualified_lead_definition.status==='confirmed');
  // decision via sheet
  w.qOpen(tm.id); await tick(100); await act('#qTeam [data-act="decide"]'); T('“Record decision” opens the decision sheet with the frozen-snapshot subtitle',sheetOpen()&&/Record decision/.test($('#qSheet h2').textContent)&&/metric v1/.test($('#qSheet .hd .s').textContent));
  await sheet({official_outcome:'pass',reason:'looks good'}); T('T6 page: Pass refused inside the sheet for a team without evidence — nothing written',sheetOpen()&&/Pass is refused/.test(sheetNote())&&db.qual_snapshots.length===0&&db.qual_decisions.length===0);
  await sheet({official_outcome:'coaching',reason:'thin sample; one no-show'}); T('T20 page: Coaching without the corrective-action fields refused',sheetOpen()&&/needs a named issue/.test(sheetNote())&&db.qual_decisions.length===0);
  await sheet({issue:'attendance',action_text:'ride-along with Tom',action_owner:'Tom',action_due:new Date(Date.now()+3*86400000).toISOString().slice(0,10),next_review_date:'2026-10-21'});
  T('T19 page: snapshot frozen with v1 and Coaching recorded with identity, period, version; action created',!sheetOpen()&&db.qual_snapshots.length===1&&db.qual_decisions.length===1&&db.qual_decisions[0].reviewer_email==='luka.m@homealliance.com'&&db.qual_decisions[0].version_id==='ver-1'&&db.qual_snapshots[0].computed.version.version===1&&db.qual_actions.length===1,toast());
  T('T19: the frozen snapshot carries the full calculation (categories with source ids, gates, evidence)',Array.isArray(db.qual_snapshots[0].computed.categories)&&db.qual_snapshots[0].computed.categories.length===7&&Array.isArray(db.qual_snapshots[0].computed.gates)&&!!db.qual_snapshots[0].computed.evidence);
  T('team page shows the official Coaching pill and the decision date',$$('#qTeam .pill.coaching').length>=1&&/Decided/.test($('#qTeam').textContent));
  await section('dec'); T('Decisions section lists the decision and its corrective action with “View snapshot”',/Coaching/.test($('#qTeam').textContent)&&/ride-along with Tom/.test($('#qTeam').textContent)&&!!$('#qTeam [data-act="viewsnap"]'));
  await act('#qTeam [data-act="viewsnap"]'); T('snapshot viewer shows the frozen JSON',/Frozen snapshot/.test($('#qSnapView').textContent)&&/weighted_score/.test($('#qSnapView').textContent));
  T('T18 page: v1 is now marked used/immutable',db.qual_metric_versions[0].used_in_decision===true);
  // category drill-down
  await act('#qTeam .backlink'); await act('#qTeam [data-drill="sales"]'); T('T16: a category row drills down to formula, sample and source ids',!!$('#qTeam .drill')&&/Formula/.test($('#qTeam .drill').textContent)&&/included/.test($('#qTeam .drill').textContent));
  // queues + comparison + overview
  w.showQualTab('qqueue'); await tick(60); T('queues render seven cards; the coaching action due appears',$$('#qQueues > .card').length===7&&/ride-along/.test($('#qQueues').textContent));
  w.showQualTab('qteams'); await tick(60); T('comparison: one row, Coaching official, evidence dot, N/A cells',$$('#qTeams a.row').length===1&&/Coaching/.test($('#qTeams').textContent)&&/N\/A/.test($('#qTeams').textContent));
  setv('#qfOut','pass'); await tick(40); T('filter by outcome hides the row without changing the stored decision',$$('#qTeams a.row').length===0&&/No teams match/.test($('#qTeams').textContent)&&db.qual_decisions[0].official_outcome==='coaching'); setv('#qfOut',''); await tick(40);
  w.showQualTab('qover'); await tick(60); T('overview: 0 of 3 qualified (coaching does not count), Coaching counted once',/0/.test($('#qOver .ring .v').textContent)&&/Coaching/.test($('#qOver .counts').textContent));
  // dispatcher view
  signIn('tom@5starair.pro'); await tick(250); w.qOpen(tm.id); await tick(120);
  T('dispatcher: no “Record decision”, records and guided entry available',!$('#qTeam [data-act="decide"]')&&$$('#qTeam .step').length===4&&/tom · dispatcher/.test($('#qWho').textContent));
  await section('leads'); T('dispatcher may add leads',!!$('#qTeam [data-act="add"][data-id="leads"]'));
  await act('#qTeam .backlink'); await section('roster'); T('dispatcher: no approve button, no “Mark entry review complete”',!$('#qTeam [data-act="approvemember"]')&&!$('#qTeam [data-act="completeentry"]'));
  await act('#qTeam .backlink'); await section('dec'); T('dispatcher: Decisions section has no add button',!$('#qTeam [data-act="add"][data-id="dec"]'));
  w.showQualTab('qcfg'); await tick(60); T('dispatcher: configuration read-only',!$('#qCfg [data-cfg="activate"]')&&!$('#qCfg [data-cfg="edit"]')&&!!$('#qCfg [data-cfg="view"]'));
  w.showQualTab('qsop'); await tick(40); T('SOP tab renders the dispatcher procedure: the four steps, the Friday routine, refusals and checklists; names the role, never the person',$('#tab-qsop').classList.contains('on')&&/How to record the day/.test($('#qSop').textContent)&&/Lead/.test($('#qSop .stp').textContent)&&/Friday/.test($('#qSop').textContent)&&/When a button refuses/.test($('#qSop').textContent)&&$$('#qSop label.ck').length===13&&!/Vasyl|Tom\b|5starair/.test($('#qSop').textContent));
  $('#qWhySop').click(); await tick(20); T('“SOP ›” in the why-strip opens the SOP tab',$('#tab-qsop').classList.contains('on'));
  w.showQualTab('qdef'); await tick(40); T('Definitions tab renders categories, evidence states, outcomes, process, roles and refusals',/seven categories/i.test($('#qDef').textContent)&&/Decision Eligible/.test($('#qDef').textContent)&&/When a button refuses/.test($('#qDef').textContent)&&/Former technician returns/.test($('#qDef').textContent));
  await fake.auth.signOut(); await tick(80); T('sign out → gate again',shown('#qGate')&&!shown('#qBody'));
  T('zero console / jsdom errors',errors.length===0,errors);
  if(cssWarn.length)console.log(`  (jsdom CSS parser warnings, not app errors: ${cssWarn.length})`);
  console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail?1:0);
})().catch(e=>{console.error('TEST CRASH',e);process.exit(2);});
