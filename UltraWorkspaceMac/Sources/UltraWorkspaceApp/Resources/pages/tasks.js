const POLL=30000;
// Tap an issue to get a Done button; tap Done to close it in Linear (Deckhand does the call).
let hit=[], sel=null, selAt=0, pending={};
// One full-width column, three rows in view; swipe up and down (or use a mouse wheel) to scroll the rest. The page takes
// the touch itself (touch-action none, pointer capture): left to the WebView, a swipe was cancelled after a few pixels and
// scrolling felt stuck. A flick keeps going and slows down, like a native list.
const TOP=48, VIEW=210, ROW=62, GAP=8; let sy=0, maxY=0, down=null, dragged=false, vel=0, lastY=0, lastT=0;
c.style.touchAction='none';
// A tap on a list that is still coasting only stops it (dragged starts true), it does not select a row.
const clampY=v=>Math.max(0,Math.min(maxY,v));
c.addEventListener('pointerdown',e=>{ down={y:e.clientY,sy}; dragged=Math.abs(vel)>0.05; vel=0; lastY=e.clientY; lastT=performance.now(); try{ c.setPointerCapture(e.pointerId); }catch(_){} });
c.addEventListener('pointermove',e=>{ if(!down) return; const dy=e.clientY-down.y; if(Math.abs(dy)>6) dragged=true; if(!dragged) return;
  sy=clampY(down.sy-dy); const t=performance.now(), dt=Math.max(1,t-lastT); vel=0.8*((lastY-e.clientY)/dt)+0.2*vel; lastY=e.clientY; lastT=t; });
const release=()=>{ if(down&&dragged&&performance.now()-lastT>80) vel=0; down=null; };
c.addEventListener('pointerup',release); c.addEventListener('pointercancel',release);
c.addEventListener('wheel',e=>{ vel=0; sy=clampY(sy+e.deltaY); e.preventDefault(); },{passive:false});
// Momentum: px per ms, decays each frame; called from render (the shell redraws every frame).
let lastFrame=performance.now();
function coast(){ const t=performance.now(), dt=Math.min(50,t-lastFrame); lastFrame=t; if(down||Math.abs(vel)<0.02){ if(!down) vel=0; return; }
  sy=clampY(sy+vel*dt); if(sy===0||sy===maxY) vel=0; vel*=Math.pow(0.995,dt); }
// The Done button lies inside its issue's row, so buttons are tested before rows (the first hit wins). A drag is not a tap.
c.addEventListener('click',e=>{ if(dragged){ dragged=false; return; } const x=e.offsetX, y=e.offsetY, inside=h=> x>=h.x&&x<=h.x+h.w&&y>=h.y&&y<=h.y+h.h&&y>=TOP&&y<=TOP+VIEW;
  for(const h of hit){ if(h.btn&&inside(h)){ pending[h.uid]=Date.now(); sel=null; act('/tasks/done/'+h.uid).then(()=>setTimeout(poll,1500)); return; } }
  for(const h of hit){ if(!h.btn&&inside(h)){ sel= sel===h.uid? null : h.uid; selAt=Date.now(); return; } }
  sel=null; });
function bars(x,y,p,col){ for(let i=0;i<4;i++){ g.fillStyle= (p&&i<5-p)?col:'rgba(255,255,255,.14)'; g.fillRect(x+i*6,y+12-(i+1)*3,4,(i+1)*3); } }
// Local calendar date as YYYY-MM-DD (toISOString would give the UTC date, a day off in the evening east of Greenwich).
function ymd(d){ return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0'); }
function render(d){
  coast(); hit=[]; if(sel&&Date.now()-selAt>8000) sel=null;
  if(!d.hasKey){ txt('Add your Linear API key in Deckhand',40,130,32,'#9aa3b2','left','700'); txt('Apps → Tasks. The key stays on the Mac.',40,172,19,'#6b7280'); return; }
  const items=(d.issues||[]).filter(i=>!(pending[i.uid]&&Date.now()-pending[i.uid]<20000)); if(d.error&&!items.length){ txt(d.error,40,150,22,'#f87171'); return; }
  const today=ymd(new Date()), week=ymd(new Date(Date.now()+7*86400000));
  const due=items.filter(i=>i.due&&i.due<=week).length, over=items.filter(i=>i.due&&i.due<today).length;
  txt((d.me?d.me+' · ':'')+items.length+' open',40,34,15,'#8b94a6','left','600');
  txt((over? over+' overdue':'')+(over&&due?' · ':'')+(due? due+' due this week':''),1384,34,15,over?'#f87171':'#8b94a6','right','600');
  if(d.error) txt(clip(d.error,80),712,34,13,'#f87171','center');
  if(!items.length){ txt('Nothing assigned to you. Enjoy it.',40,150,30,'#9aa3b2','left','700'); return; }
  const pc={1:'#f87171',2:'#fbbf24',3:'#60a5fa',4:'#8b94a6'};
  const x=40, W=1336, H=ROW;
  maxY=Math.max(0,items.length*(ROW+GAP)-GAP-VIEW); sy=Math.min(sy,maxY);
  g.save(); g.beginPath(); g.rect(0,TOP,1424,VIEW); g.clip();
  items.forEach((it,i)=>{ const y=TOP+i*(ROW+GAP)-sy, isSel=sel===it.uid; if(y+H<TOP||y>TOP+VIEW) return;
    rr(x,y,W,H,10, isSel?'rgba(74,222,128,.14)':it.stateType==='started'?'rgba(96,165,250,.12)':'rgba(255,255,255,.06)');
    hit.push({x,y,w:W,h:H,uid:it.uid});
    bars(x+18,y+24,it.priority,pc[it.priority]||'#8b94a6');
    // Small line: id, then the due date. Big line: the title, cut off before the pill or the Done button on the right.
    txt(it.id,x+56,y+25,15,'#8b94a6','left','600');
    if(it.due){ g.font='600 15px -apple-system,Roboto,Helvetica,Arial,sans-serif'; const late=it.due<today; txt('·  '+(late?'overdue ':'due ')+it.due.slice(5),x+56+g.measureText(it.id).width+10,y+25,15,late?'#f87171':'#8b94a6','left','600'); }
    g.font='600 21px -apple-system,Roboto,Helvetica,Arial,sans-serif'; let t=it.title||''; const maxW=W-56-190;
    if(g.measureText(t).width>maxW){ while(t.length>1&&g.measureText(t+'…').width>maxW) t=t.slice(0,-1); t+='…'; }
    txt(t,x+56,y+49,21,'#fff','left','600');
    const bx=x+W-160;
    if(isSel){ rr(bx,y+11,146,40,20,'#4ade80'); txt('✓  Done',bx+73,y+38,18,'#0b2e17','center','700'); hit.push({x:bx,y:y+11,w:146,h:40,uid:it.uid,btn:true}); }
    else { rr(bx,y+19,146,24,12,it.color||'#4b5363'); txt(clip(it.state,16),bx+73,y+36,13,'#fff','center','700'); } });
  g.restore();
  // Scroll bar: only when there is more than fits.
  if(maxY>0){ const th=Math.max(36,VIEW*VIEW/(VIEW+maxY)), ty=TOP+(VIEW-th)*(sy/maxY); rr(1390,TOP,6,VIEW,3,'rgba(255,255,255,.08)'); rr(1390,ty,6,th,3,'rgba(255,255,255,.45)'); }
  if(!sel) txt(items.length>3?'tap an issue to mark it done · swipe to scroll':'tap an issue to mark it done',40,274,12,'#4b5363','left');
}
