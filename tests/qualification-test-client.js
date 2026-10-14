/* Test/preview adapter only. Transport executes the real migration on a fictional PostgreSQL DB. */
(function(root){
function makeClient(transport,initialSession){let session=initialSession,listeners=[];
 const request=async(mode,query)=>{try{return await transport({mode,member:session?.user?.role||'outsider',query});}catch(e){return {data:null,error:{message:e.message}};}};
 class Builder{constructor(mode,table){this.mode=mode;this.query={table,op:'select',filters:[],orders:[]};}select(){return this;}eq(k,v){this.query.filters.push([k,'=',v]);return this;}order(k,o){this.query.orders.push([k,o?.ascending===false?'desc':'asc']);return this;}range(a,b){this.query.offset=a;this.query.limit=b-a+1;return this;}limit(n){this.query.limit=n;return this;}insert(payload){this.query.op='insert';this.query.payload=payload;return this;}update(payload){this.query.op='update';this.query.payload=payload;return this;}single(){this.query.single=true;return this;}maybeSingle(){this.query.single=true;return this;}then(a,b){return request(this.mode,this.query).then(a,b);}}
 const auth={getSession:async()=>({data:{session},error:null}),onAuthStateChange(cb){listeners.push(cb);return {data:{subscription:{unsubscribe(){listeners=listeners.filter(x=>x!==cb);}}}};},signInWithOtp:async()=>({error:{message:'This preview uses fictional data only.'}}),signOut:async()=>{session=null;listeners.forEach(f=>f('SIGNED_OUT',null));return {error:null};},__set(s){session=s;listeners.forEach(f=>f('SIGNED_IN',s));}};
 return {createClient(url,key,options){const mode=options?.auth?.persistSession===false?'anon':'authenticated';return {from:t=>new Builder(mode,t),auth,rpc:(rpc,args={})=>request(mode,{rpc,args})};},auth};
}
root.makeQualificationTestClient=makeClient;if(typeof module!=='undefined')module.exports={makeClient};
})(typeof globalThis!=='undefined'?globalThis:this);
