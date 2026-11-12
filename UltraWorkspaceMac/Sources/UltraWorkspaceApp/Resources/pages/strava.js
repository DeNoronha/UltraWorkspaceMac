const POLL=60000;
// Training: the athlete's own Strava activities, fetched by Deckhand on the Mac (the tokens never reach the bar).
// Left the latest activity with its route (the shape only, drawn here without map tiles), then the next four, this
// week against last week per sport, and the year so far. Tap an activity for its details; tap again (or wait 90 s)
// to go back. "Powered by Strava" as Strava's brand guidelines ask; the app's name may not contain "Strava".
const DIM='#8b94a6', FAINT='#4b5363', TEXT='#e5e9f0', CARD='rgba(255,255,255,.06)';
const SPORT={run:'#fb923c', ride:'#60a5fa', swim:'#2dd4bf', walk:'#a3e635', other:'#c084fc'};
let hit=[], sel=null, selAt=0;
c.addEventListener('click',e=>{ if(sel!==null){ sel=null; return; }
  const x=e.offsetX, y=e.offsetY; for(const h of hit){ if(x>=h.x&&x<=h.x+h.w&&y>=h.y&&y<=h.y+h.h){ sel=h.id; selAt=Date.now(); return; } } });
function col(s){ return SPORT[s]||SPORT.other; }
function font(size,weight){ g.font=(weight||'400')+' '+size+'px -apple-system,Roboto,Helvetica,Arial,sans-serif'; }
function width(s,size,weight){ font(size,weight); return g.measureText(s).width; }
// Shrinks a name until it fits `w` px.
function fit(s,w,size,weight){ s=s||''; if(width(s,size,weight)<=w) return s; while(s.length>1&&width(s+'…',size,weight)>w) s=s.slice(0,-1); return s+'…'; }
function badge(label,x,y,s){ const w=width(label,12,'700')+18; rr(x,y-15,w,21,10.5,col(s)); txt(label,x+w/2,y,12,'#10131a','center','700'); return w; }
// The route's shape (unit box, y down) fitted into a w×h box.
function route(pts,x,y,w,h,s,lw){
  rr(x,y,w,h,12,'rgba(0,0,0,.28)');
  if(!pts||pts.length<2){ txt('no route',x+w/2,y+h/2+5,13,FAINT,'center'); return; }
  const pad=Math.max(10,w*.08), side=Math.min(w,h)-2*pad, ox=x+(w-side)/2, oy=y+(h-side)/2;
  g.strokeStyle=col(s); g.lineWidth=lw||3; g.lineJoin='round'; g.lineCap='round'; g.beginPath();
  pts.forEach((p,i)=>{ const px=ox+p[0]*side, py=oy+p[1]*side; if(i) g.lineTo(px,py); else g.moveTo(px,py); }); g.stroke();
  const a=pts[0], b=pts[pts.length-1];
  g.fillStyle='#4ade80'; g.beginPath(); g.arc(ox+a[0]*side,oy+a[1]*side,lw?6:4.5,0,7); g.fill();
  g.fillStyle='#fff'; g.beginPath(); g.arc(ox+b[0]*side,oy+b[1]*side,lw?5:3.5,0,7); g.fill();
}
function stat(v,label,x,y,size){ txt(v||'–',x,y,size||26,'#fff','left','700'); txt(label,x,y+18,12,DIM,'left','600'); }
function render(d){
  hit=[]; if(sel!==null&&Date.now()-selAt>90000) sel=null;
  if(!d.hasClient||!d.connected){
    txt('Connect Strava in Deckhand',40,124,32,'#9aa3b2','left','700');
    txt(d.hasClient?'Apps → Training → Connect Strava. The tokens stay on the Mac.':'Apps → Training: your own Strava API application, then Connect. The tokens stay on the Mac.',40,166,19,'#6b7280');
    if(d.error) txt(clip(d.error,110),40,200,15,'#f87171');
    footer(d,true); return; }
  if(!d.latest){ txt(d.error?clip(d.error,90):'Reading your activities…',40,150,24,d.error?'#f87171':'#9aa3b2','left','700'); footer(d,true); return; }
  if(!d.latest.length){ txt('No activities yet',40,140,30,'#9aa3b2','left','700'); txt('Your next one shows up here within a quarter of an hour.',40,176,18,'#6b7280'); footer(d); return; }
  const a=sel!==null&&d.latest.find(q=>q.id===sel); if(sel!==null&&!a) sel=null;
  if(a) detail(a); else overview(d);
  footer(d);
}
// The error goes in the footer only when the body does not show it already.
function footer(d,shown){
  txt('Powered by Strava',24,272,12,DIM,'left','600');
  const err=d.error&&!shown, t=err?clip(d.error,90):[d.updated?'updated '+ago(Math.max(0,(d.at||0)-d.updated))+' ago':'',d.athlete||''].filter(x=>x).join(' · ');
  txt(t,1316,272,12,err?'#f87171':FAINT,'right');
}
function overview(d){
  const y=14, H=240;
  // The latest activity.
  const a=d.latest[0], X=24, W=470;
  rr(X,y,W,H,14,CARD); hit.push({x:X,y,w:W,h:H,id:a.id});
  route(a.route,X+14,y+14,150,150,a.sport);
  const tx=X+180; const bw=badge(a.label.toUpperCase().slice(0,18),tx,y+32,a.sport); txt(clip(a.when,26),tx+bw+10,y+32,13,DIM,'left','600');
  txt(fit(a.name,W-196,21,'700'),tx,y+64,21,'#fff','left','700');
  stat(a.dist||a.moving,a.dist?'distance':'time',tx,y+108); stat(a.dist?a.moving:'','moving time',tx+150,y+108);
  stat(a.pace,a.sport==='run'||a.sport==='walk'||a.sport==='swim'?'pace':'speed',tx,y+162,22); stat(a.elev||'0 m','elevation',tx+150,y+162,22);
  txt(a.hr?'♥ '+a.hr+' bpm':'',X+14,y+192,14,'#f87171','left','600');
  txt('tap for details',X+14,y+222,12,FAINT,'left');
  if(a.prs) txt(a.prs+(a.prs>1?' PRs':' PR'),X+W-16,y+222,12,'#fbbf24','right','700');
  // The next four.
  const RX=508, RW=300; rr(RX,y,RW,H,14,CARD); txt('Recent',RX+16,y+26,13,DIM,'left','700');
  const rows=d.latest.slice(1,5);
  rows.forEach((r,i)=>{ const ry=y+40+i*49;
    hit.push({x:RX,y:ry,w:RW,h:49,id:r.id});
    if(i) { g.fillStyle='rgba(255,255,255,.06)'; g.fillRect(RX+14,ry,RW-28,1); }
    g.fillStyle=col(r.sport); g.beginPath(); g.arc(RX+22,ry+18,5,0,7); g.fill();
    const right=r.dist||r.moving, rw=width(right,16,'700');
    txt(fit(r.name,RW-62-rw,16,'600'),RX+34,ry+24,16,TEXT,'left','600');
    txt(right,RX+RW-16,ry+24,16,'#fff','right','700');
    txt(clip(r.when,30),RX+34,ry+42,12,DIM); txt(r.dist?r.moving:'',RX+RW-16,ry+42,12,DIM,'right'); });
  if(!rows.length) txt('nothing else lately',RX+16,y+70,14,FAINT);
  // This week against last week.
  const WX=822, WW=290; rr(WX,y,WW,H,14,CARD); txt('This week',WX+16,y+26,13,DIM,'left','700'); txt('last week',WX+WW-16,y+26,12,FAINT,'right','600');
  const weeks=(d.weeks||[]).slice(0,3);
  weeks.forEach((w,i)=>{ const wy=y+42+i*66, t=w.this, l=w.last, useDist=(t.distM||0)+(l.distM||0)>0;
    txt(w.label,WX+16,wy+22,13,col(w.sport),'left','700');
    txt(useDist?(t.dist||'0'):t.timeText,WX+16+width(w.label,13,'700')+10,wy+22,20,'#fff','left','700');
    txt(useDist?(l.dist||'–'):l.timeText,WX+WW-16,wy+22,14,DIM,'right','600');
    const a1=useDist?t.distM:t.time, b1=useDist?l.distM:l.time, m=Math.max(a1,b1,1), bwid=WW-32;
    rr(WX+16,wy+32,bwid,6,3,'rgba(255,255,255,.08)'); if(a1>0) rr(WX+16,wy+32,Math.max(6,bwid*a1/m),6,3,col(w.sport));
    rr(WX+16,wy+42,bwid,4,2,'rgba(255,255,255,.05)'); if(b1>0) rr(WX+16,wy+42,Math.max(4,bwid*b1/m),4,2,'rgba(255,255,255,.28)');
    txt(t.n+(t.n===1?' activity':' activities')+(useDist&&t.n?' · '+t.timeText:''),WX+16,wy+60,12,DIM); });
  if(!weeks.length) txt('nothing in the last two weeks',WX+16,y+70,14,FAINT);
  // The year so far.
  const YX=1126, YW=190; rr(YX,y,YW,H,14,CARD); txt((d.year||'Year')+' so far',YX+16,y+26,13,DIM,'left','700');
  const ytd=(d.ytd||[]).slice(0,3);
  ytd.forEach((t,i)=>{ const yy=y+42+i*66;
    txt(t.label,YX+16,yy+18,12,col(t.sport),'left','700');
    txt(t.dist,YX+16,yy+42,21,'#fff','left','700');
    txt(t.n+'× · '+t.time,YX+16,yy+60,12,DIM); });
  if(!ytd.length) txt(d.hasStats?'only activities visible to Everyone count':'…',YX+16,y+70,12,FAINT);
}
function detail(a){
  route(a.route,24,14,246,246,a.sport,4);
  const X=292; const bw=badge(a.label.toUpperCase(),X,44,a.sport); txt(a.when+(a.indoor?' · indoor':''),X+bw+12,44,14,DIM,'left','600');
  txt(fit(a.name,1316-X-60,28,'700'),X,86,28,'#fff','left','700');
  const speedy=a.sport==='run'||a.sport==='walk'||a.sport==='swim';
  const tiles=[[a.dist,'distance'],[a.moving,'moving time'],[a.pace,speedy?'pace':'average speed'],[a.elev||'0 m','elevation gain'],
    [a.elapsed,'elapsed time'],[a.hr?a.hr+' bpm':'','average heart rate'],[a.maxSpeed,'max speed'],[a.kj?a.kj+' kJ':(a.kudos!=null?String(a.kudos):''),a.kj?'energy':'kudos']].filter(t=>t[0]);
  const TW=(1316-X-3*14)/4;
  tiles.slice(0,8).forEach((t,i)=>{ const tx=X+(i%4)*(TW+14), ty=106+Math.floor(i/4)*76;
    rr(tx,ty,TW,64,12,CARD); txt(t[0],tx+16,ty+32,24,'#fff','left','700'); txt(t[1],tx+16,ty+52,12,DIM,'left','600'); });
  txt('tap to go back',X,272-0,12,FAINT,'left');
}
