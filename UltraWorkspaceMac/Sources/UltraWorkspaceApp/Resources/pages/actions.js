const POLL=15000;
// GitHub Actions: on the left how many workflows pass, fail or run (each workflow's newest run) and a dot per
// repository; on the right the newest runs, four at a time. Tap the left part to show only failing runs, the arrow chip
// for older runs, a run for its details (tap again, or wait a minute, to go back).
let failOnly=false, page=0, detail=null, detailUntil=0, rows=[], chip=null, lastDraw=0;
const GREEN='#4ade80', RED='#f87171', AMBER='#fbbf24', GREY='#8b94a6', DIM='#5b6475';
const COL={passing:GREEN,failing:RED,running:AMBER,cancelled:GREY,skipped:DIM};
const L=380, W=1024;                                    // the runs panel

function font(size,weight){ g.font=(weight||'400')+' '+size+'px -apple-system,Roboto,Helvetica,Arial,sans-serif'; }
// The text cut with an ellipsis so it fits in w pixels at this size and weight.
function fit(s,w,size,weight){ font(size,weight); s=s||''; if(g.measureText(s).width<=w) return s;
  let lo=0, hi=s.length; while(lo<hi){ const m=(lo+hi+1)>>1; if(g.measureText(s.slice(0,m)+'…').width<=w) lo=m; else hi=m-1; } return s.slice(0,lo).trimEnd()+'…'; }
function width(s,size,weight){ font(size,weight); return g.measureText(s).width; }
function dur(s){ s=Math.max(0,Math.round(s)); if(s<60) return s+' s'; const m=Math.floor(s/60), h=Math.floor(m/60);
  return h? h+' h '+(m%60)+' min' : m+' min'+(s%60?' '+(s%60)+' s':''); }
function clock(s){ s=Math.max(0,Math.floor(s)); const h=Math.floor(s/3600), m=Math.floor(s/60)%60, x=s%60; return (h?h+':'+String(m).padStart(2,'0'):m)+':'+String(x).padStart(2,'0'); }
function event(e){ return ({push:'push',pull_request:'pull request',pull_request_target:'pull request',workflow_dispatch:'manual',schedule:'scheduled',release:'release',merge_group:'merge queue',workflow_run:'after a workflow',dynamic:'GitHub'})[e]||(e||'').replace(/_/g,' '); }
function since(s){ s=Math.max(0,Math.round(s)); return (s<172800? ago(s) : Math.round(s/86400)+' days')+' ago'; }
function hhmm(t){ const d=new Date(t*1000); return String(d.getHours()).padStart(2,'0')+':'+String(d.getMinutes()).padStart(2,'0'); }
function nowS(){ return Date.now()/1000; }

// The state as a small drawn icon: a check, a cross, a turning arc, a slash or a dash.
function icon(x,y,r,state){
  const col=COL[state]||GREY; g.lineCap='round'; g.lineJoin='round';
  if(state==='running'){ const a=(Date.now()/1000*2*Math.PI*0.75)%(2*Math.PI);
    g.strokeStyle='rgba(251,191,36,.25)'; g.lineWidth=r*0.3; g.beginPath(); g.arc(x,y,r*0.8,0,7); g.stroke();
    g.strokeStyle=col; g.beginPath(); g.arc(x,y,r*0.8,a,a+Math.PI*1.2); g.stroke(); return; }
  g.fillStyle=col; g.beginPath(); g.arc(x,y,r,0,7); g.fill();
  g.strokeStyle='#1c2029'; g.lineWidth=r*0.24; g.beginPath();
  if(state==='passing'){ g.moveTo(x-r*.45,y+r*.02); g.lineTo(x-r*.12,y+r*.36); g.lineTo(x+r*.48,y-r*.34); }
  else if(state==='failing'){ g.moveTo(x-r*.36,y-r*.36); g.lineTo(x+r*.36,y+r*.36); g.moveTo(x+r*.36,y-r*.36); g.lineTo(x-r*.36,y+r*.36); }
  else if(state==='cancelled'){ g.moveTo(x-r*.4,y+r*.4); g.lineTo(x+r*.4,y-r*.4); }
  else { g.moveTo(x-r*.42,y); g.lineTo(x+r*.42,y); }
  g.stroke();
}

