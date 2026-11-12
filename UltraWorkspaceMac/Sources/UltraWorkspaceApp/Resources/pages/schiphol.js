const POLL=10000;
// Amsterdam Schiphol as a tower would sketch it: the six runways on the left with the aircraft around them
// (arriving cyan, departing amber, on the ground grey), the runways in use for landing and take-off with the last
// 15 minutes' counts in the middle, and on the right the next arrivals and departures (with a Schiphol API key) or
// the latest arrivals and departures seen on ADS-B. Positions within 5 km of the field's centre are to scale; further
// out the distance is compressed, and an arriving or departing aircraft beyond the panel sits on its edge, one per
// runway with the number behind it.
const CYAN='#38bdf8', AMBER='#fbbf24', DIM='#8b94a6', FAINT='#4b5363', RED='#f87171', GREEN='#4ade80';
function font(size,weight){ g.font=(weight||'400')+' '+size+'px -apple-system,Roboto,Helvetica,Arial,sans-serif'; }
function wid(s,size,weight){ font(size,weight); return g.measureText(s).width; }
function ago2(s){ return s<90?'just now':Math.round(s/60)+' min ago'; }
// Schematic: field centre (km from the reference point), px per km, linear out to R0 km, then compressed.
const SX=16, SY=14, SW=500, SH=252, CX=-0.5, CY=1.85, K=26, R0=5, F=0.2;
function proj(x,y){ let dx=x-CX, dy=y-CY; const r=Math.hypot(dx,dy); if(r>R0){ const s=(R0+(r-R0)*F)/r; dx*=s; dy*=s; } return [SX+SW/2+dx*K, SY+SH/2-dy*K]; }
function arrow(x,y,trk,size,col){ g.save(); g.translate(x,y); g.rotate((trk||0)*Math.PI/180); g.fillStyle=col; g.beginPath();
  g.moveTo(0,-size); g.lineTo(size*.62,size*.75); g.lineTo(0,size*.38); g.lineTo(-size*.62,size*.75); g.closePath(); g.fill(); g.restore(); }
