const POLL=20000;
// Climate: the house on the left (inside from the Netatmo station, the heating from tado, outside), the heating's
// controls in the middle (tap a temperature to heat for the chosen time or until the schedule), the last 24 hours on
// the right. Everything comes from Deckhand (/climate/data.json); taps POST /climate/heat/<°C>/<min|next>, /climate/schedule.
const TEMPS=[19,20,21,22], DURS=[['60','1 h'],['120','2 h'],['240','4 h'],['next','Until schedule']];
let dur='120', sent=null, hits=[];
function hm(t){ const d=new Date(t*1000); return String(d.getHours()).padStart(2,'0')+':'+String(d.getMinutes()).padStart(2,'0'); }
function deg(v,dec){ return v==null?'—':v.toFixed(dec==null?1:dec).replace('.',',')+'°'; }
function whole(v){ return v==null?'—':(Math.round(v*2)/2).toString().replace('.',',')+'°'; }
function trend(t){ return t==='up'?' ↑':t==='down'?' ↓':''; }
const CO2C={good:'#4ade80',stuffy:'#f59e0b',bad:'#f87171'};
function button(x,y,w,h,label,on,size,hit){
  rr(x,y,w,h,14,on?'#f97316':'rgba(255,255,255,.09)'); txt(label,x+w/2,y+h/2+size*0.36,size,on?'#fff':'#e5e7eb','center','700');
  if(hit) hits.push(Object.assign({x,y,w,h},hit));
}
function chartLine(xs,x0,y0,w,h,lo,hi,col){
  if(!xs||xs.length<2) return; const X=i=>x0+i*w/(xs.length-1), Y=v=>y0+(hi-v)/((hi-lo)||1)*h;
  g.strokeStyle=col; g.lineWidth=2.4; g.lineJoin='round'; g.beginPath(); xs.forEach((v,i)=>i?g.lineTo(X(i),Y(v)):g.moveTo(X(i),Y(v))); g.stroke();
}

