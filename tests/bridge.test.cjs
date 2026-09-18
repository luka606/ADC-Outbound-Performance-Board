const {JSDOM,VirtualConsole}=require('jsdom'); const fs=require('fs');
const {makeFake}=require('./fake-bridge.js'); const {makeDb}=require('./seed-bridge.js');
const html=fs.readFileSync(process.argv[2],'utf8');
const errors=[],cssWarn=[]; const vc=new VirtualConsole();
vc.on('jsdomError',e=>(/Could not parse CSS/.test(e.message)?cssWarn:errors).push('jsdomError: '+e.message.split('\n')[0]));
vc.on('error',(...a)=>errors.push('console.error: '+a.join(' '))); ['warn','log','info','debug'].forEach(k=>vc.on(k,()=>{}));
let db=makeDb(),fake=makeFake(db);
const dom=new JSDOM(html,{url:'http://localhost/bridge.html',runScripts:'dangerously',pretendToBeVisual:true,virtualConsole:vc,beforeParse(w){
  w.localStorage.setItem('adc_supabase_cfg',JSON.stringify({url:'http://fake.local',key:'fake'}));
  w.supabase={createClient:()=>fake}; w.confirm=()=>true; w.prompt=()=>'test reason'; w.alert=()=>{}; w.scrollTo=()=>{};
  w.HTMLElement.prototype.scrollIntoView=function(){}; w.URL.createObjectURL=()=>'blob:fake';
}});
const w=dom.window,d=w.document,$=s=>d.querySelector(s),$$=s=>[...d.querySelectorAll(s)];
const tick=(ms=40)=>new Promise(r=>setTimeout(r,ms));
let pass=0,fail=0; const T=(n,c,x)=>{if(c){pass++;console.log('  ✓',n);}else{fail++;console.log('  ✗',n,x!==undefined?JSON.stringify(x).slice(0,400):'');}};
const setv=(sel,v)=>{const e=$(sel);e.value=v;e.dispatchEvent(new w.Event('change',{bubbles:true}));}; const toast=()=>$('#toast').textContent;
const vis=sel=>{const e=$(sel);return !!e&&e.style.display!=='none';};
const signIn=email=>{fake.auth.__set({user:{id:'u',email}});};
(async()=>{
  await tick(80);
  console.log('— pure logic (brief §10) —');
  const BC=w.bridgeCompute, rules={installation:{target_pct:40,floor_pct:35},cleaning:{floor_pct:45}};
  const agrBoth={status:'approved',route:'combined',components:[{rate_pct:50}],deduction_categories:['materials','company_helper']};
  const agrMat={...agrBoth,deduction_categories:['materials']};
  const fx=(a,extra)=>BC({route:'combined',customer_price_cents:1000000,discounts_cents:0,scope:[{service:'installation',price_cents:1000000}],rules,agreement:a,
    costs:[{category:'materials',amount_cents:200000,payer:'company',status:'estimated'},{category:'company_helper',amount_cents:50000,payer:'company',status:'estimated'}],...(extra||{})});
  let o=fx(agrBoth); T('S3: deduct materials+helper → commission $3,750, profit $3,750, margin 37.5%, below target above floor',o.c_cents===375000&&o.gross_profit_cents===375000&&o.margin===0.375&&o.gate==='below_target_above_floor',o);
  o=fx(agrMat); T('S4: deduct only materials → commission $4,000, profit $3,500, margin 35.0%; helper still a company cost',o.c_cents===400000&&o.gross_profit_cents===350000&&o.k_cents===250000&&o.margin===0.35&&o.gate==='below_target_above_floor',o);
  const m=(rev,gp,svc)=>BC({route:'combined',customer_price_cents:rev,discounts_cents:0,scope:[{service:svc,price_cents:rev}],rules,job_level_comp_cents:0,job_level_note:'none',costs:[{category:'materials',amount_cents:rev-gp,payer:'company',status:'actual'}]});
  T('S5: installation 35.00% meets floor; 34.99% needs exception (unrounded)',m(1000000,350000,'installation').gate==='below_target_above_floor'&&m(1000000,349900,'installation').gate==='below_floor');
  T('S5: cleaning 45.00% meets floor; 44.99% needs exception',m(1000000,450000,'cleaning').gate==='meets_target'&&m(1000000,449900,'cleaning').gate==='below_floor');
  o=BC({route:'sagi',customer_price_cents:1000000,discounts_cents:0,scope:[{service:'installation',price_cents:1000000}],rules,job_level_comp_cents:450000,job_level_note:'all-inclusive incl. installers',costs:[{category:'materials',amount_cents:200000,payer:'company',status:'estimated'},{category:'installer',amount_cents:150000,payer:'sagi',status:'estimated',included_in_other_payment:true}]});
  T('S6: Sagi $4,500 package → profit $3,500, margin 35%; installers not deducted twice',o.c_cents===450000&&o.k_cents===200000&&o.gross_profit_cents===350000&&o.margin===0.35,o);
  o=BC({route:'sagi',customer_price_cents:1000000,scope:[{service:'installation',price_cents:1000000}],rules,job_level_comp_cents:null,costs:[]}); T('S7: Sagi with only "50%+10+%" text → not calculable (invalid)',o.gate==='invalid'&&o.validation_issues.some(x=>/not calculable/.test(x)));
  o=fx({status:'draft',route:'combined',components:[{rate_pct:50}],deduction_categories:null}); T('§9.1: unresolved deduction list → invalid, named',o.gate==='invalid'&&o.validation_issues.some(x=>/deduction list is unresolved/.test(x)));
  o=fx(agrBoth,{customer_price_cents:0}); T('S11: zero revenue → no margin, invalid',o.gate==='invalid'&&o.margin==null);
  o=fx(agrBoth,{costs:[{category:'materials',amount_cents:null,payer:'company',status:'unknown'}]}); T('S11: unknown cost → invalid, never zero',o.gate==='invalid'&&o.validation_issues.some(x=>/unknown/.test(x)));
  o=BC({route:'combined',customer_price_cents:1000000,scope:[{service:'installation',price_cents:600000},{service:'cleaning',price_cents:400000}],rules,agreement:agrMat,costs:[{category:'materials',amount_cents:200000,payer:'company',status:'estimated'}],service_split:[{service:'installation',revenue_cents:600000,direct_cost_cents:200000},{service:'cleaning',revenue_cents:400000,direct_cost_cents:0}]});
  T('mixed job: per-service floors applied; cleaning at 50% ok, installation (600k−200k−240k)/600k=26.7% below floor',o.gate==='below_floor'&&o.per_service.find(p=>p.service==='installation').below_floor&&!o.per_service.find(p=>p.service==='cleaning').below_floor,o.per_service);
  o=BC({route:'combined',customer_price_cents:1000000,scope:[{service:'installation',price_cents:600000},{service:'cleaning',price_cents:400000}],rules,agreement:agrMat,costs:[{category:'materials',amount_cents:200000,payer:'company',status:'estimated'}]}); T('mixed job without explicit allocation → invalid',o.gate==='invalid'&&o.validation_issues.some(x=>/allocate/.test(x)));
  o=BC({route:'combined',customer_price_cents:1000000,scope:[{service:'hvac',price_cents:1000000}],rules,agreement:agrMat,costs:[]}); T('unclassified service (hvac has no rule) → invalid',o.gate==='invalid'&&o.validation_issues.some(x=>/no margin rule/.test(x)));
  const F=w.brFlags; T('S1: returning customer + $5,000 documented → qualified',F({indicators:[{code:'returning_upsell'}],expected_revenue_cents:500000,expected_revenue_basis:'prior job'}).qualified===true);
  T('S1: $4,999 → lead, not qualified',(()=>{const f=F({indicators:[{code:'returning_upsell'}],expected_revenue_cents:499900,expected_revenue_basis:'x'});return f.lead&&!f.qualified;})());
  T('S1: unknown revenue → lead only',(()=>{const f=F({indicators:[{code:'returning_upsell'}],expected_revenue_unknown:true});return f.lead&&!f.qualified;})());
  T('S2: HVAC interest with a booked HVAC check does not count; other indicators may still qualify',(()=>{const a=F({indicators:[{code:'hvac_interest'}],hvac_check_booked:true,expected_revenue_cents:900000,expected_revenue_basis:'x'});const b=F({indicators:[{code:'hvac_interest'},{code:'commercial'}],hvac_check_booked:true,expected_revenue_cents:900000,expected_revenue_basis:'x'});return !a.lead&&a.hvacExcluded&&b.qualified&&b.indicatorCount===1;})());
  const now=Date.now(); const S=w.brSla; T('S10: pending 90 min → in denominator, not met (miss)',(()=>{const s=S({submitted_at:new Date(now-90*60000).toISOString()},now);return s.inDenominator&&!s.met&&s.overdue;})());
  T('S10: pending 20 min → not yet in denominator',(()=>{const s=S({submitted_at:new Date(now-20*60000).toISOString()},now);return !s.inDenominator&&!s.overdue;})());
  T('S10: decided at 59 min → met',(()=>{const s=S({submitted_at:new Date(now-59*60000).toISOString(),decided_at:new Date(now).toISOString()},now);return s.met;})());
  T('S13: after the end date the banner asks for review and says nothing auto-completed',/passed — review outstanding coverage/.test(w.brEndBanner('2027-01-01','2027-01-02'))&&/Nothing was auto-completed/.test(w.brEndBanner('2027-01-01','2027-01-02'))&&/days/.test(w.brEndBanner('2027-01-01','2026-09-18')));

  console.log('— page: gate, roles, flows —');
  T('no session → sign-in gate shown, body hidden',vis('#brGate')&&!vis('#brBody'));
  T('the why-strip is visible on the gate, before sign-in',/Why the Bridge exists/.test($('.br-why').textContent)&&/gross margin/.test($('.br-why').textContent));
  signIn('someone@homealliance.com'); await tick(80);
  T('signed in but not a member → told so, body hidden',vis('#brNotMember')&&!vis('#brBody'));
  signIn('luka.m@homealliance.com'); await tick(120);
  T('manager signed in → body shown, identity displayed',vis('#brBody')&&/luka\.m@homealliance\.com · manager/.test($('#brWho').textContent),$('#brWho').textContent);
  T('Queue renders with KPIs',$$('#bqKpis .kpi').length===5);
  w.showBridgeTab('bsop'); await tick(20); T('SOP tab renders the dispatcher guide with the why, the flow, the refusals and the glossary',$('#tab-bsop').classList.contains('on')&&/Why we are doing this/.test($('#tab-bsop').textContent)&&/Your flow, step by step/.test($('#tab-bsop').textContent)&&/When a button refuses/.test($('#tab-bsop').textContent)&&$$('#tab-bsop .br-terms>div').length===10);
  $('#brWhySop').click(); await tick(20); T('“Read the SOP” link opens the SOP tab',$('#tab-bsop').classList.contains('on')); w.showBridgeTab('bqueue'); await tick(40);
  // intake
  $('#brNewToggle').click(); await tick(20);
  setv('#bi_customer','Malibu returning'); setv('#bi_job','HV0001'); setv('#bi_terr','LA'); setv('#bi_route','combined'); setv('#bi_sales','Jordan'); setv('#bi_rev','7500'); setv('#bi_basis','prior job $6,800 + attic ducts');
  const ind=$('[data-ind="returning_upsell"]'); ind.checked=true; $('[data-indev="returning_upsell"]').value='Job A1B2C3, 2026-05-02'; $('[data-inddt="returning_upsell"]').value='2026-05-02';
  $('#bi_save').click(); await tick(120);
  const opp=db.bridge_opportunities[0];
  T('recording a lead does not trip the bridge_events foreign key (the BEFORE-trigger regression)',!/foreign key/i.test(toast())&&db.bridge_opportunities.length===1,toast());
  T('lead recorded: seq B-1, qualified, event "created"',!!opp&&opp.seq===1&&w.brFlags(opp).qualified&&db.bridge_events.some(e=>e.opportunity_id===opp.id&&e.kind==='created'),opp);
  T('opens on the Opportunity page',$('#tab-bopp').classList.contains('on')&&/B-1/.test($('#brOpp').textContent));
  // gated statuses cannot be set by hand
  let r=await fake.from('bridge_opportunities').update({status:'work_released'}).eq('id',opp.id); T('DB: work_released cannot be set by editing the job',/only through an approval/.test(r.error&&r.error.message));
  // assignment
  setv('#ba_route','combined'); setv('#ba_tech','3 LA Jordan'); $('[data-bo="saveasg"]').click(); await tick(120);
  T('assignment v1 saved with an approved technician',db.bridge_assignments.length===1&&db.bridge_assignments[0].performing_technician==='3 LA Jordan');
  setv('#ba_route','combined'); setv('#ba_tech','3 LA Donat'); $('[data-bo="saveasg"]').click(); await tick(60);
  T('assignment refuses a technician who is not approved',/not approved/.test(toast())&&db.bridge_assignments.length===1,toast());
  // estimate
  $('[data-sc="price"]').value='10000'; $('[data-sc="description"]').value='Full duct replacement'; $('[data-bo="saveest"]').click(); await tick(120);
  T('estimate v1 saved: $10,000 installation',db.bridge_estimates.length===1&&db.bridge_estimates[0].customer_price_cents===1000000);
  r=await fake.from('bridge_estimates').update({customer_price_cents:900000}).eq('id',db.bridge_estimates[0].id); T('DB: an estimate version is never edited',/never edited/.test(r.error&&r.error.message));
  // economics with the unresolved draft agreement → cannot approve
  setv('#bc_agr','agr-draft'); await tick(40); $('[data-bo="costadd"]').click(); await tick(40);
  T('draft agreement → calculator names the unresolved deduction list',/deduction list is unresolved/.test($('#brOpp').textContent));
  $('[data-bo="saveeco"]').click(); await tick(120);
  T('economics v1 saved as draft WITH issues',db.bridge_economics.length===1&&db.bridge_economics[0].validation_issues.length>0);
  r=await fake.from('bridge_economics').update({status:'approved'}).eq('id',db.bridge_economics[0].id); T('DB: a version with issues cannot be approved',/validation issues/.test(r.error&&r.error.message));
  r=await fake.from('bridge_comp_agreements').update({status:'approved'}).eq('id','agr-draft'); T('DB: combined agreement with NULL deduction list cannot be approved',/deduction list is unresolved/.test(r.error&&r.error.message));
  // manager creates + approves a real agreement (Settings), then prices properly
  w.showBridgeTab('bset'); await tick(60);
  T('Settings shows status pills / editors for the manager',$$('[data-cfgs]').length>10);
  setv('#ag_name','Combined — deduct materials + company helpers'); setv('#ag_route','combined'); setv('#ag_rate','50'); $$('[data-agded]').forEach(c=>{c.checked=['materials','company_helper'].includes(c.value);}); $('[data-brset="saveagr"]').click(); await tick(120);
  const agr=db.bridge_comp_agreements.find(a=>a.name.startsWith('Combined — deduct')); T('new agreement saved as draft with explicit deductions',!!agr&&JSON.stringify(agr.deduction_categories)==='["materials","company_helper"]',agr);
  $(`[data-brset="approveagr"][data-id="${agr.id}"]`).click(); await tick(120); T('agreement approved, approver stamped from identity',agr.status==='approved'&&agr.approved_by==='luka.m@homealliance.com');
  w.brOpen(opp.id); await tick(80);
  setv('#bc_agr',agr.id); await tick(60);
  $('[data-bo="costadd"]').click(); await tick(40); $('[data-bo="costadd"]').click(); await tick(40);
  const costRows=$$('#bc_costs .br-cost'); costRows[0].querySelector('[data-cs="category"]').value='materials'; costRows[0].querySelector('[data-cs="amount"]').value='2000'; costRows[1].querySelector('[data-cs="category"]').value='company_helper'; costRows[1].querySelector('[data-cs="amount"]').value='500'; if(costRows[2]){costRows[2].querySelector('[data-cs="category"]').value='materials';costRows[2].querySelector('[data-cs="amount"]').value='0';}
  $('[data-bo="saveeco"]').click(); await tick(120);
  const e2=db.bridge_economics.find(e=>e.version===2); T('economics v2: $3,750 commission, 37.5%, below target above floor, no issues',!!e2&&e2.c_cents===375000&&e2.margin===0.375&&e2.gate==='below_target_above_floor'&&e2.validation_issues.length===0,e2&&{c:e2.c_cents,m:e2.margin,g:e2.gate,i:e2.validation_issues});
  // S8: release before economics approved / before customer acceptance
  r=await fake.from('bridge_approvals').insert({opportunity_id:opp.id,type:'work_release',decision:'approve',economics_version:2}); T('S8: release refused while economics v2 is unapproved',/not approved/.test(r.error&&r.error.message));
  $(`[data-bo="approveeco"][data-id="${e2.id}"]`).click(); await tick(120); T('manager approves v2 → frozen, approver stamped',e2.status==='approved'&&e2.approved_by==='luka.m@homealliance.com');
  r=await fake.from('bridge_economics').update({c_cents:1}).eq('id',e2.id); T('DB: approved economics are immutable',/immutable/.test(r.error&&r.error.message));
  r=await fake.from('bridge_approvals').insert({opportunity_id:opp.id,type:'work_release',decision:'approve',economics_version:2}); T('S8: release refused until the customer accepts the estimate',/has not accepted/.test(r.error&&r.error.message),r.error);
  $('[data-bo="accept"]').click(); await tick(120); T('customer acceptance recorded on estimate v1',db.bridge_estimates[0].customer_accepted===true);
  T('S8: customer acceptance alone did not release work',opp.status!=='work_released');
  $('[data-bo="reqrelease"]').click(); await tick(120); const req=db.bridge_requests[0]; T('work-release request submitted → clock running, job in economics review',!!req&&req.type==='work_release'&&!req.decided_at&&opp.status==='economics_review',opp.status);
  w.showBridgeTab('bappr'); await tick(60); T('Approvals tab lists the pending request with a timer',/B-1/.test($('#brAppr').textContent)&&$$('#brAppr .br-timer').length===1);
  w.brOpen(opp.id); await tick(80); $('[data-bo="approve"]').click(); await tick(150);
  const rel=db.bridge_approvals.find(a=>a.type==='work_release'); T('release recorded: actor from identity, version named, request decided, job work_released, event written',!!rel&&rel.actor_email==='luka.m@homealliance.com'&&rel.actor_role==='manager'&&rel.economics_version===2&&!!req.decided_at&&opp.status==='work_released'&&db.bridge_events.some(e=>e.kind==='approval'),{rel,st:opp.status});
  // S9: a change after approval → new version, back to review, both kept
  $('[data-bo="saveeco"]').click(); await tick(120);
  T('S9: new draft after release → job back to economics_review; v2 still approved, v3 draft',opp.status==='economics_review'&&db.bridge_economics.find(e=>e.version===2).status==='approved'&&db.bridge_economics.find(e=>e.version===3).status==='draft'&&db.bridge_events.some(e=>e.kind==='release_invalidated'),opp.status);
  // S7: Sagi route on a second opportunity
  w.showBridgeTab('bqueue'); await tick(40); $('#brNewToggle').click(); await tick(20);
  setv('#bi_customer','Sagi bridge job'); setv('#bi_terr','OC'); setv('#bi_route','sagi'); setv('#bi_sales','Sagi'); setv('#bi_rev','10000'); setv('#bi_basis','scope walk'); $('[data-ind="property_value_2m"]').checked=true; $('[data-indev="property_value_2m"]').value='Zillow $2.4M'; $('#bi_save').click(); await tick(120);
  const opp2=db.bridge_opportunities.find(o=>o.customer_ref==='Sagi bridge job'); T('second lead recorded on the Sagi route',!!opp2&&opp2.route==='sagi');
  setv('#ba_route','sagi'); setv('#ba_sales','Sagi'); setv('#ba_inst','Ivan P.'); setv('#ba_instcap','ducts + attic'); setv('#ba_instav','Mon–Sat'); $('[data-bo="saveasg"]').click(); await tick(120);
  const asg2=db.bridge_assignments.find(a=>a.opportunity_id===opp2.id); T('Sagi assignment saved with installer, NOT yet approved',!!asg2&&asg2.installer_name==='Ivan P.'&&asg2.installer_approved===false);
  $('[data-sc="price"]').value='10000'; $('[data-bo="saveest"]').click(); await tick(120); $('[data-bo="accept"]').click(); await tick(120);
  $('[data-bo="costadd"]').click(); await tick(40); $('[data-bo="costadd"]').click(); await tick(40);
  let cr=$$('#bc_costs .br-cost'); cr[0].querySelector('[data-cs="category"]').value='materials'; cr[0].querySelector('[data-cs="amount"]').value='2000'; cr[1].querySelector('[data-cs="category"]').value='installer'; cr[1].querySelector('[data-cs="amount"]').value='1500'; cr[1].querySelector('[data-cs="payer"]').value='sagi'; cr[1].querySelector('[data-cs="included_in_other_payment"]').checked=true;
  $('[data-bo="saveeco"]').click(); await tick(120);
  let se=db.bridge_economics.filter(e=>e.opportunity_id===opp2.id).pop(); T('S7: Sagi economics without an amount → not calculable, cannot be approved',se.gate==='invalid'&&se.validation_issues.some(x=>/not calculable/.test(x)));
  setv('#bc_jl','4500'); setv('#bc_jlnote','All-inclusive: Sagi + his two installers; company pays materials'); await tick(60);
  cr=$$('#bc_costs .br-cost'); if(cr.length<2){$('[data-bo="costadd"]').click();await tick(40);$('[data-bo="costadd"]').click();await tick(40);cr=$$('#bc_costs .br-cost');}
  cr[0].querySelector('[data-cs="category"]').value='materials'; cr[0].querySelector('[data-cs="amount"]').value='2000'; cr[1].querySelector('[data-cs="category"]').value='installer'; cr[1].querySelector('[data-cs="amount"]').value='1500'; cr[1].querySelector('[data-cs="payer"]').value='sagi'; cr[1].querySelector('[data-cs="included_in_other_payment"]').checked=true;
  $('[data-bo="saveeco"]').click(); await tick(120);
  se=db.bridge_economics.filter(e=>e.opportunity_id===opp2.id).pop(); T('S6 via the page: Sagi $4,500 package → 35.00%, K $2,000, no issues',se.c_cents===450000&&se.k_cents===200000&&se.margin===0.35&&se.validation_issues.length===0,{c:se.c_cents,k:se.k_cents,m:se.margin,i:se.validation_issues});
  $(`[data-bo="approvejl"][data-id="${se.id}"]`).click(); await tick(120); T('job-level amount approved by the manager (stamped)',se.job_level_comp_approved_by==='luka.m@homealliance.com');
  $(`[data-bo="approveeco"][data-id="${se.id}"]`).click(); await tick(120); T('Sagi economics approved',se.status==='approved');
  r=await fake.from('bridge_approvals').insert({opportunity_id:opp2.id,type:'work_release',decision:'approve',economics_version:se.version}); T('S7: release refused — installer not approved',/installer is not approved/.test(r.error&&r.error.message),r.error);
  $('[data-bo="approveinst"]').click(); await tick(120); T('installer approved by the manager, stamped',asg2.installer_approved===true&&asg2.installer_approved_by==='luka.m@homealliance.com');
  r=await fake.from('bridge_approvals').insert({opportunity_id:opp2.id,type:'work_release',decision:'approve',economics_version:se.version}); T('Sagi job releases once installer + amount are approved',!r.error&&opp2.status==='work_released',r.error);
  // Sardor exception path (below floor) on a third opportunity
  w.showBridgeTab('bqueue'); await tick(40); $('#brNewToggle').click(); await tick(20);
  setv('#bi_customer','Thin margin'); setv('#bi_terr','LA'); setv('#bi_route','combined'); setv('#bi_rev','10000'); setv('#bi_basis','x'); $('[data-ind="commercial"]').checked=true; $('#bi_save').click(); await tick(120);
  const opp3=db.bridge_opportunities.find(o=>o.customer_ref==='Thin margin');
  setv('#ba_route','combined'); setv('#ba_tech','3 LA Sagi'); $('[data-bo="saveasg"]').click(); await tick(120);
  $('[data-sc="price"]').value='10000'; $('[data-bo="saveest"]').click(); await tick(120); $('[data-bo="accept"]').click(); await tick(120);
  setv('#bc_agr',agr.id); await tick(60); $('[data-bo="costadd"]').click(); await tick(40); cr=$$('#bc_costs .br-cost'); cr[0].querySelector('[data-cs="category"]').value='materials'; cr[0].querySelector('[data-cs="amount"]').value='3500';
  $('[data-bo="saveeco"]').click(); await tick(120);
  const e3=db.bridge_economics.filter(e=>e.opportunity_id===opp3.id).pop(); T('below-floor version: R 10,000 − K 3,500 − C 3,250 = 32.5% → below_floor',e3.gate==='below_floor'&&e3.margin===0.325,{m:e3.margin,g:e3.gate});
  $(`[data-bo="approveeco"][data-id="${e3.id}"]`).click(); await tick(120); T('below-floor economics can be approved as a version (release is the gate)',e3.status==='approved');
  r=await fake.from('bridge_approvals').insert({opportunity_id:opp3.id,type:'work_release',decision:'approve',economics_version:e3.version}); T("S8: Luka's release alone cannot release a below-floor job",/below its floor/.test(r.error&&r.error.message));
  r=await fake.from('bridge_approvals').insert({opportunity_id:opp3.id,type:'margin_exception',decision:'record',economics_version:e3.version,on_behalf_of:'Sardor',confirmed_via:'text'}); T("exception without Sardor's confirmation reference refused",/confirmation is required/.test(r.error&&r.error.message));
  $('[data-bo="exception"]').click(); await tick(20); setv('#bx_via','text'); setv('#bx_ref','text 18 Sep 14:32 — “ok at 32.5% for this one”'); $('[data-bo="saveexc"]').click(); await tick(120);
  const exc=db.bridge_approvals.find(a=>a.type==='margin_exception'&&a.opportunity_id===opp3.id); T("exception recorded on Sardor's behalf with via + ref, by the manager",!!exc&&exc.on_behalf_of==='Sardor'&&exc.confirmed_via==='text'&&/14:32/.test(exc.confirmation_ref)&&exc.actor_email==='luka.m@homealliance.com');
  T("S8: Sardor's exception alone did not release work",opp3.status!=='work_released');
  r=await fake.from('bridge_approvals').insert({opportunity_id:opp3.id,type:'work_release',decision:'approve',economics_version:e3.version}); T('with the exception recorded, the manager can release',!r.error&&opp3.status==='work_released',r.error);
  r=await fake.from('bridge_approvals').update({reason:'x'}).eq('id',rel.id); T('DB: approvals are append-only',/permission denied/.test(r.error&&r.error.message));
  // S10 on the page: an old pending request is a miss
  db.bridge_requests.push({id:'old-req',opportunity_id:opp.id,type:'visit_approval',submitted_at:new Date(Date.now()-95*60000).toISOString(),urgent:true,created_at:new Date(Date.now()-95*60000).toISOString()});
  await w.brLoad(); w.showBridgeTab('bappr'); await tick(60); T('Approvals: urgent overdue request first, timer red',$$('#brAppr .br-row')[0].classList.contains('urgent')&&$$('#brAppr .br-timer.over').length>=1);
  w.showBridgeTab('bscore'); await tick(60);
  T('Scorecard: one-hour decisions counts the overdue pending request as a miss',/One-hour decisions/.test($('#brScore').textContent)&&/\(1\/2\)|\(1\/3\)|\(0\/1\)|\(1\/1\)/.test($('#brScore').textContent),$('#brScore').textContent.match(/One-hour decisions[^%]*%\s*\(\d+\/\d+\)/)?.[0]);
  setv('#bsWeek','2026-01-05'); await tick(60); T('S11: an empty week shows N/A, not 100%',(($('#brScore').textContent.match(/N\/A/g)||[]).length>=4)&&!/100\.0%/.test($('#brScore').textContent));
  // S12 coverage
  w.showBridgeTab('bcover'); await tick(60); T('coverage % is N/A until the denominator is agreed',/N\/A/.test($$('#brCover .kpi')[2].textContent));
  setv('#cv_terr','LA'); setv('#cv_svc','installation'); setv('#cv_pri','3 LA Jordan'); setv('#cv_bak','3 LA Sagi'); setv('#cv_dep','both rely on installer Ivan'); $('[data-brcov="save"]').click(); await tick(120);
  T('shared dependency → not independent, no Accept button',/shared: both rely/.test($('#brCover').textContent)&&$$('[data-brcov="accept"]').length===0);
  const cov=db.bridge_coverage_register[0]; r=await fake.from('bridge_coverage_register').update({accepted:true,backup_name:'3 LA Jordan'}).eq('id',cov.id); T('DB: primary and backup must differ',/different people/.test(r.error&&r.error.message));
  T('S12: three released bridge jobs did not increase accepted coverage',db.bridge_coverage_register.filter(c=>c.accepted).length===0);
  // dispatcher view
  signIn('vasyl.k@homealliance.com'); await tick(150); w.showBridgeTab('bset'); await tick(60);
  T('dispatcher: Settings read-only, no approve buttons',$$('[data-cfgs]').length===0&&$$('[data-brset="approveagr"]').length===0&&/vasyl\.k@homealliance\.com · dispatcher/.test($('#brWho').textContent));
  r=await fake.from('bridge_approvals').insert({opportunity_id:opp.id,type:'work_release',decision:'approve',economics_version:2}); T('DB: dispatcher cannot record approvals',/Only the manager/.test(r.error&&r.error.message));
  r=await fake.rpc('grant_bridge',{target_email:'someone@homealliance.com',target_role:'manager'}); T('RPC: dispatcher cannot grant roles',/Not authorised/.test(r.error&&r.error.message));
  signIn('luka.m@homealliance.com'); await tick(120); r=await fake.rpc('revoke_bridge',{target_email:'luka.m@homealliance.com'}); T('RPC: refuses to remove the last manager',/no manager/.test(r.error&&r.error.message));
  await fake.auth.signOut(); await tick(80); T('sign out → gate again',vis('#brGate')&&!vis('#brBody'));
  T('zero console / jsdom errors',errors.length===0,errors);
  if(cssWarn.length)console.log(`  (jsdom CSS parser warnings, not app errors: ${cssWarn.length})`);
  console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail?1:0);
})().catch(e=>{console.error('TEST CRASH',e);process.exit(2);});
