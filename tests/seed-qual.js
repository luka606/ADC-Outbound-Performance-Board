/* Seed for the qualification tests: technicians, two Bridge members, the draft metric v1 exactly as qualification_schema.sql seeds it,
   a Coverage-log row for the import test, empty qual_* tables. */
(function(root){
function makeDb(){
  const techs=['1 Shams','3 Edward','3 LA Donat','3 LA Jordan','3 LA Miguel','3 LA Sagi','3 Miami Howard','3 OC Jimmy','3 SD Elisha','3 SF Alex','4 Ventura Vram'];
  const v1={id:'ver-1',version:1,label:'v1 — proposed defaults from the M4 brief (2026-09-23)',status:'draft',effective_from:null,used_in_decision:false,change_note:'Seeded from the M4 brief §4–§7 as a draft.',
    categories:[
      {key:'sales',label:'Sales effectiveness',weight_pct:20,direction:'higher',status:'confirmed',formula:'won qualified estimates ÷ decision-eligible qualified estimates',target:'≥ 50% close rate',bands:{p100:50,p70:40,p40:30}},
      {key:'revenue',label:'Revenue efficiency',weight_pct:15,direction:'higher',status:'unresolved',formula:'sold revenue ÷ qualified leads assigned, as % of the approved baseline',target:'≥ 100% of the approved baseline',bands:{p100:100,p70:85,p40:70}},
      {key:'coverage',label:'Coverage reliability',weight_pct:15,direction:'higher',status:'proposed',formula:'eligible assignments fulfilled ÷ eligible assignments offered',target:'≥ 95%',bands:{p100:95,p70:90,p40:80}},
      {key:'attendance',label:'Attendance',weight_pct:10,direction:'higher',status:'proposed',formula:'on-time attended ÷ scheduled responsible appointments',target:'≥ 95% and no unexplained no-show',bands:{p100:95,p70:90,p40:85}},
      {key:'completion',label:'Completion reliability',weight_pct:15,direction:'higher',status:'proposed',formula:'compliant on-time completions ÷ jobs due',target:'≥ 95%',bands:{p100:95,p70:90,p40:85}},
      {key:'quality',label:'Customer quality',weight_pct:15,direction:'lower',status:'proposed',formula:'jobs with a substantiated issue ÷ eligible completed jobs',target:'≤ 5% and no unresolved severe incident',bands:{p100:5,p70:10,p40:15}},
      {key:'compliance',label:'Compliance',weight_pct:10,direction:'higher',status:'proposed',formula:'passed required checks ÷ required checks; every critical check must pass',target:'100% critical and ≥ 95% overall',bands:{p100:95,p70:90,p40:80}}],
    gates:[{key:'critical_compliance'},{key:'no_unresolved_severe'},{key:'no_active_restriction'},{key:'no_confirmed_critical'}],
    evidence:{window_days:28,min_qualified_estimates:10,min_completed_jobs:5,supervised_jobs:3,decision_age_days:{value:null,status:'unresolved'}},
    windows:{quality_observation_days:{value:30,status:'proposed'},on_time_grace_minutes:{value:null,status:'unresolved'},timezone:{value:'America/Los_Angeles',status:'proposed'},week_start:{value:'monday',status:'proposed'}},
    revenue:{baseline_cents:{value:null,status:'unresolved'},credit_point:{value:'sold',status:'proposed'},segmented_by:{value:null,status:'unresolved'}},
    outcome_rules:{pass_min:80,coaching_min:70,probation_min:60,probation_days:{value:null,status:'unresolved'},coaching_repeat_to_probation:2,membership_change_restarts:{value:null,status:'unresolved'}},
    critical_events:[{code:'unsafe_work',label:'Unsafe work or deliberate disregard of a safety requirement',status:'proposed'},{code:'payment_fraud',label:'Payment mishandling, theft, fraud or falsified records',status:'proposed'},{code:'unauthorized_pricing',label:'Deliberate unauthorized pricing, financing or job-start behavior',status:'proposed'},{code:'license_failure',label:'Required license, authorization or insurance failure',status:'proposed'},{code:'abandonment',label:'Abandonment of an active customer job without an approved handoff',status:'proposed'},{code:'severe_harm',label:'Severe customer harm or property damage from reckless or prohibited behavior',status:'proposed'}],
    margin_rules:{installation:{target_pct:40,floor_pct:35},cleaning:{floor_pct:45},status:'confirmed'},created_at:'2026-09-23T00:00:00Z'};
  const empty=['qual_teams','qual_team_members','qual_availability','qual_leads','qual_lead_estimates','qual_appointments','qual_jobs','qual_job_reschedules','qual_coverage_events','qual_quality_events','qual_compliance_checks','qual_exclusions','qual_supervised_jobs','qual_incidents','qual_restrictions','qual_snapshots','qual_decisions','qual_actions','qual_reviews','qual_audit','bridge_opportunities','bridge_assignments'];
  const db={technicians:techs.map((name,i)=>({id:'t'+i,name,active:true,approved:true,areas:(name.match(/^\d+\s+(LA|OC|SD|SF|Miami|Ventura)\s/)||[])[1]||null,job_types:'both'})),
    __users:[{id:'u-luka',email:'luka.m@homealliance.com'},{id:'u-tom',email:'tom@5starair.pro'},{id:'u-x',email:'someone@homealliance.com'}],
    bridge_roles:[{user_id:'u-luka',email:'luka.m@homealliance.com',role:'manager'},{user_id:'u-tom',email:'tom@5starair.pro',role:'dispatcher'}],
    qual_metric_versions:[v1],
    coverage_log:[{id:'cl-1',log_date:'2026-09-20',time_local:'09:15',lead_ref:'A1B2C3',area:'LA',job_date:'2026-09-21',original_assignee:'3 LA Sagi',issue:'unavailable',offered_names:['3 LA Donat','3 LA Jordan'],final_assignee:'3 LA Donat',outcome:'reassigned'}]};
  empty.forEach(t=>db[t]=[]);return db;
}
root.__makeQualDb=makeDb; if(typeof module!=='undefined'&&module.exports)module.exports={makeDb};
})(typeof globalThis!=='undefined'?globalThis:this);
