/* Seed for the board tests: every table index.html reads at connect/boot, technicians with the approved flag,
   today's job_assignments — three approved technicians with rows, one unapproved with rows, one approved without —
   plus yesterday's rows with their outcome lines (job_assignment_outcomes). makeDb(todayPT) also exposes .yesterday. */
(function(root){
function makeDb(todayPT){
  const d=todayPT; const yd=new Date(d+'T12:00:00Z'); yd.setUTCDate(yd.getUTCDate()-1); const y=yd.toISOString().slice(0,10); const ts=y+'T18:30:00.000Z';
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
      {id:'j5',date:d,technician:'1 Shams',job_type:'ADC',jobs:1,justified:null},
      // yesterday: Miguel expected 1 ADC job, no outcome yet; Donat expected 3 ADC — 2 completed, 1 cancelled with a comment
      {id:'y1',date:y,technician:'3 LA Miguel',job_type:'ADC',jobs:1,justified:null},
      {id:'y2',date:y,technician:'3 LA Donat',job_type:'ADC',jobs:3,justified:null}],
    job_assignment_outcomes:[
      ...['j1','j1','j1','j2','j3','j3','j4','j4','j5'].map((a,i,arr)=>({id:'o'+i,assignment_id:a,seq:arr.slice(0,i).filter(x=>x===a).length+1,outcome:'pending',comment:null,job_ref:null,updated_by:null,updated_at:ts,created_at:ts})),
      {id:'oy1',assignment_id:'y1',seq:1,outcome:'pending',comment:null,job_ref:null,updated_by:null,updated_at:ts,created_at:ts},
      {id:'oy2',assignment_id:'y2',seq:1,outcome:'completed',comment:null,job_ref:null,updated_by:'Tom-laptop',updated_at:ts,created_at:ts},
      {id:'oy3',assignment_id:'y2',seq:2,outcome:'completed',comment:null,job_ref:'LD-4471',updated_by:'Tom-laptop',updated_at:ts,created_at:ts},
      {id:'oy4',assignment_id:'y2',seq:3,outcome:'cancelled',comment:'customer cancelled at the door',job_ref:null,updated_by:'Tom-laptop',updated_at:ts,created_at:ts}],
    coverage_log:[],coverage_days:[],adc_database:[],weekly_history:[],
    yesterday:y
  };
}
root.__makeBoardDb=makeDb; if(typeof module!=='undefined'&&module.exports)module.exports={makeDb};
})(typeof globalThis!=='undefined'?globalThis:this);