function schematic(d){
  boxes=[]; idle=[];
  rr(SX,SY,SW,SH,14,'rgba(255,255,255,.04)');
  g.save(); g.beginPath(); g.rect(SX,SY,SW,SH); g.clip();
  // 5 km ring: inside it to scale, outside compressed
  g.strokeStyle='rgba(255,255,255,.08)'; g.lineWidth=1; g.setLineDash([3,5]); g.beginPath(); g.arc(SX+SW/2,SY+SH/2,R0*K,0,7); g.stroke(); g.setLineDash([]);
  txt('5 km',SX+SW/2+R0*K+6,SY+SH/2+4,10,FAINT);
  const land=new Set((d.landing||[]).map(r=>r.rwy)), off=new Set((d.takeoff||[]).map(r=>r.rwy));
  (d.runways||[]).forEach(r=>{ const [ax,ay]=proj(r.a.x,r.a.y), [bx,by]=proj(r.b.x,r.b.y);
    const used=[r.a.id,r.b.id].filter(e=>land.has(e)||off.has(e));
    const col=used.some(e=>land.has(e))&&used.some(e=>off.has(e))?'#a5b4fc':used.some(e=>land.has(e))?CYAN:used.length?AMBER:'#5b6372';
    g.strokeStyle=col; g.lineWidth=used.length?7:5; g.lineCap='round'; g.beginPath(); g.moveTo(ax,ay); g.lineTo(bx,by); g.stroke(); g.lineCap='butt';
    // idents just beyond each end, on the extension of the runway: those in use now, the others later where there is room
    const L=Math.hypot(bx-ax,by-ay)||1, ux=(bx-ax)/L, uy=(by-ay)/L;
    [[r.a,ax-ux*13,ay-uy*13],[r.b,bx+ux*13,by+uy*13]].forEach(([e,x,y])=>{ const on=land.has(e.id)||off.has(e.id);
      if(on) put(e.id,x,y+4,12,land.has(e.id)?CYAN:AMBER,'center','700'); else idle.push([e.id,x,y+4]); }); });
  // aircraft: the ones in the air first, then those on the runways' business on top
  const ac=(d.aircraft||[]).slice().sort((a,b)=>(a.st==='arr'||a.st==='dep')-(b.st==='arr'||b.st==='dep'));
  const M=12, edge={}, out=(x,y)=>x<SX+M||x>SX+SW-M||y<SY+M||y>SY+SH-M;
  ac.forEach(a=>{ const [x,y]=proj(a.x,a.y);
    if(a.st==='gnd'){ g.fillStyle='rgba(203,213,225,.45)'; g.beginPath(); g.arc(x,y,2.2,0,7); g.fill(); return; }
    const big=a.st==='arr'||a.st==='dep', col=a.st==='arr'?CYAN:a.st==='dep'?AMBER:'rgba(148,163,184,.55)';
    if(out(x,y)){ if(!big) return;
      // beyond the panel: keep the nearest per runway and phase on the edge, count the others
      const k=a.st+a.rwy, dist=Math.hypot(a.x-CX,a.y-CY), e=edge[k];
      if(e){ e.n++; if(dist<e.dist){ e.a=a; e.dist=dist; } } else edge[k]={a,dist,n:1}; return; }
    arrow(x,y,a.trk,big?8:5,col);
    if(big&&a.cs) label(a.cs,x,y,col); });
  Object.values(edge).forEach(e=>{ const a=e.a, col=a.st==='arr'?CYAN:AMBER; let [x,y]=proj(a.x,a.y);
    x=Math.max(SX+M,Math.min(SX+SW-M,x)); y=Math.max(SY+M,Math.min(SY+SH-M,y));
    arrow(x,y,a.trk,8,col); label((a.cs||'')+(e.n>1?' +'+(e.n-1):''),x,y,col); });
  idle.forEach(([s,x,y])=>put(s,x,y,10,FAINT,'center','600',true));
  g.restore();
  txt('N ↑',SX+12,SY+22,11,FAINT,'left','600');
  const age=d.age; txt(age<0?'connecting…':age<40?'live':'last seen '+ago(age)+' ago',SX+SW-12,SY+SH-10,11,age>=0&&age<40?FAINT:(d.error?RED:DIM),'right');
}
// Text on the schematic, remembering where it went; `optional` text is left out where it would overlap.
let boxes=[], idle=[];
function put(s,x,y,size,col,align,weight,optional){ const w=wid(s,size,weight), x0=align==='center'?x-w/2:align==='right'?x-w:x, b=[x0-2,y-size,x0+w+2,y+3];
  if(optional&&boxes.some(o=>b[0]<o[2]&&b[2]>o[0]&&b[1]<o[3]&&b[3]>o[1])) return false;
  boxes.push(b); txt(s,x,y,size,col,align,weight); return true; }
// An aircraft's callsign: to the right of it, else to the left, else left out (the arrow stays).
function label(s,x,y,col){ if(!s) return; const ly=y<SY+24?y+14:y-5; g.save(); g.shadowColor='rgba(0,0,0,.9)'; g.shadowBlur=3;
  const first=x>SX+SW-110?'right':'left'; for(const al of [first,first==='left'?'right':'left']) if(put(s,al==='left'?x+11:x-11,ly,11,col,al,'600',true)) break;
  g.restore(); }
