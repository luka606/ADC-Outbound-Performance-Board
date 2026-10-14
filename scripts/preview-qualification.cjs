// Local development preview: the real frontend + migration, fictional PostgreSQL data.
// It never loads production credentials or connects to Supabase/CRM.
const http=require('node:http'),fs=require('node:fs'),path=require('node:path');
const {createFixture}=require('../tests/qualification-transport.cjs');
(async()=>{
 const fixture=await createFixture();const mode={mode:'authenticated',member:'manager'};
 const linked=await fixture.transport({...mode,query:{rpc:'qual_link_assignment',args:{p_team:fixture.team,p_outcome:fixture.outcomes[0].id,p_service:'cleaning',p_territory:'LA'}}});if(linked.error)throw Error(linked.error.message);
 let link=linked.data;for(const [action,values] of [['estimate',{price_cents:75000,presented_at:'2026-10-12T20:00:00Z'}],['sale',{revenue_cents:64000,promised_date:'2026-10-20',decision_at:'2026-10-12T22:00:00Z'}],['costs',{costs:[{category:'labor',amount_cents:20000,status:'estimated'},{category:'materials',amount_cents:8000,status:'estimated'}]}]]){
  const r=await fixture.transport({...mode,query:{rpc:'qual_save_linked_job',args:{p_link:link.id,p_revision:link.revision,p_action:action,p_values:values}}});if(r.error)throw Error(r.error.message);link=r.data;
 }
 const pending=await fixture.transport({...mode,query:{rpc:'qual_link_assignment',args:{p_team:fixture.team,p_outcome:fixture.outcomes[2].id,p_service:'cleaning',p_territory:'LA'}}});if(pending.error)throw Error(pending.error.message);
 const pendingEstimate=await fixture.transport({...mode,query:{rpc:'qual_save_linked_job',args:{p_link:pending.data.id,p_revision:pending.data.revision,p_action:'estimate',p_values:{price_cents:1800000,presented_at:'2026-10-12T20:00:00Z'}}}});if(pendingEstimate.error)throw Error(pendingEstimate.error.message);
 const root=path.join(__dirname,'..');let html=fs.readFileSync(path.join(root,'qualification.html'),'utf8');
 const client=fs.readFileSync(path.join(root,'tests/qualification-test-client.js'),'utf8');
 const marker=/<script[^>]+src="https:[^"]*supabase[^"]*"[^>]*><\/script>/;if(!marker.test(html))throw Error('Supabase script marker missing');
 html=html.replace(marker,`<script src="/fixture-client.js"></script><script>localStorage.setItem('adc_supabase_cfg',JSON.stringify({url:'http://fixture.local',key:'fictional'}));window.supabase=makeQualificationTestClient(async body=>{const r=await fetch('/fixture-api',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});return r.json();},{user:{email:'manager@example.test',role:'manager'}});</script>`);
 html=html.replace('<header class="glass-edge">','<div style="padding:10px 24px;background:var(--accent);color:white;font-size:13px;font-weight:600">Preview · fictional jobs · changes stay in this local sample database</div><header class="glass-edge">');
 html=html.replace(/href="https:\/\/adc-outbound-performance-board[^\"]*"/g,'href="#" aria-disabled="true"');
 const server=http.createServer(async(req,res)=>{
  if(req.method==='GET'&&['/','/qualification.html'].includes(req.url)){res.writeHead(200,{'Content-Type':'text/html; charset=utf-8','Cache-Control':'no-store'});res.end(html);return;}
  if(req.method==='GET'&&req.url==='/fixture-client.js'){res.writeHead(200,{'Content-Type':'application/javascript'});res.end(client);return;}
  if(req.method==='POST'&&req.url==='/fixture-api'){
   if(req.headers.origin&&req.headers.origin!==`http://127.0.0.1:${server.address().port}`){res.writeHead(403);res.end();return;}
   let body='';for await(const chunk of req){body+=chunk;if(body.length>65536){res.writeHead(413);res.end();return;}}
   try{const result=await fixture.transport(JSON.parse(body));res.writeHead(200,{'Content-Type':'application/json'});res.end(JSON.stringify(result));}catch(e){res.writeHead(400);res.end(JSON.stringify({error:{message:e.message}}));}return;
  }
  res.writeHead(404);res.end();
 });server.listen(Number(process.env.PORT||8787),'127.0.0.1',()=>console.log(`Fictional qualification preview: http://127.0.0.1:${server.address().port}/qualification.html`));
 for(const signal of ['SIGINT','SIGTERM'])process.on(signal,()=>server.close(async()=>{await fixture.close();process.exit(0);}));
})().catch(e=>{console.error(e);process.exitCode=1;});
