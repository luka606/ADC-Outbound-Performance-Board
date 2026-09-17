(function(root){
function makeDb(){
  const techs=[['1 Shams',true,false],['3 Edward',true,false],['3 LA Donat',true,false],['3 LA Jordan',true,true],['3 LA Miguel',true,false],['3 LA Sagi',true,true],['3 Miami Howard',true,false],['3 OC Jimmy',false,true],['3 SD Elisha',true,false],['3 SF Alex',true,false],['4 Ventura Vram',true,false]];
  const cfg=(key,value,status,note)=>({key,value,status,note:note||null,updated_at:'2026-09-18T00:00:00Z'});
  return {
    technicians:techs.map(([name,active,approved],i)=>({id:'t'+i,name,active,approved,areas:(name.match(/^\d+\s+(LA|OC|SD|SF|Miami|Ventura)\s/)||[])[1]||null,job_types:approved?'both':null,default_type:null})),
    __users:[{id:'u-luka',email:'luka.m@homealliance.com'},{id:'u-vasyl',email:'vasyl.k@homealliance.com'},{id:'u-x',email:'someone@homealliance.com'}],
    bridge_roles:[{user_id:'u-luka',email:'luka.m@homealliance.com',role:'manager',added_at:'2026-09-18T00:00:00Z'},{user_id:'u-vasyl',email:'vasyl.k@homealliance.com',role:'dispatcher',added_at:'2026-09-18T00:00:00Z'}],
    bridge_config:[cfg('install_target_pct',40,'confirmed'),cfg('install_floor_pct',35,'confirmed'),cfg('cleaning_floor_pct',45,'confirmed'),
      cfg('service_rules',{installation:{target_pct:40,floor_pct:35},cleaning:{floor_pct:45}},'confirmed'),cfg('min_expected_revenue_cents',500000,'confirmed'),cfg('territories',['LA','OC'],'confirmed'),
      cfg('bridge_end_date','2027-01-01','confirmed'),cfg('decision_sla_minutes',60,'confirmed'),cfg('sla_basis',null,'unresolved'),cfg('timezone','America/Los_Angeles','proposed'),cfg('week_start','monday','proposed'),
      cfg('callback_window_days',30,'proposed'),cfg('combined_commission_pct',50,'confirmed'),cfg('hvac_indicator_requires_no_hvac_check',true,'confirmed'),
      cfg('indicators',[{code:'returning_upsell',kind:'customer',label:'Returning customer who bought additional work'},{code:'expensive_area',kind:'customer',label:'Expensive area'},{code:'hvac_interest',kind:'customer',label:'HVAC interest (no separate HVAC check)'},{code:'multi_service',kind:'customer',label:'Multiple service needs'},{code:'property_value_2m',kind:'property',label:'Property ≥ $2M'},{code:'property_3000sqft',kind:'property',label:'≥ 3,000 sq ft'},{code:'multi_story',kind:'property',label:'Multiple stories'},{code:'older_expensive',kind:'property',label:'Expensive older property'},{code:'commercial',kind:'property',label:'Commercial'}],'confirmed'),
      cfg('cost_categories',['materials','company_helper','travel','equipment','disposal','financing_processing','permits','other'],'proposed'),cfg('services',['installation','cleaning','hvac','removal','other'],'confirmed'),
      cfg('notify_enabled',false,'proposed'),cfg('coverage_denominator_agreed',false,'unresolved'),cfg('sagi_approved_for_estimates',true,'confirmed','set for the test')],
    bridge_comp_agreements:[{id:'agr-draft',name:'Combined technician — 50% after deductions (draft)',route:'combined',recipient:'combined technician',components:[{name:'technician_commission',rate_pct:50,base:'R-D'}],deduction_categories:null,status:'draft',created_at:'2026-09-18T00:00:00Z'}],
    bridge_opportunities:[],bridge_assignments:[],bridge_estimates:[],bridge_economics:[],bridge_requests:[],bridge_approvals:[],bridge_events:[],bridge_actuals:[],bridge_coverage_register:[]
  };
}
root.__makeBridgeDb=makeDb; if(typeof module!=='undefined'&&module.exports)module.exports={makeDb};
})(typeof globalThis!=='undefined'?globalThis:this);
