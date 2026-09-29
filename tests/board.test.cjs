/* The board (index.html) — Tower shell and the Job Assignment Daily Meeting. Run: npm test */
const {JSDOM,VirtualConsole}=require('jsdom'); const fs=require('fs');
const {makeFake}=require('./fake-board.js'); const {makeDb}=require('./seed-board.js');
const html=fs.readFileSync(process.argv[2],'utf8');
const pt=new Date(new Date().toLocaleString('en-US',{timeZone:'America/Los_Angeles'}));const TODAY=`${pt.getFullYear()}-${String(pt.getMonth()+1).padStart(2,'0')}-${String(pt.getDate()).padStart(2,'0')}`;
let pass=0,fail=0; const T=(n,c,x)=>{if(c){pass++;console.log('  ✓',n);}else{fail++;console.log('  ✗',n,x!==undefined?JSON.stringify(x).slice(0,400):'');}};
const tick=(ms=60)=>new Promise(r=>setTimeout(r,ms));
function mount(db,{admin=false}={}){
  const errors=[]; const vc=new VirtualConsole();
  vc.on('jsdomError',e=>{if(!/Could not parse CSS/.test(e.message))errors.push('jsdomError: '+e.message.split('\n')[0]);}); vc.on('error',(...a)=>errors.push('console.error: '+a.join(' ')));['warn','log','info','debug'].forEach(k=>vc.on(k,()=>{}));
  const fake=makeFake(db);
  const dom=new JSDOM(html,{url:'http://localhost/index.html',runScripts:'dangerously',pretendToBeVisual:true,virtualConsole:vc,beforeParse(w){
    w.localStorage.setItem('adc_supabase_cfg',JSON.stringify({url:'http://fake.local',key:'fake'}));
    if(admin)w.sessionStorage.setItem('adc_admin_session','1');
    w.sessionStorage.setItem('adc_sales_session','Tom');   // skips the Office Sales PIN prompt
    w.supabase={createClient:()=>fake}; w.confirm=()=>true; w.prompt=()=>null; w.alert=()=>{}; w.scrollTo=()=>{}; w.HTMLElement.prototype.scrollIntoView=function(){};
  }});
  const w=dom.window,d=w.document;
  return {w,d,fake,errors,$:s=>d.querySelector(s),$$:s=>[...d.querySelectorAll(s)]};
}
(async()=>{
  console.log('— shell —');
  let db=makeDb(TODAY); let {w,d,fake,errors,$,$$}=mount(db);
  await tick(300);
  T('boots signed in to the anon board: not logged-out, sidebar present, ADC group open',!d.body.classList.contains('logged-out')&&!!$('#sbNav')&&$('[data-wsgroup=adc]').classList.contains('open'));
  T('ADC Outbound tabs are rendered into the sidebar (no Admin tab for a non-admin)',$$('#sbKidsAdc .sb-tab').map(b=>b.dataset.tab).join()==='report,meeting,scorecard,database,sop');
  T('header shows the PT date, the brand label and Admin',/\b20\d\d\b/.test($('#hdrDate').textContent)&&$('#wsLabel').textContent==='ADC OUTBOUND'&&$('#adminBtn').textContent==='Admin');
  T('the old brand dropdown and pill navs are gone',!$('#wsMenu')&&!$('#navJobs')&&!$('#navSales')&&!$('#nav'));
  T('Bridge and Qualification are sidebar links to their own pages',$$('#sbNav a.sb-ws').map(a=>a.getAttribute('href')).join()==='bridge.html,qualification.html');
  $('#sbNav [data-tab="scorecard"]').click(); await tick(120);
  T('ADC tab click renders the Scorecard view in #app and lights the row',$('#sbNav [data-tab="scorecard"]').classList.contains('on')&&/scorecard|Scorecard/.test($('#app').innerHTML)&&$('#app').style.display!=='none');
  $('#sbNav button[data-ws="jobs"]').click(); await tick(300);
  T('Job Assignment workspace opens on Meeting: root shown, group open, label, tab lit',$('#jobsRoot').style.display==='block'&&$('#app').style.display==='none'&&$('[data-wsgroup=jobs]').classList.contains('open')&&$('#wsLabel').textContent==='JOB ASSIGNMENT'&&$('#tab-jmeet').classList.contains('on')&&$('#sbNav [data-tab="jmeet"]').classList.contains('on'));
  T('workspace choice is remembered',w.localStorage.getItem('adc_ws')==='jobs');
  $('#sbToggle').click(); T('rail collapse toggles body.sb-rail and persists',d.body.classList.contains('sb-rail')&&w.localStorage.getItem('adc_sidebar')==='1'); $('#sbToggle').click();
  $('#sbNav button[data-ws="sales"]').click(); await tick(300);
  T('Office Sales opens (session unlocked) on Dashboard',$('#salesRoot').style.display==='block'&&$('#tab-sdash').classList.contains('on')&&$('#sbNav [data-tab="sdash"]').classList.contains('on'));
  $('#sbNav [data-tab="jbreak"]').click(); await tick(200);
  T('clicking a tab of another workspace switches workspace and tab together',$('#jobsRoot').style.display==='block'&&$('#tab-jbreak').classList.contains('on')&&$('[data-wsgroup=jobs]').classList.contains('open'));

  console.log('— Daily Meeting —');
  $('#sbNav [data-tab="jmeet"]').click(); await tick(300);
  const kpis=$$('#jmKpis .kpi').map(k=>k.querySelector('.v').textContent+' '+k.querySelector('.l').textContent);
  T('KPIs: 9 jobs · 6 ADC · 3 DVC · 4 technicians · 66.7% ADC · Not yet reviewed · flags',kpis[0]==='9 Jobs assigned'&&kpis[1]==='6 ADC jobs'&&kpis[2]==='3 DVC jobs'&&kpis[3]==='4 Technicians assigned'&&kpis[4]==='66.7% % ADC'&&/— Not yet reviewed/.test(kpis[5])&&/Flagged rows/.test(kpis[6]),kpis);
  T('note counts entries on the date',$('#jmNote').textContent===`5 entries on ${TODAY}`,$('#jmNote').textContent);
  T('four ranked cards, one dashed empty row for the approved technician without entries',$$('#jmList .lb-row').length===4&&$$('#jmList .lb-empty-row').length===1&&/3 LA Miguel/.test($('#jmList .lb-empty-row').textContent));
  T('default sort by jobs: Donat (4) first, rank badges present',/3 LA Donat/.test($('#jmList .lb-row').textContent)&&$('#jmList .lb-row .lb-rank').textContent==='#1');
  const donat=$$('#jmList .lb-row').find(r=>/3 LA Donat/.test(r.textContent));
  T('Donat: Jobs 4, ADC share 75.0%, Correct —, mix bar ADC+DVC segments and the team-average tick',donat.querySelector('.lb-stat .v').textContent==='4'&&/75\.0%/.test(donat.querySelector('.lb-stat.tp .v').textContent)&&donat.querySelector('.lb-stat.correct .v').textContent==='—'&&!!donat.querySelector('.mix-bar .p1')&&!!donat.querySelector('.mix-bar .p2')&&!!donat.querySelector('.avg-tick'));
  T('overload at the threshold (4 jobs) shows the dashed pill and flags the row',!!donat.querySelector('.ovl-pill')&&donat.classList.contains('flagged'));
  const shams=$$('#jmList .lb-row').find(r=>/1 Shams/.test(r.textContent));
  T('an unapproved technician gets the "not approved" flag pill',!!shams&&/not approved/.test(shams.querySelector('.flag-pill').textContent)&&shams.classList.contains('flagged'));
  T('Flagged rows KPI counts the two flagged cards',$$('#jmKpis .kpi')[6].querySelector('.v').textContent==='2');
  T('team average ADC share shown',/team avg ADC share: 67%/.test($('#jmAvg').textContent),$('#jmAvg').textContent);
  $('#jmSortBar [data-sort="adcLow"]').click(); await tick(30);
  T('sort by ADC share lowest first puts Jimmy (0% ADC) at #1 and persists the choice',/3 OC Jimmy/.test($('#jmList .lb-row').textContent)&&w.localStorage.getItem('adc_jm_sort')==='adcLow');
  $('#jmSortBar [data-sort="jobs"]').click(); await tick(30);
  $('#jmList [data-tech-open="3 LA Donat"]').click(); await tick(60);
  T('card opens the technician-day modal with KPIs, flag reasons and the rows; non-admin sees no verdict buttons',$('#repRoot').classList.contains('show')&&/3 LA Donat/.test($('#repRoot .rep-title .nm').textContent)&&$$('#repRoot .rep-kpi').length===5&&/overload threshold is 4/.test($('#repRoot').textContent)&&$$('#repRoot tbody tr').length===2&&$$('#repRoot .jb').length===0&&/not yet reviewed/.test($('#repRoot').textContent));
  $('#rp_next').click(); await tick(30); T('› moves to the next card in sort order',/3 LA Jordan|3 OC Jimmy/.test($('#repRoot .rep-title .nm').textContent));
  $('#rp_close').click(); T('× closes',!$('#repRoot').classList.contains('show'));
  $('#jmDate').value='2026-01-05'; $('#jmDate').dispatchEvent(new w.Event('change',{bubbles:true})); await tick(200);
  T('another date: KPIs zero, every approved technician is an empty row, Today/Yesterday pills both off',$('#jmKpis .kpi .v').textContent==='0'&&$$('#jmList .lb-row').length===0&&$$('#jmList .lb-empty-row').length===4&&$$('[data-jm-day].on').length===0);
  $('[data-jm-day="today"]').click(); await tick(200); T('Today pill returns to today',$('#jmDate').value===TODAY&&$('[data-jm-day="today"]').classList.contains('on'));
  T('Daily Entry keeps the assign form and the editable table, no KPIs',(()=>{w.showTab('jtoday');return !!$('#jaSave')&&!$('#jaKpis')&&$('#tab-jtoday h2').textContent==='Daily Entry';})());
  await tick(150); T('Daily Entry table lists the day\'s rows with a DVC badge',$$('#tblJToday tbody tr').length===5&&!!$('#tblJToday .badge.dvc'));
  $('#jaTech').value='3 LA Miguel'; $('#jaType').value='ADC'; $('#jaCount').value='2'; $('#jaSave').click(); await tick(200);
  T('Daily Entry upsert still works',db.job_assignments.some(r=>r.technician==='3 LA Miguel'&&r.jobs===2));
  w.showTab('jmeet'); await tick(200); T('Meeting reflects the new entry: 5 cards, Miguel no longer an empty row',$$('#jmList .lb-row').length===5&&$$('#jmList .lb-empty-row').length===0);
  T('zero console / jsdom errors (non-admin)',errors.length===0,errors);

  console.log('— admin verdict —');
  ({w,d,fake,errors,$,$$}=mount(db,{admin:true})); await tick(300);
  T('admin boot: Admin ✓, Admin tab in the sidebar',$('#adminBtn').textContent==='Admin ✓'&&!!$('#sbKidsAdc [data-tab="admin"]'));
  $('#sbNav button[data-ws="jobs"]').click(); await tick(300); $('#jmList [data-tech-open="3 LA Donat"]').click(); await tick(60);
  T('admin sees Correct / Not correct buttons per row',$$('#repRoot .jb').length===4);
  $('#repRoot .jb.no[data-jid="j2"]').click(); await tick(120);
  const j2=db.job_assignments.find(r=>r.id==='j2');
  T('"Not correct" writes justified=No with the stamp (trigger emulated)',j2.justified==='No'&&j2.justified_by==='Admin (board)'&&!!j2.justified_at);
  T('modal re-draws with the verdict lit; KPI tile flips to Correctly assigned 90.9% (1 of 11 jobs not correct)',$('#repRoot .jb.no[data-jid="j2"]').classList.contains('on')&&/Correctly assigned/.test($('#jmKpis').textContent)&&/90\.9%/.test($('#jmKpis').textContent),$('#jmKpis').textContent);
  T('card shows Correct 75.0% for Donat (1 of 4 jobs not correct)',/75\.0%/.test($$('#jmList .lb-row').find(r=>/3 LA Donat/.test(r.textContent)).querySelector('.lb-stat.correct .v').textContent));
  $('#repRoot .jb.no[data-jid="j2"]').click(); await tick(120);
  T('clicking the lit verdict again clears it and the stamp',db.job_assignments.find(r=>r.id==='j2').justified===null&&db.job_assignments.find(r=>r.id==='j2').justified_at===null&&/Not yet reviewed/.test($('#jmKpis').textContent));
  $('#repRoot .jb.yes[data-jid="j1"]').click(); await tick(120); T('"Correct" writes Yes',db.job_assignments.find(r=>r.id==='j1').justified==='Yes');
  T('zero console / jsdom errors (admin)',errors.length===0,errors);
  console.log(`\n${pass} passed, ${fail} failed`); process.exit(fail?1:0);
})().catch(e=>{console.error('TEST CRASH',e);process.exit(2);});
