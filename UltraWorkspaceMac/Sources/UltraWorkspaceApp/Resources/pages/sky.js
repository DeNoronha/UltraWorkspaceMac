const POLL=20000;
function hm(t){ if(!t) return '—'; const d=new Date(t*1000); return d.toTimeString().slice(0,5); }
function dur(s){ return Math.floor(s/3600)+' h '+String(Math.round(s%3600/60)).padStart(2,'0')+' min'; }
function moonDisc(cx,cy,r,ill,waxing){
  g.fillStyle='#2a3140'; g.beginPath(); g.arc(cx,cy,r,0,7); g.fill();
  g.fillStyle='#f3f4f6'; g.beginPath(); g.arc(cx,cy,r,-Math.PI/2,Math.PI/2, !waxing); g.fill();   // lit half (right when waxing)
  const rx=r*Math.abs(1-2*ill); g.fillStyle= ill>0.5? '#f3f4f6':'#2a3140'; g.beginPath(); g.ellipse(cx,cy,Math.max(0.01,rx),r,0,0,7); g.fill();
  g.strokeStyle='rgba(255,255,255,.18)'; g.lineWidth=1.5; g.beginPath(); g.arc(cx,cy,r,0,7); g.stroke();
  // a few craters for texture
  g.fillStyle='rgba(0,0,0,.08)'; [[-.3,-.2,.18],[.25,.1,.12],[-.05,.35,.09],[.1,-.45,.07]].forEach(c=>{ g.beginPath(); g.arc(cx+c[0]*r,cy+c[1]*r,c[2]*r,0,7); g.fill(); });
}
function render(d){
  const s=d.sun, m=d.moon; if(!s||!m){ txt('Working out the sky for '+(d.place||'your location')+'…',40,150,22,'#8b94a6'); return; }
  // --- sun arc (left 700 px)
  const x0=60, x1=660, hy=190, top=50, now=d.now;
  g.strokeStyle='rgba(255,255,255,.18)'; g.lineWidth=1.5; g.beginPath(); g.moveTo(x0-20,hy); g.lineTo(x1+20,hy); g.stroke();
  g.strokeStyle='rgba(251,191,36,.35)'; g.setLineDash([5,6]); g.beginPath(); g.ellipse((x0+x1)/2,hy,(x1-x0)/2,hy-top,0,Math.PI,2*Math.PI); g.stroke(); g.setLineDash([]);
  const rise=s.rise, set=s.set;
  if(rise&&set){ const f=Math.min(1.08,Math.max(-0.08,(now-rise)/(set-rise))); const a=Math.PI+f*Math.PI; const sx=(x0+x1)/2+Math.cos(a)*(x1-x0)/2, sy=hy+Math.sin(a)*(hy-top);
    if(f>=0&&f<=1){ const gl=g.createRadialGradient(sx,sy,4,sx,sy,40); gl.addColorStop(0,'rgba(251,191,36,.9)'); gl.addColorStop(1,'rgba(251,191,36,0)'); g.fillStyle=gl; g.beginPath(); g.arc(sx,sy,40,0,7); g.fill(); }
    g.fillStyle= f>=0&&f<=1?'#fbbf24':'#6b7280'; g.beginPath(); g.arc(sx,Math.min(sy,hy+6),11,0,7); g.fill(); }
  txt('↑ '+hm(rise),x0,hy+28,20,'#fff','left','700'); txt('↓ '+hm(set),x1,hy+28,20,'#fff','right','700');
  txt('sunrise',x0,hy+48,13,'#8b94a6','left'); txt('sunset',x1,hy+48,13,'#8b94a6','right');
  txt('noon '+hm(s.noon),(x0+x1)/2,top-16,14,'#8b94a6','center');
  txt(d.place||'',x0,30,15,'#8b94a6','left','600'); txt(s.elevation>0? 'sun '+s.elevation+'° up':'sun below the horizon',x1,30,15,'#8b94a6','right');
  txt('day '+dur(s.dayLength)+'  ·  golden '+hm(s.goldenStart)+'  ·  dusk '+hm(s.dusk)+'  ·  dawn '+hm(s.dawn),(x0+x1)/2,hy+76,15,'#b4bccb','center');
  // --- moon (right)
  moonDisc(860,140,92,m.illumination,m.waxing);
  txt(m.name,990,70,34,'#fff','left','700');
  txt(Math.round(m.illumination*100)+' % lit  ·  '+Math.round(m.age)+' days old',990,104,18,'#d6dbe6');
  txt('↑ '+hm(m.rise)+'   ↓ '+hm(m.set)+(m.elevation>0?'   ·  up now, '+Math.round(m.elevation)+'°':''),990,146,18,'#b4bccb');
  const fmt=t=> t? new Date(t*1000).toLocaleDateString(undefined,{weekday:'short',day:'numeric',month:'short'}) : '—';
  txt('full '+fmt(m.nextFull)+'   ·   new '+fmt(m.nextNew),990,180,17,'#8b94a6');
  txt(Math.round(m.distanceKm/1000)+' thousand km away',990,214,15,'#6b7280');
}
