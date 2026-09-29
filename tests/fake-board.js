/* In-memory stand-in for supabase-js v2 for the board (index.html): plain tables, no auth, the job_assignments
   review stamp trigger emulated. Same builder shape as fake-bridge.js. */
(function(root){
function makeFake(db){
  const uid=()=>'id-'+Math.random().toString(36).slice(2,10); const now=()=>new Date().toISOString();
  const ERR=m=>({data:null,error:{message:m}});
  function before(t,op,row,old){
    if(t==='job_assignments'&&op==='update'){
      if(row.justified!==old.justified){row.justified_at=row.justified==null?null:now();if(row.justified==null)row.justified_by=null;}
      else{row.justified_by=old.justified_by;row.justified_at=old.justified_at;}
      if(row.justified!=null&&!['Yes','No'].includes(row.justified))return 'new row for relation "job_assignments" violates check constraint "job_assignments_justified_ck"';
    }
    if(t==='job_assignments'&&op==='insert'){row.justified=row.justified??null;row.justified_by=row.justified_by??null;row.justified_at=row.justified_at??null;}
    return null;
  }
  class Qb{
    constructor(t){this.t=t;this.op='select';this.f=[];this.one=false;this.payload=null;this.conflict=[];this.lim=null;this.sorts=[];this.cols=null;}
    select(c){if(this.op==='select')this.cols=c;return this;} insert(p){this.op='insert';this.payload=p;return this;} update(p){this.op='update';this.payload=p;return this;} delete(){this.op='delete';return this;}
    upsert(p,o){this.op='upsert';this.payload=p;this.conflict=String((o&&o.onConflict)||'').split(',').map(x=>x.trim()).filter(Boolean);return this;}
    eq(k,v){this.f.push(r=>String(r[k])===String(v));return this;} neq(k,v){this.f.push(r=>String(r[k])!==String(v));return this;} in(k,vs){this.f.push(r=>vs.map(String).includes(String(r[k])));return this;} is(k,v){this.f.push(r=>v===null?r[k]==null:r[k]===v);return this;}
    gte(k,v){this.f.push(r=>r[k]>=v);return this;} lte(k,v){this.f.push(r=>r[k]<=v);return this;} lt(k,v){this.f.push(r=>r[k]<v);return this;} gt(k,v){this.f.push(r=>r[k]>v);return this;} ilike(k,v){const re=new RegExp('^'+String(v).replace(/%/g,'.*')+'$','i');this.f.push(r=>re.test(String(r[k]??'')));return this;}
    order(k,o){this.sorts.push([k,!(o&&o.ascending===false)]);return this;} limit(n){this.lim=n;return this;} range(a,b){this.lim=b+1;return this;} single(){this.one=true;return this;} maybeSingle(){this.one=true;return this;}
    _rows(){return (db[this.t]||[]).filter(r=>this.f.every(fn=>fn(r)));}
    _run(){
      if(!(this.t in db))return ERR(`Could not find the table 'public.${this.t}' in the schema cache`);
      let data=null;
      if(this.op==='select'){data=this._rows().slice();for(const [k,asc] of this.sorts.slice().reverse())data.sort((a,b)=>{const x=a[k]??'',y=b[k]??'';return (x<y?-1:x>y?1:0)*(asc?1:-1);});if(this.lim!=null)data=data.slice(0,this.lim);if(this.one)data=data[0]||null;return {data,error:null,count:data?data.length:0};}
      if(this.op==='insert'){const arr=Array.isArray(this.payload)?this.payload:[this.payload];const out=[];for(const p of arr){const r={id:uid(),created_at:now(),...p};const err=before(this.t,'insert',r,null);if(err)return ERR(err);db[this.t].push(r);out.push(r);}data=this.one?out[0]:out;}
      else if(this.op==='update'){const rows=this._rows();const staged=[];for(const r of rows){const nr={...r,...this.payload};const err=before(this.t,'update',nr,r);if(err)return ERR(err);staged.push([r,nr]);}staged.forEach(([r,nr])=>Object.assign(r,nr));data=this.one?rows[0]||null:rows;}
      else if(this.op==='upsert'){const arr=Array.isArray(this.payload)?this.payload:[this.payload];const out=[];for(const p of arr){const hit=(db[this.t]||[]).find(r=>this.conflict.length&&this.conflict.every(k=>String(r[k])===String(p[k])));if(hit){const nr={...hit,...p};const err=before(this.t,'update',nr,hit);if(err)return ERR(err);Object.assign(hit,nr);out.push(hit);}else{const r={id:uid(),created_at:now(),...p};const err=before(this.t,'insert',r,null);if(err)return ERR(err);db[this.t].push(r);out.push(r);}}data=out;}
      else if(this.op==='delete'){const rows=this._rows();db[this.t]=db[this.t].filter(r=>!rows.includes(r));data=rows;}
      return {data,error:null};
    }
    then(res,rej){return Promise.resolve().then(()=>this._run()).then(res,rej);}
  }
  const chan={on(){return chan;},subscribe(){return chan;},unsubscribe(){}};
  return {from:t=>new Qb(t),channel:()=>chan,removeChannel(){},auth:{getSession:async()=>({data:{session:null}}),onAuthStateChange(){return {data:{subscription:{unsubscribe(){}}}};}},__db:db};
}
root.__makeFakeBoard=makeFake;
if(typeof module!=='undefined'&&module.exports)module.exports={makeFake};
})(typeof globalThis!=='undefined'?globalThis:this);
