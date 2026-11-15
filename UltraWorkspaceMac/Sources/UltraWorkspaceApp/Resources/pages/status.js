const POLL=60000;
// Cloud Status: the summary on the left, a tile per service on the right (issues first). Tap a tile for what is going
// on; tap again, or wait a minute, to go back. The bar fetches the status pages itself (StatusFeed.kt).
const GX=400, GW=1004, GY=8, GH=264, GAP=12;
const COL={ok:'#4ade80',minor:'#f59e0b',major:'#f87171',maintenance:'#60a5fa',unknown:'#8b94a6'};
const TINT={minor:'rgba(245,158,11,.16)',major:'rgba(248,113,113,.2)',maintenance:'rgba(96,165,250,.12)'};
let detail=null, detailUntil=0, tiles=[], pulse=false;
const FONT='-apple-system,Roboto,Helvetica,Arial,sans-serif';

function issue(s){ return s.state==='minor'||s.state==='major'; }
function stateText(s){
  const part=s.part?' · '+s.part:'';
  return s.state==='ok'?'Operational' : s.state==='minor'?'Degraded'+part : s.state==='major'?'Major outage'+part
    : s.state==='maintenance'?'Maintenance'+part : 'No answer';
}
/** The longest start of `s` that fits in `w` px at the current font, with an ellipsis when cut. */
function fit(s,w){ if(g.measureText(s).width<=w) return s; let lo=0, hi=s.length; while(lo<hi){ const m=(lo+hi+1)>>1; if(g.measureText(s.slice(0,m)+'…').width<=w) lo=m; else hi=m-1; } return s.slice(0,lo).trimEnd()+'…'; }
function fitTxt(s,x,y,w,size,col,weight){ g.font=(weight||'400')+' '+size+'px '+FONT; txt(fit(s,w),x,y,size,col,'left',weight); }
/** Words wrapped into at most `max` lines of `w` px; the last one gets an ellipsis when text is left over. */
function wrap(s,w,size,weight,max){
  g.font=(weight||'400')+' '+size+'px '+FONT; const words=(s||'').split(/\s+/).filter(Boolean), lines=[]; let cur='';
  for(let i=0;i<words.length;i++){ const t=cur?cur+' '+words[i]:words[i];
    if(g.measureText(t).width<=w){ cur=t; continue; }
    if(lines.length===max-1){ lines.push(fit([cur].concat(words.slice(i)).filter(Boolean).join(' '),w)); return lines; }
    if(cur) lines.push(cur); cur=g.measureText(words[i]).width>w? fit(words[i],w):words[i]; }
  if(cur) lines.push(cur); return lines.slice(0,max);
}
function hm(t,h24){ const d=new Date(t*1000); let h=d.getHours(); const m=String(d.getMinutes()).padStart(2,'0');
  if(h24===false){ const ap=h<12?'am':'pm'; h=h%12||12; return h+':'+m+' '+ap; } return String(h).padStart(2,'0')+':'+m; }
function when(t,h24){ const now=Date.now()/1000; if(now-t<20*3600) return hm(t,h24);
  const d=new Date(t*1000); return d.getDate()+' '+['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'][d.getMonth()]+' '+hm(t,h24); }
function dot(x,y,s,r){ g.fillStyle=COL[s.state]||COL.unknown; g.beginPath(); g.arc(x,y,r,0,7); g.fill();
  if(issue(s)&&pulse){ g.strokeStyle=COL[s.state]; g.globalAlpha=.45; g.lineWidth=2; g.beginPath(); g.arc(x,y,r+4,0,7); g.stroke(); g.globalAlpha=1; } }

function sorted(d){
  const rank=s=>s.state==='major'?0:s.state==='minor'?1:2;
  return (d.services||[]).map((s,i)=>({s,i})).sort((a,b)=>rank(a.s)-rank(b.s)||a.i-b.i).map(o=>o.s);
}

