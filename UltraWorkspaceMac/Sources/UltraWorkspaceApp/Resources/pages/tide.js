const POLL=60000;
// One card per gauge (Rijkswaterstaat, cm NAP): the level now and which way it goes, the next high and low water
// for a tidal station, and today 00–24 h with the measured level over the astronomical tide (dashed). A river gauge
// (no tide) shows its level, trend and the day's range. On the right a small almanac: sun, day length, moon.
const CYAN='#38bdf8', AMBER='#fbbf24', DIM='#8b94a6', FAINT='#4b5363', TIDE='rgba(148,163,184,.75)';
function hm(t){ if(!t) return '—'; return new Date(t*1000).toTimeString().slice(0,5); }
function cm(v){ return v>0? '+'+v : v<0? '−'+Math.abs(v) : '0'; }
function dur(s){ return Math.floor(s/3600)+' h '+String(Math.round(s%3600/60)).padStart(2,'0')+' min'; }
function font(size,weight){ g.font=(weight||'400')+' '+size+'px -apple-system,Roboto,Helvetica,Arial,sans-serif'; }
function wide(s,size,weight){ font(size,weight); return g.measureText(s).width; }
function moonDisc(cx,cy,r,ill,waxing){   // as on the Sun & Moon page, smaller
  g.fillStyle='#2a3140'; g.beginPath(); g.arc(cx,cy,r,0,7); g.fill();
  g.fillStyle='#f3f4f6'; g.beginPath(); g.arc(cx,cy,r,-Math.PI/2,Math.PI/2,!waxing); g.fill();
  const rx=r*Math.abs(1-2*ill); g.fillStyle=ill>0.5?'#f3f4f6':'#2a3140'; g.beginPath(); g.ellipse(cx,cy,Math.max(0.01,rx),r,0,0,7); g.fill();
  g.strokeStyle='rgba(255,255,255,.18)'; g.lineWidth=1.5; g.beginPath(); g.arc(cx,cy,r,0,7); g.stroke();
}
function render(d){
  const st=d.stations||[];
  if(!st.length){ txt('No gauges chosen',40,140,26,'#9aa3b2','left','700'); txt('Deckhand → Apps → Tide',40,176,18,DIM); return; }
  const n=st.length, gap=12, X0=20, X1=1060, W=(X1-X0-gap*(n-1))/n;
  st.forEach((s,i)=>card(s,X0+i*(W+gap),12,W,256,d));
  almanac(d.almanac||{},1080,d);
}
function card(s,x,y,W,H,d){
  rr(x,y,W,H,14,'rgba(255,255,255,.06)');
  const parts=(s.name||s.code).split(','), title=parts[0].trim(), sub=parts.slice(1).join(',').trim(), chars=Math.floor((W-32)/10);
  txt(clip(title,chars),x+16,y+30,19,'#fff','left','700');
  txt(clip(sub||(s.tide?'tidal':'river gauge'),Math.floor((W-32)/6.6)),x+16,y+48,12,FAINT,'left','600');
  const now=s.now;
  if(!now){ txt(s.error?'Rijkswaterstaat did not answer':'no recent readings',x+16,y+96,15,s.error?'#f87171':DIM); return; }
  const age=d.now-now.t, stale=age>3*3600;
  // the level now, and which way it goes
  const big=cm(now.v); txt(big,x+16,y+92,38,stale?DIM:'#fff','left','700');
  txt('cm NAP',x+22+wide(big,38,'700'),y+92,13,DIM,'left','600');
  const tr=s.trend, steady=tr==null||Math.abs(tr)<2;
  const tl=steady?'steady':(tr>0?'▲ ':'▼ ')+Math.round(Math.abs(tr))+' cm/h';
  txt(tl,x+W-16,y+68,14,steady?DIM:(tr>0?CYAN:AMBER),'right','700');
  txt(stale?'at '+hm(now.t):hm(now.t),x+W-16,y+90,12,stale?AMBER:FAINT,'right');
  // next high and low water, or the day's range for a river
  let line='', l2='';
  if(s.tide){
    const next=(s.extremes||[]).filter(e=>e.t>d.now).slice(0,2);
    const ex=e=>(e.hw?'HW ':'LW ')+hm(e.t)+'  '+cm(e.v);
    line=next.map(ex).join('   ·   ');
    if(next.length>1&&wide(line,14,'600')>W-32) line=ex(next[0]);   // a narrow card: the next one only
    if(!next.length) line='no tide table today';
    if(s.surge!=null) l2=Math.abs(s.surge)<5?'on the predicted tide':Math.abs(s.surge)+' cm '+(s.surge>0?'above':'below')+' the predicted tide';
  } else if(s.min!=null){ line='today '+cm(s.min)+' to '+cm(s.max)+' cm'; l2='river gauge, no tide'; }
  txt(clip(line,Math.floor((W-32)/7.4)),x+16,y+116,14,'#e5e9f0','left','600');
  if(l2) txt(clip(l2,Math.floor((W-32)/6.4)),x+16,y+134,12,s.surge!=null&&Math.abs(s.surge)>=30?AMBER:DIM);
  chart(s,x+14,y+146,W-28,96,d);
}
function chart(s,x,y,w,h,d){
  const t0=d.day.start, t1=d.day.end, meas=s.meas||[], astro=s.astro||[];
  const vals=meas.map(p=>p[1]).concat(astro.map(p=>p[1]));
  if(!vals.length) return;
  let lo=Math.min(...vals), hi=Math.max(...vals); if(hi-lo<20){ const m=(hi+lo)/2; lo=m-10; hi=m+10; }
  const pad=(hi-lo)*0.18; lo-=pad; hi+=pad*1.2;
  const X=t=>x+(t-t0)/(t1-t0)*w, Y=v=>y+h-16-(v-lo)/(hi-lo)*(h-16);
  // hours along the bottom, NAP 0 when it is in view
  g.fillStyle='rgba(255,255,255,.07)'; [6,12,18].forEach(k=>{ const xx=X(t0+k*3600); g.fillRect(xx,y,1,h-16); txt(String(k).padStart(2,'0'),xx,y+h-2,11,FAINT,'center'); });
  if(lo<0&&hi>0){ g.strokeStyle='rgba(255,255,255,.12)'; g.setLineDash([2,4]); g.lineWidth=1; g.beginPath(); g.moveTo(x,Y(0)); g.lineTo(x+w,Y(0)); g.stroke(); g.setLineDash([]); txt('NAP',x+2,Y(0)-3,10,FAINT,'left'); }
  const line=(pts,col,width,dash)=>{ if(pts.length<2) return; g.strokeStyle=col; g.lineWidth=width; g.setLineDash(dash||[]); g.lineJoin='round'; g.beginPath();
    pts.forEach((p,i)=>{ const px=X(p[0]), py=Y(p[1]); i?g.lineTo(px,py):g.moveTo(px,py); }); g.stroke(); g.setLineDash([]); };
  line(astro,TIDE,1.5,[5,4]);
  if(meas.length>1){ const grd=g.createLinearGradient(0,y,0,y+h-16); grd.addColorStop(0,'rgba(56,189,248,.28)'); grd.addColorStop(1,'rgba(56,189,248,0)');
    g.fillStyle=grd; g.beginPath(); g.moveTo(X(meas[0][0]),y+h-16); meas.forEach(p=>g.lineTo(X(p[0]),Y(p[1]))); g.lineTo(X(meas[meas.length-1][0]),y+h-16); g.closePath(); g.fill(); }
  line(meas,CYAN,2.5);
  // high and low waters of today on the predicted curve
  (s.extremes||[]).filter(e=>e.t>=t0&&e.t<t1).forEach(e=>{ const ex=X(e.t), ey=Y(e.v);
    g.fillStyle=e.hw?'#e2e8f0':'#94a3b8'; g.beginPath(); g.arc(ex,ey,3,0,7); g.fill();
    const lx=Math.min(Math.max(ex,x+14),x+w-14); txt(hm(e.t),lx,e.hw?ey-7:ey+15,10,DIM,'center'); });
  // now
  const nx=X(d.now); if(nx>x&&nx<x+w){ g.fillStyle='rgba(255,255,255,.35)'; g.fillRect(nx,y,1,h-16);
    const last=meas[meas.length-1]; if(last){ g.fillStyle=CYAN; g.beginPath(); g.arc(X(last[0]),Y(last[1]),4.5,0,7); g.fill(); } }
}
function almanac(a,x,d){
  const date=new Date(d.now*1000);
  txt(date.toLocaleDateString(undefined,{weekday:'long'}),x,40,17,'#fff','left','700');
  txt(date.toLocaleDateString(undefined,{day:'numeric',month:'long',year:'numeric'}),x,62,14,DIM);
  if(a.rise===undefined){ txt('Set a location in Deckhand',x,110,14,DIM); txt('for sun and moon',x,130,14,DIM); }
  else {
    txt('☀',x,104,18,AMBER); txt('↑ '+hm(a.rise)+'   ↓ '+hm(a.set),x+26,104,19,'#fff','left','700');
    const ch=a.dayChange||0, chs=Math.abs(ch)<60? (ch===0?'same as yesterday':(ch>0?'+':'−')+Math.abs(ch)+' s') : (ch>0?'+':'−')+Math.round(Math.abs(ch)/60)+' min';
    txt('day '+dur(a.dayLength||0),x,128,14,'#d6dbe6'); txt(chs+' on yesterday',x,146,12,ch>=0?DIM:FAINT);
    const m=a.moon; if(m){ moonDisc(x+20,194,19,m.illumination,m.waxing);
      txt(m.name,x+50,190,15,'#fff','left','700');
      const f=t=>new Date(t*1000).toLocaleDateString(undefined,{weekday:'short',day:'numeric',month:'short'});
      const nf=m.nextFull<m.nextNew; txt(Math.round(m.illumination*100)+' % · '+(nf?'full ':'new ')+f(nf?m.nextFull:m.nextNew),x+50,208,12,DIM); }
  }
  txt(clip(a.place||'',30),x,236,12,FAINT);
  txt('Rijkswaterstaat · '+hm(d.at),x,258,11,FAINT);
}
