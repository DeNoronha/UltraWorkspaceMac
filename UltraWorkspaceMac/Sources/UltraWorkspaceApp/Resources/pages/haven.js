const POLL=10000;
// One card per place (port or terminal): how many ships are on their way in and how many lie alongside, and the
// first few by name. Tap a card for its approach: a line from the far end of the approach to the berth, each
// arriving ship a dot at its distance. Tap again (or wait 90 s) to go back.
const CYAN='#38bdf8', GREEN='#4ade80', DIM='#8b94a6', FAINT='#4b5363';
let hit=[], sel=null, selAt=0;
c.addEventListener('click',e=>{ if(sel){ sel=null; return; }
  const x=e.offsetX, y=e.offsetY; for(const h of hit){ if(x>=h.x&&x<=h.x+h.w&&y>=h.y&&y<=h.y+h.h){ sel=h.id; selAt=Date.now(); return; } } });
function kmh(s){ return Math.round(s*1.852*10)/10; }
function font(size,weight){ g.font=(weight||'400')+' '+size+'px -apple-system,Roboto,Helvetica,Arial,sans-serif'; }
function stat(n,label,x,y,col){ txt(String(n),x,y,40,col,'left','700'); font(40,'700'); const w=g.measureText(String(n)).width; txt(label,x+w+8,y-4,15,DIM,'left','600'); }
function render(d){
  hit=[]; if(sel&&Date.now()-selAt>90000) sel=null;
  if(!d.hasKey){ txt('Add your aisstream.io key in Deckhand',40,130,32,'#9aa3b2','left','700'); txt('Apps → Haven. The key stays on the Mac.',40,172,19,'#6b7280'); return; }
  const places=d.places||[];
  if(!places.length){ txt(d.error||'No places set',40,150,24,'#f87171'); return; }
  const p=sel&&places.find(q=>q.id===sel); if(sel&&!p) sel=null;
  if(p) detail(p,d); else overview(places,d);
  const status=d.connected?'live':(d.error?clip(d.error,70):'connecting to aisstream.io…');
  txt(status,1316,272,12,d.connected?FAINT:(d.error?'#f87171':DIM),'right');
}
function overview(places,d){
  const n=places.length, gap=14, W=(1292-gap*(n-1))/n;
  places.forEach((p,i)=>{ const x=24+i*(W+gap), y=18, H=238, port=p.kind==='port';
    rr(x,y,W,H,14,'rgba(255,255,255,.06)'); hit.push({x,y,w:W,h:H,id:p.id});
    txt(clip(p.name,Math.floor(W/11)),x+18,y+34,20,'#fff','left','700');
    stat(p.nArriving,'on the way',x+18,y+86,p.nArriving?CYAN:FAINT);
    stat(p.nAlongside,port?'in port':'alongside',x+W/2+4,y+86,p.nAlongside?GREEN:FAINT);
    const rows=[...(p.arriving||[]), ...(p.alongside||[])].slice(0,4), chars=Math.floor(W/10.5)-8;
    rows.forEach((s,j)=>{ const ry=y+124+j*28, arr=s.st==='arriving';
      g.fillStyle=arr?CYAN:GREEN; g.beginPath(); g.arc(x+24,ry-5,4,0,7); g.fill();
      txt(clip(s.n,chars),x+36,ry,16,'#e5e9f0','left','600');
      txt(arr?(s.eta||kmh(s.s)+' km/h'):(s.l?s.l+' m':''),x+W-16,ry,14,arr?CYAN:DIM,'right'); });
    if(!rows.length) txt(d.connected?'nothing here right now':'…',x+18,y+140,15,FAINT);
  });
  txt('tap a place for its approach',24,272,12,FAINT,'left');
}
function detail(p,d){
  const port=p.kind==='port', arr=p.arriving||[], al=p.alongside||[];
  txt(clip(p.name,22),24,52,26,'#fff','left','700');
  txt(port?'sea port · ships of 200 m and up':'inland terminal · barges',24,78,14,DIM);
  stat(p.nArriving,'on the way',24,140,p.nArriving?CYAN:FAINT);
  stat(p.nAlongside,port?'in port':'alongside',24,196,p.nAlongside?GREEN:FAINT);
  txt('tap to go back',24,272,12,FAINT,'left');
  // The approach: berth on the right, the far end of the approach on the left, scaled to the furthest ship.
  const X0=360, X1=1250, Y=128, far=Math.max(5,...arr.map(s=>s.d))*1.12, step=far>40?10:far>16?5:far>8?2:1;
  g.strokeStyle='rgba(255,255,255,.18)'; g.lineWidth=4; g.beginPath(); g.moveTo(X0,Y); g.lineTo(X1,Y); g.stroke();
  for(let k=0;k<=far;k+=step){ const x=X1-k/far*(X1-X0); g.fillStyle='rgba(255,255,255,.25)'; g.fillRect(x-1,Y+6,2,8); txt(k+' km',x,Y+30,12,FAINT,'center'); }
  rr(X1-8,Y-20,16,40,4,GREEN); txt(port?'port':'berth',X1+16,Y+6,14,GREEN,'left','700');
  // Labels alternate above and below the line, two rows each, so neighbouring ships do not overwrite each other.
  arr.slice(0,8).forEach((s,i)=>{ const x=X1-s.d/far*(X1-X0), up=i%2===0, row=Math.floor(i/2)%2, ly=up?Y-24-row*40:Y+52+row*40;
    g.strokeStyle='rgba(56,189,248,.35)'; g.lineWidth=1; g.beginPath(); g.moveTo(x,Y); g.lineTo(x,up?ly+6:ly-16); g.stroke();
    g.fillStyle=CYAN; g.beginPath(); g.arc(x,Y,8,0,7); g.fill(); g.strokeStyle='#1c2029'; g.lineWidth=2; g.stroke();
    txt(clip(s.n,16),x,ly-14,15,'#fff','center','700');
    txt((s.eta?s.eta+' · ':'')+s.d+' km · '+kmh(s.s)+' km/h',x,ly+2,12,CYAN,'center'); });
  if(!arr.length) txt('nothing on its way in right now',X0,Y-24,16,FAINT);
  if(al.length){ txt((port?'In port: ':'Alongside: ')+clip(al.map(s=>s.n).join(', '),110),X0,252,14,GREEN,'left','600'); }
}