function render(d){
  hits=[]; const T=d.tado||{}, N=d.netatmo||{}, H=T.heating, mods=N.modules||[];
  // Rooms: the station, its indoor modules, then outside (rain and wind gauges have no temperature tile).
  const rooms=mods.filter(m=>m.kind==='indoor').concat(mods.filter(m=>m.kind==='extra')).slice(0,3).concat(mods.filter(m=>m.kind==='outdoor').slice(0,1));
  // --- left: the heating, then a tile per room
  txt('CLIMATE'+(N.station?' · '+N.station.toUpperCase():T.home?' · '+T.home.toUpperCase():''),20,32,14,'#8b94a6','left','600');
  const fresh=!T.connected&&!N.connected;
  if(fresh){ txt('Your heating and weather station',20,90,24,'#fff','left','700'); txt('Connect tado and Netatmo under',20,124,15,'#8b94a6'); txt('Apps → Climate in Deckhand.',20,146,15,'#8b94a6'); }
  let line='', col='#8b94a6', sub='';
  if(fresh) line='';
  else if(!T.connected) line='tado not connected';
  else if(!H) line=T.error?clip(T.error,40):'Reading tado…';
  else {
    if(!H.online){ line='tado is offline'; col='#f87171'; }
    else if(H.away){ line='Away'+(H.on&&H.target!=null?' · '+whole(H.target):' · heating off'); }
    else if(H.manual&&H.on){ line='Heating to '+whole(H.target)+(H.untilSchedule?' until schedule':H.ends?' until '+hm(H.ends):''); col='#fb923c'; }
    else if(H.manual){ line='Heating off'+(H.ends?' until '+hm(H.ends):''); }
    else if(H.on){ line='Schedule · '+whole(H.target); col='#fdba74'; }
    else line='Heating off · schedule';
    if(H.openWindow){ sub='Open window: heating paused'; }
    else if(H.nextAt&&!(H.manual&&!H.untilSchedule)) sub=(H.nextOn?'Heats to '+whole(H.nextTarget):'Off')+' at '+hm(H.nextAt);
    if(H.inside!=null) sub=(sub?sub+' · ':'')+'thermostat '+deg(H.inside);
    if(H.on&&H.power!=null) sub=(sub?sub+' · ':'')+'boiler '+H.power+'%';
  }
  if(line){ if(col==='#fb923c'||col==='#fdba74'){ g.fillStyle=col; g.beginPath(); g.arc(28,66,7,0,7); g.fill(); txt(clip(line,30),44,74,24,col,'left','700'); }
    else txt(clip(line,32),20,74,24,col==='#8b94a6'?'#e5e7eb':col,'left','700'); }
  if(sub) txt(clip(sub,54),20,100,14,'#8b94a6');
  rooms.forEach((m,i)=>{ const x=20+i*102, y=118, out=m.kind==='outdoor';
    rr(x,y,96,146,12,out?'rgba(96,165,250,.10)':'rgba(255,255,255,.06)');
    txt(clip(m.name,12),x+10,y+24,13,'#8b94a6','left','600');
    txt(m.reachable===false?'—':deg(m.t),x+10,y+64,28,out?'#93c5fd':'#fff','left','700');
    if(out){ if(m.min!=null&&m.max!=null) txt(deg(m.min,0)+' / '+deg(m.max,0)+trend(m.trend),x+10,y+92,13,'#cbd5e1'); }
    else if(m.co2!=null) txt('CO₂ '+m.co2,x+10,y+92,13,CO2C[m.co2Level]||'#cbd5e1','left','600');
    if(m.h!=null) txt(Math.round(m.h)+'% hum.',x+10,y+114,12,'#8b94a6');
    if(m.reachable===false) txt('no signal',x+10,y+134,11,'#f59e0b'); else if(m.battery!=null&&m.battery<20) txt('battery '+m.battery+'%',x+10,y+134,11,'#f59e0b');
  });
  if(!fresh&&!N.connected) txt(N.hasClient?'Connect Netatmo under Apps → Climate.':'Netatmo not connected',20,160,14,'#8b94a6');


  // --- middle: the heating's controls
  const M=450; g.fillStyle='rgba(255,255,255,.08)'; g.fillRect(M-16,16,1,248);
  if(!T.connected){ txt('Connect tado under Apps → Climate',M+215,132,18,'#8b94a6','center'); txt('in Deckhand to set the heating from here.',M+215,158,16,'#8b94a6','center'); }
  else {
    txt('HEAT THE HOUSE',M,32,14,'#8b94a6','left','600');
    const busy=T.pending||(sent&&Date.now()-sent.at<4000);
    TEMPS.forEach((t,i)=>button(M+i*106,46,96,74,t+'°',H&&H.manual&&H.on&&H.target===t,30,busy?null:{temp:t}));
    DURS.forEach((q,i)=>{ const w=i===3?150:82, bx=M+[0,90,180,270][i]; rr(bx,136,w,36,18,dur===q[0]?'rgba(255,255,255,.18)':'rgba(255,255,255,.05)');
      txt(q[1],bx+w/2,160,15,dur===q[0]?'#fff':'#8b94a6','center','600'); hits.push({x:bx,y:132,w,h:44,dur:q[0]}); });
    if(busy) txt(T.pending==='schedule'||(sent&&sent.label==='schedule')?'Back to the schedule…':'Setting '+(T.pending||sent.label)+'…',M,218,17,'#fdba74','left','600');
    else if(H&&H.manual) button(M,190,200,52,'Back to schedule',false,17,{schedule:true});
    else txt('Tap a temperature to heat the house.',M,218,15,'#8b94a6');
    if(T.error&&H) txt(clip(T.error,54),M,262,13,'#f59e0b');
    else if(T.callsLeft!=null) txt(T.callsLeft+' tado calls left today',M+414,262,12,T.callsLeft<10?'#f59e0b':'#6b7280','right');
  }

  // --- right: the last 24 hours
  const R=910, W=494; g.fillStyle='rgba(255,255,255,.08)'; g.fillRect(R-16,16,1,248);
  txt('LAST 24 HOURS',R,32,14,'#8b94a6','left','600');
  const C=N.chart;
  if(C&&(C.indoor||C.outdoor)){
    const all=[].concat(C.indoor||[],C.outdoor||[]), lo=Math.floor(Math.min(...all)-1), hi=Math.ceil(Math.max(...all)+1);
    const y0=52, h=170;
    g.strokeStyle='rgba(255,255,255,.08)'; g.lineWidth=1; for(let k=0;k<=2;k++){ const y=y0+k*h/2; g.beginPath(); g.moveTo(R,y); g.lineTo(R+W-40,y); g.stroke();
      txt(deg(hi-(hi-lo)*k/2,0),R+W,y+5,12,'#6b7280','right'); }
    chartLine(C.outdoor,R,y0,W-48,h,lo,hi,'#60a5fa'); chartLine(C.indoor,R,y0,W-48,h,lo,hi,'#fb923c');
    const nm=(mods.find(m=>m.kind==='indoor')||{}).name||'inside'; txt('— '+clip(nm,14),R,250,13,'#fb923c'); g.font='400 13px -apple-system,Roboto,sans-serif'; const lw=g.measureText('— '+clip(nm,14)).width+16; txt('— outside',R+lw,250,13,'#60a5fa');
    const from=(C.from&&C.from[0])||0; if(from){ txt(hm(from),R,268,12,'#6b7280'); txt('now',R+W-48,268,12,'#6b7280','right'); }
  } else txt(N.connected?(N.error?clip(N.error,52):'Reading the station…'):'Connect Netatmo under Apps → Climate.',R,140,16,'#8b94a6');
}

c.addEventListener('click',ev=>{
  const r=c.getBoundingClientRect(), x=(ev.clientX-r.left)*1424/r.width, y=(ev.clientY-r.top)*280/r.height;
  const h=hits.find(o=>x>=o.x&&x<o.x+o.w&&y>=o.y&&y<o.y+o.h); if(!h) return;
  if(h.dur){ dur=h.dur; return; }
  if(h.temp){ sent={label:h.temp+'°',at:Date.now()}; act('/climate/heat/'+h.temp+'/'+dur).then(()=>setTimeout(poll,1500)); return; }
  if(h.schedule){ sent={label:'schedule',at:Date.now()}; act('/climate/schedule').then(()=>setTimeout(poll,2500)); }
});
// Redraw on new data or a tap, else every 2 s for the "Setting…" line; never 60 times a second.
let lastD=null, lastDraw=0, dirty=false; const STEP=250;
c.addEventListener('click',()=>{ dirty=true; });
function frame(){ const t=Date.now(); if(D&&(D!==lastD||dirty||t-lastDraw>=2000)){ lastD=D; dirty=false; lastDraw=t; bg(); render(D); } setTimeout(frame,STEP); }