function render(d){
  const list=sorted(d), bad=list.filter(issue), now=Date.now()/1000;
  pulse=!pulse;
  // --- left: the summary
  txt('CLOUD STATUS',20,32,14,'#8b94a6','left','600');
  const known=list.filter(s=>s.state!=='unknown');
  let head, col;
  if(!known.length){ head=list.some(s=>s.checked)?'No answer':'Checking…'; col='#8b94a6'; }
  else if(!bad.length){ head='All systems normal'; col=COL.ok; }
  else { head=bad.length===1? bad[0].name+' has an issue' : bad.length+' services with issues'; col=bad.some(s=>s.state==='major')?COL.major:COL.minor; }
  let size=34; g.font='700 '+size+'px '+FONT; while(size>24&&g.measureText(head).width>360){ size-=2; g.font='700 '+size+'px '+FONT; }
  const hl=wrap(head,360,size,'700',2); hl.forEach((l,i)=>txt(l,20,hl.length>1?78+i*(size+4):100,size,col,'left','700'));
  let y=hl.length>1?78+(hl.length-1)*(size+4)+30:130;
  const checked=Math.max(0,...list.map(s=>s.checked||0));
  txt(checked?'Checked '+(now-checked<45?'just now':ago(Math.round(now-checked))+' ago'):'Not checked yet',20,y,15,'#8b94a6');
  y+=36;
  if(bad.length){ const rows=bad.slice(0,hl.length>1?2:3);
    rows.forEach((s,i)=>{ dot(28,y+i*28-6,s,5); fitTxt(s.name+(s.part?' · '+s.part:''),42,y+i*28,338,17,'#e5e7eb'); });
    if(bad.length>rows.length) txt('and '+(bad.length-rows.length)+' more',42,y+rows.length*28,15,'#8b94a6'); }
  else { const mt=list.filter(s=>s.state==='maintenance'), un=list.filter(s=>s.state==='unknown');
    if(mt.length) fitTxt('Maintenance: '+mt.map(s=>s.name).join(', '),20,y,360,17,COL.maintenance);
    else if(un.length&&known.length) fitTxt('No answer from '+un.map(s=>s.name).join(', '),20,y,360,17,'#8b94a6');
    else if(known.length) txt(list.length+' services, from their official status pages',20,y,15,'#8b94a6'); }

  // --- right: a tap's detail, or the tiles
  const sel=detail&&Date.now()<detailUntil&&list.find(s=>s.id===detail);
  if(sel){ renderDetail(sel,d); return; }
  detail=null;
  const n=list.length, cols=n<=6?3:n<=9?3:4, rows=n<=3?1:n<=6?2:3;
  const w=(GW-(cols-1)*GAP)/cols, h=(GH-(rows-1)*GAP)/rows, big=h>100;
  tiles=[];
  list.slice(0,cols*rows).forEach((s,i)=>{
    const x=GX+(i%cols)*(w+GAP), ty=GY+Math.floor(i/cols)*(h+GAP); tiles.push({x,y:ty,w,h,id:s.id});
    rr(x,ty,w,h,14,TINT[s.state]||'rgba(255,255,255,.06)');
    const cy=ty+h/2, ns=big?24:19, ss=big?16:14;
    dot(x+22,cy-(big?10:8),s,big?6:5);
    fitTxt(s.name,x+38,cy-(big?2:1),w-52,ns,'#fff','700');
    fitTxt(stateText(s),x+38,cy+(big?24:20),w-52,ss,issue(s)||s.state==='maintenance'?COL[s.state]:'#8b94a6');
  });
}

function renderDetail(s,d){
  rr(GX,GY,GW,GH,16,TINT[s.state]||'rgba(255,255,255,.06)');
  const x=GX+28, w=GW-56;
  dot(x+8,44,s,8);
  g.font='700 24px '+FONT; const nw=g.measureText(s.name).width;
  txt(s.name,x+26,52,24,'#fff','left','700');
  fitTxt(stateText(s),x+40+nw,52,w-60-nw,17,COL[s.state]||COL.unknown,'600');
  let y=90;
  if(s.title){ const tl=wrap(s.title,w,20,'600',2); tl.forEach((l,i)=>txt(l,x,y+i*26,20,'#fff','left','600')); y+=tl.length*26+6; }
  else if(s.state==='ok'){ txt('No incidents on its status page.',x,y,20,'#e5e7eb'); y+=32; }
  else if(s.state==='unknown'){ txt('Its status page did not answer.',x,y,20,'#e5e7eb'); y+=32; }
  if(s.detail){ const dl=wrap(s.detail,w,16,'400',Math.max(1,Math.min(4,Math.floor((236-y)/22)))); dl.forEach((l,i)=>txt(l,x,y+i*22,16,'#cbd5e1')); }
  const bits=[]; if(s.since){ bits.push('Since '+when(s.since,d.clock24h)+' · '+ago(Math.max(0,Math.round(Date.now()/1000-s.since)))); }
  if(s.checked) bits.push('checked '+hm(s.checked,d.clock24h));
  txt(bits.join(' · ').replace(/^checked/,'Checked'),x,258,14,'#8b94a6');
  txt('Tap to go back',GX+GW-28,258,14,'#8b94a6','right');
}

// The page changes once a second at most (the "ago" text), twice while an issue's dot pulses; the shell's frame()
// redraws at 60 Hz, which keeps the bar's processor busy. This declaration replaces it (the later one wins).
let lastDraw=0;
function frame(){ const t=Date.now(), step=D&&(D.services||[]).some(issue)?500:1000;
  if(D&&t-lastDraw>=step-20){ lastDraw=t; bg(); render(D); } setTimeout(frame,step); }
c.addEventListener('click',ev=>{
  const r=c.getBoundingClientRect(), x=(ev.clientX-r.left)*1424/r.width, y=(ev.clientY-r.top)*280/r.height;
  if(detail&&Date.now()<detailUntil){ if(x>=GX){ detail=null; lastDraw=0; } return; }
  const t=tiles.find(o=>x>=o.x&&x<o.x+o.w&&y>=o.y&&y<o.y+o.h); if(t){ detail=t.id; detailUntil=Date.now()+60000; lastDraw=0; }
});
