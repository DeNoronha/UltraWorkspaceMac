const POLL=30000;
// Tap an issue to get a Done button; tap Done to close it in Linear (Deckhand does the call).
let hit=[], sel=null, selAt=0, pending={};
// The Done button lies inside its issue's row, so buttons are tested before rows (the first hit wins).
c.addEventListener('click',e=>{ const x=e.offsetX, y=e.offsetY, inside=h=> x>=h.x&&x<=h.x+h.w&&y>=h.y&&y<=h.y+h.h;
  for(const h of hit){ if(h.btn&&inside(h)){ pending[h.uid]=Date.now(); sel=null; act('/tasks/done/'+h.uid).then(()=>setTimeout(poll,1500)); return; } }
  for(const h of hit){ if(!h.btn&&inside(h)){ sel= sel===h.uid? null : h.uid; selAt=Date.now(); return; } }
  sel=null; });
function bars(x,y,p,col){ for(let i=0;i<4;i++){ g.fillStyle= (p&&i<5-p)?col:'rgba(255,255,255,.14)'; g.fillRect(x+i*6,y+12-(i+1)*3,4,(i+1)*3); } }
// Local calendar date as YYYY-MM-DD (toISOString would give the UTC date, a day off in the evening east of Greenwich).
function ymd(d){ return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0'); }
function render(d){
  hit=[]; if(sel&&Date.now()-selAt>8000) sel=null;
  if(!d.hasKey){ txt('Add your Linear API key in Deckhand',40,130,32,'#9aa3b2','left','700'); txt('Apps → Tasks. The key stays on the Mac.',40,172,19,'#6b7280'); return; }
  const items=(d.issues||[]).filter(i=>!(pending[i.uid]&&Date.now()-pending[i.uid]<20000)); if(d.error&&!items.length){ txt(d.error,40,150,22,'#f87171'); return; }
  const today=ymd(new Date()), week=ymd(new Date(Date.now()+7*86400000));
  const due=items.filter(i=>i.due&&i.due<=week).length, over=items.filter(i=>i.due&&i.due<today).length;
  txt((d.me?d.me+' · ':'')+items.length+' open',40,34,15,'#8b94a6','left','600');
  txt((over? over+' overdue':'')+(over&&due?' · ':'')+(due? due+' due this week':''),1340,34,15,over?'#f87171':'#8b94a6','right','600');
  if(d.error) txt(clip(d.error,80),712,34,13,'#f87171','center');
  if(!items.length){ txt('Nothing assigned to you. Enjoy it.',40,150,30,'#9aa3b2','left','700'); return; }
  const pc={1:'#f87171',2:'#fbbf24',3:'#60a5fa',4:'#8b94a6'};
  items.slice(0,6).forEach((it,i)=>{ const col=i%2, row=Math.floor(i/2); const x=40+col*700, y=60+row*70, W=660, H=60, isSel=sel===it.uid;
    rr(x,y,W,H,10, isSel?'rgba(74,222,128,.14)':it.stateType==='started'?'rgba(96,165,250,.12)':'rgba(255,255,255,.06)');
    hit.push({x,y,w:W,h:H,uid:it.uid});
    bars(x+16,y+22,it.priority,pc[it.priority]||'#8b94a6'); txt(it.id,x+50,y+26,14,'#8b94a6','left','600');
    txt(clip(it.title,isSel?34:46),x+50,y+48,19,'#fff','left','600');
    if(isSel){ rr(x+W-150,y+10,138,40,20,'#4ade80'); txt('✓  Done',x+W-81,y+37,18,'#0b2e17','center','700'); hit.push({x:x+W-150,y:y+10,w:138,h:40,uid:it.uid,btn:true}); }
    else { rr(x+520,y+14,120,22,11,it.color||'#4b5363'); txt(clip(it.state,14),x+580,y+30,12,'#fff','center','700');
      if(it.due){ const late=it.due<today; txt((late?'overdue ':'due ')+it.due.slice(5),x+640,y+52,13,late?'#f87171':'#8b94a6','right'); } } });
  if(items.length>6) txt('+'+(items.length-6)+' more',712,272,12,'#4b5363','center');
  if(!sel) txt('tap an issue to mark it done',40,272,12,'#4b5363','left');
}