function chips(list,y,col,empty){
  if(!list.length){ txt(empty,X1,y+26,15,FAINT); return; }
  list.slice(0,2).forEach((r,i)=>{ const x=X1+i*134;
    rr(x,y,124,62,10,'rgba(255,255,255,.06)'); g.fillStyle=col; g.fillRect(x,y+12,4,38);
    txt(r.rwy,x+16,y+34,30,col,'left','700');
    if(r.now) { g.fillStyle=col; g.beginPath(); g.arc(x+112,y+13,4,0,7); g.fill(); }
    txt(clip(r.name,15),x+16,y+53,12,DIM,'left','600'); });
  if(list.length>2) txt('+'+(list.length-2),X1+262,y+38,14,DIM,'right');
}
const X1=532;
function runwaysColumn(d){
  txt('Schiphol',X1,42,24,'#fff','left','700');
  txt('LANDING',X1,72,12,CYAN,'left','700'); chips(d.landing||[],80,CYAN,'none seen');
  txt('TAKE-OFF',X1,164,12,AMBER,'left','700'); chips(d.takeoff||[],172,AMBER,'none seen');
  if(d.age<0){ txt(clip(d.error||'Fetching the traffic…',40),X1,262,13,d.error?RED:DIM); return; }
  const w=d.watching||0, span=w>=890?'15 min':'the last '+Math.max(1,Math.round(w/60))+' min';
  txt('↓ '+(d.arr15||0),X1,262,16,CYAN,'left','700'); const a=wid('↓ '+(d.arr15||0),16,'700');
  txt('↑ '+(d.dep15||0),X1+a+14,262,16,AMBER,'left','700'); const b=wid('↑ '+(d.dep15||0),16,'700');
  txt('in '+span,X1+a+b+28,262,13,DIM);
}
// Board: two columns, four rows each.
const BX=[816,1072], BW=240, ROW=48;
function boardRow(x,y,o,arrival){
  const col=arrival?CYAN:AMBER;
  txt(o.t,x,y,17,o.x?FAINT:'#fff','left','700'); const tw=wid(o.t,17,'700');
  txt(o.f,x+tw+10,y,17,o.x?FAINT:col,'left','700');
  const st=o.x?'Cancelled':(o.st||''); if(st){ txt(clip(st,16),x+BW-4,y,12,o.x?RED:o.live?col:(st==='Delayed'||o.late?AMBER:DIM),'right','600'); }
  let sub=clip(o.place||o.iata||'',o.est?18:26); txt(sub,x,y+19,14,o.x?FAINT:'#c7cdd8');
  const right=o.est?'exp '+o.est:(o.gate?'gate '+o.gate:''); if(right) txt(right,x+BW-4,y+19,12,o.late?AMBER:DIM,'right');
}
function recentRow(x,y,m,arrival){
  const col=arrival?CYAN:AMBER;
  txt(m.f||m.cs||'—',x,y,17,'#fff','left','700');
  rr(x+BW-40,y-15,36,20,5,arrival?'rgba(56,189,248,.18)':'rgba(251,191,36,.18)'); txt(m.rwy,x+BW-22,y,12,col,'center','700');
  const when=m.live?(arrival?'on final':'climbing out'):ago2(m.ago);
  txt((m.place?clip((arrival?'from ':'to ')+m.place,27-when.length)+' · ':'')+when,x,y+19,13,m.live?col:DIM);
}
function board(d){
  // The timetable when there is one; with no key, or a key Schiphol refuses, what ADS-B saw.
  if(d.hasKey&&((d.arrivals||[]).length||(d.departures||[]).length||!d.boardError)){
    [['ARRIVALS',d.arrivals||[],true],['DEPARTURES',d.departures||[],false]].forEach(([h,list,arr],i)=>{ const x=BX[i];
      txt(h,x,40,12,arr?CYAN:AMBER,'left','700');
      list.slice(0,4).forEach((o,j)=>boardRow(x,74+j*ROW,o,arr));
      if(!list.length) txt(d.boardError?'—':'loading the timetable…',x,80,14,FAINT); });
    if(d.boardError) txt(clip('Schiphol: '+d.boardError,80),BX[0],272,12,AMBER);
    return;
  }
  [['ARRIVALS SEEN',d.recentArr||[],true],['DEPARTURES SEEN',d.recentDep||[],false]].forEach(([h,list,arr],i)=>{ const x=BX[i];
    txt(h,x,40,12,arr?CYAN:AMBER,'left','700');
    list.slice(0,4).forEach((m,j)=>recentRow(x,74+j*ROW,m,arr));
    if(!list.length) txt(d.age<0?'…':'nothing yet',x,80,14,FAINT); });
  if(d.hasKey) txt(clip('Timetable: '+(d.boardError||'loading…'),80),BX[0],272,12,RED);
  else txt('Timetable: add a Schiphol API key in Deckhand → Apps → Schiphol',BX[0],272,12,FAINT);
}
function render(d){
  schematic(d); runwaysColumn(d); board(d);
}