function render(d){
  rows=[]; chip=null;
  if(!d.hasToken){ txt('Add a GitHub token under Apps → GitHub Actions in Deckhand.',712,150,22,GREY,'center'); return; }
  if(!d.counts){ txt(d.error||'Reading your workflow runs…',712,150,20,GREY,'center'); return; }
  const c=d.counts, days=d.days||7;
  // --- left: the counts, the repositories
  txt(failOnly?'ACTIONS · FAILING ONLY':'ACTIONS · '+(days===1?'LAST DAY':'LAST '+days+' DAYS'),20,32,14,failOnly?RED:GREY,'left','600');
  const lines=[['failing',c.failing||0,'failing'],['running',c.running||0,'running'],['passing',c.passing||0,'passing']];
  const big=(lines.find(l=>l[1]>0)||lines[2])[0];
  lines.forEach((l,i)=>{ const y=[80,130,180][i], on=l[0]===big, size=on?34:22;
    icon(34,y-size*0.36,on?15:11,l[1]>0?l[0]:'skipped');
    txt(l[1]+' '+l[2],58,y,size,l[1]>0?(on?'#fff':'#d4d8e0'):DIM,'left',on?'700':'500'); });
  const repos=d.repos||[];
  repos.slice(0,12).forEach((r,i)=>{ g.fillStyle=COL[r.state]||GREY; g.beginPath(); g.arc(27+i*20,236,7,0,7); g.fill(); });
  const n=Math.min(12,repos.length); if(repos.length>12) txt('+'+(repos.length-12),27+12*20-4,241,13,GREY);
  else if(repos.length&&n<=8) txt(repos.length+(repos.length===1?' repo':' repos'),27+n*20-2,241,13,GREY);
  if(d.error) txt(fit(d.error,330,13),20,268,13,'#f59e0b');

  const all=d.runs||[], list=failOnly?all.filter(r=>r.state==='failing'):all;
  const pages=Math.max(1,Math.ceil(list.length/4)); if(page>=pages) page=0;
  if(pages>1){ const label=(page+1)+'/'+pages+'  ›'; const w=width(label,15,'700')+22, x=360-w;
    rr(x,220,w,32,16,'rgba(255,255,255,.12)'); txt(label,x+w/2,241,15,'#fff','center','700'); chip={x,w}; }

  const shown=detail&&Date.now()<detailUntil? all.find(r=>r.full+r.started+r.workflow===detail) : null;
  rr(L,14,W,252,16,'rgba(255,255,255,.06)');
  if(shown){ renderDetail(shown); return; }
  detail=null;
  if(!list.length){ txt(failOnly?'Nothing is failing.':'No workflow runs in the last '+(days===1?'day':days+' days')+'.',L+W/2,148,20,GREY,'center'); return; }
  list.slice(page*4,page*4+4).forEach((r,i)=>{ const y=18+i*62; rows.push({y,key:r.full+r.started+r.workflow});
    if(i){ g.fillStyle='rgba(255,255,255,.08)'; g.fillRect(L+16,y,W-32,1); }
    icon(L+30,y+31,13,r.state);
    const X=L+58, right=L+W-20;
    const wf=fit(r.workflow,360,20,'700'); txt(wf,X,y+28,20,'#fff','left','700');
    const x2=X+width(wf,20,'700'); if(r.title&&r.title!==r.workflow) txt(' · ',x2,y+28,17,GREY);
    const x3=x2+width(' · ',17); if(r.title&&r.title!==r.workflow) txt(fit(clip(r.title,60),right-x3,17),x3,y+28,17,'#e5e7eb');
    const run=r.state==='running';
    const when=run? (r.status==='queued'||r.status==='waiting'||r.status==='pending'||r.status==='requested'? r.status+' '+clock(nowS()-r.started) : 'running '+clock(nowS()-r.started)) : since(nowS()-r.started);
    const ww=width(when,15,run?'600':'400'); txt(when,right,y+51,15,run?AMBER:GREY,'right',run?'600':'400');
    const meta=[r.repo,r.branch,event(r.event)].filter(Boolean).join(' · ')+(r.duration!=null?' · '+dur(r.duration):'')+(r.attempt>1?' · attempt '+r.attempt:'');
    txt(fit(meta,right-X-ww-24,15),X,y+51,15,GREY);
  });
}

function renderDetail(r){
  const X=L+28, right=L+W-28, run=r.state==='running';
  icon(X+18,58,20,r.state);
  const head=fit(r.repo+' · '+r.workflow,right-X-56,26,'700'); txt(head,X+52,52,26,'#fff','left','700');
  txt(fit(r.title,right-X-56,19),X+52,82,19,'#e5e7eb');
  const res=run? (r.status==='in_progress'?'Running':r.status.charAt(0).toUpperCase()+r.status.slice(1)) : (r.conclusion||'done').replace(/_/g,' ');
  const stats=[['Result',res.charAt(0).toUpperCase()+res.slice(1)],['Attempt','#'+(r.attempt||1)],['Trigger',event(r.event)||'—'],['Branch',r.branch||'—'],
    ['Started',hhmm(r.started)],[run?'Running for':'Took',run?clock(nowS()-r.started):(r.duration!=null?dur(r.duration):'—')]];
  const cw=(right-X)/6;
  stats.forEach((s,i)=>{ const x=X+i*cw; txt(s[0],x,140,13,GREY,'left','600'); txt(fit(s[1],cw-14,19,'600'),x,166,19,i===0?(COL[r.state]||'#fff'):'#fff','left','600'); });
  if(r.url){ txt('Open on the Mac:',X,222,15,GREY,'left','600'); const w=width('Open on the Mac: ',15,'600'); txt(fit(r.url,right-X-w,15),X+w,222,15,'#93c5fd'); }
  txt('Tap again to go back',right,252,13,DIM,'right');
}

// Redrawn when new data or a tap comes in, four times a second while a run's arc turns and its clock counts, every
// 5 s otherwise (the "ago" texts), every 30 s with nothing to show. The shell's frame() would redraw 60 times a second.
let lastD=null;
function frame(){ const t=Date.now(), step=!D||!D.counts?30000:(D.runs||[]).some(r=>r.state==='running')?250:5000;
  if(D&&(D!==lastD||t-lastDraw>=step-20)){ lastD=D; lastDraw=t; bg(); render(D); } setTimeout(frame,250); }

c.addEventListener('click',ev=>{
  const r=c.getBoundingClientRect(), x=(ev.clientX-r.left)*1424/r.width, y=(ev.clientY-r.top)*280/r.height;
  if(chip&&x>=chip.x-8&&x<=chip.x+chip.w+8&&y>=210&&y<=262){ page++; detail=null; }
  else if(x<L){ failOnly=!failOnly; page=0; detail=null; }
  else if(detail){ detail=null; }
  else { const row=rows.find(o=>y>=o.y&&y<o.y+62); if(row){ detail=row.key; detailUntil=Date.now()+60000; } }
  lastDraw=0; if(D){ lastD=D; lastDraw=Date.now(); bg(); render(D); }
});
