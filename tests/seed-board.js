/* Seed for the board tests: every table index.html reads at connect/boot, technicians with the approved flag,
   and one day of job_assignments — three approved technicians with rows, one unapproved with rows, one approved without. */
(function(root){
function makeDb(todayPT){
  const d=todayPT;
  const techs=[['3 LA Donat',true],['3 LA Jordan',true],['3 OC Jimmy',true],['3 LA Miguel',true],['1 Shams',false]];
  return {
    agents:[{id:'ag1',name:'Reagan',sort_order:1,target_bookings:10,target_crossbookings:2,active:true}],
    daily_reports:[],bookings:[],sales:[],sales_metrics:[],salespersons:[{id:'sp1',name:'Tom',pin:'1234',active:true}],
    app_settings:[{key:'job_overload_threshold',value:'4'}],
    technicians:techs.map(([name,approved],i)=>({id:'t'+i,name,active:true,approved,areas:(name.match(/^\d+\s+(LA|OC)\s/)||[])[1]||null,job_types:'both',default_type:null})),
    job_assignments:[
      {id:'j1',date:d,technician:'3 LA Donat',job_type:'ADC',jobs:3,justified:null},
      {id:'j2',date:d,technician:'3 LA Donat',job_type:'DVC',jobs:1,justified:null},
      {id:'j3',date:d,technician:'3 LA Jordan',job_type:'ADC',jobs:2,justified:null},
      {id:'j4',date:d,technician:'3 OC Jimmy',job_type:'DVC',jobs:2,justified:null},
      {id:'j5',date:d,technician:'1 Shams',job_type:'ADC',jobs:1,justified:null}],
    coverage_log:[],coverage_days:[],adc_database:[],weekly_history:[]
  };
}
root.__makeBoardDb=makeDb; if(typeof module!=='undefined'&&module.exports)module.exports={makeDb};
})(typeof globalThis!=='undefined'?globalThis:this);
