const {createTestDb}=require('./qualification-postgres.cjs');
exports.createFixture=async function(options={}){
 const db=await createTestDb(options);await db.exec(`select set_config('test.member','manager',false);`);
 const team=(await db.query(`insert into qual_teams(name,leader_name,team_type,services,territories,entry_review_complete_at) values('Sample cleaning team','Fixture Tech','incumbent',array['cleaning'],array['LA'],'2026-10-01T20:00:00Z') returning id`)).rows[0];
 await db.exec(`insert into technicians(name) values('Fixture Tech');`);
 const assignment=(await db.query(`insert into job_assignments(date,technician,job_type,jobs) values('2026-10-12','Fixture Tech','ADC',4) returning id`)).rows[0];
 await db.query(`update job_assignment_outcomes set job_ref=case seq when 1 then '12345' when 2 then '12345' when 3 then '45678' else '78901' end,outcome=case when seq=1 then 'completed' else 'pending' end where assignment_id=$1`,[assignment.id]);
 const outcomes=(await db.query(`select id,seq from job_assignment_outcomes where assignment_id=$1 order by seq`,[assignment.id])).rows;
 await db.exec(`update qual_metric_versions set status='active',change_note='Fictional verification version',revenue=jsonb_set(revenue,'{baseline_cents}','{"value":100000,"status":"confirmed"}'::jsonb);`);
 const safeIdentifier=x=>{if(!/^[a-z_][a-z0-9_]*$/.test(x))throw Error('Invalid fixture identifier');return '"'+x+'"';};
 let queue=Promise.resolve();
 const transport=body=>{const run=queue.then(async()=>{const {query:r,mode,member}=body;await db.exec('begin;reset role;');try{
   await db.query(`select set_config('test.member',$1,true)`,[member||'outsider']);await db.exec(`set local role ${mode==='anon'?'anon':'authenticated'};`);
   let result;
   if(r.rpc){const defs={bridge_role:[],qual_sync_assignments:['p_start','p_end'],qual_set_assignment_reference:['p_outcome','p_reference'],qual_confirm_assignment_team:['p_outcome','p_team','p_reason'],qual_link_assignment:['p_team','p_outcome','p_existing_lead','p_job_ref','p_service','p_territory','p_mapping_note'],qual_save_linked_job:['p_link','p_revision','p_action','p_values']};const names=defs[r.rpc];if(!names)throw Error('Unknown fixture RPC');const params=names.map(n=>n==='p_values'?JSON.stringify(r.args[n]):r.args[n]??null);result=await db.query(`select * from public.${r.rpc}(${params.map((_,i)=>'$'+(i+1)).join(',')})`,params);}
   else {if(!r.table.startsWith('qual_')&&!['technicians','job_assignments','job_assignment_outcomes'].includes(r.table))throw Error('Unknown fixture table');if(r.op!=='select')throw Error('Preview uses the linked workflow for changes');const params=[],filters=r.filters.map(([k,op,v])=>{params.push(v);return safeIdentifier(k)+'='+('$'+params.length);});const order=r.orders.map(([k,d])=>safeIdentifier(k)+(d==='desc'?' desc':' asc')).join(',');
     result=await db.query(`select * from public.${safeIdentifier(r.table)}${filters.length?' where '+filters.join(' and '):''}${order?' order by '+order:''}${r.limit!=null?' limit '+Math.min(500,Math.max(0,Number(r.limit))):''}${r.offset?' offset '+Math.max(0,Number(r.offset)):''}`,params);}
   // Match PostgREST's date/timestamp JSON representation.
   result.rows.forEach(row=>result.fields.forEach(f=>{if(row[f.name] instanceof Date)row[f.name]=f.dataTypeID===1082?row[f.name].toISOString().slice(0,10):row[f.name].toISOString();}));
   await db.exec('commit');return {data:['bridge_role','qual_sync_assignments','qual_set_assignment_reference','qual_confirm_assignment_team'].includes(r.rpc)?result.rows[0]?.[r.rpc]:r.rpc||r.single?result.rows[0]||null:result.rows,error:null};
  }catch(e){await db.exec('rollback');return {data:null,error:{message:e.message}};}});queue=run.catch(()=>{});return run;};
 return {db,team:team.id,outcomes,transport,close:async()=>{await queue;await db.close();}};
};
