const POLL=10000;
// Connection: a weather-style verdict on the left with the last minutes' latency, the path in the middle
// (Mac → Wi-Fi → router → provider → internet → services, a colour per hop, the culprit ringed) with the services
// below it, and the ASUS router on the right. From Deckhand (/connection/data.json), measured only while this page asks.
const LV={ok:'#22c55e',warn:'#f59e0b',bad:'#ef4444',unknown:'#475569'};
function ms(v){ return v==null?'—':v<10?v.toFixed(1)+' ms':Math.round(v)+' ms'; }
function wrap(s,x,y,size,col,max,lines){ const words=(s||'').split(' '); let line='', n=0; g.font='400 '+size+'px -apple-system,Roboto,sans-serif';
  for(const w of words){ const t=line?line+' '+w:w;
    if(g.measureText(t).width>max&&line){ if(n===lines-1){ txt(line+'…',x,y+n*(size+6),size,col); return; } txt(line,x,y+n*(size+6),size,col); n++; line=w; } else line=t; }
  if(line) txt(line,x,y+n*(size+6),size,col); }
function sky(kind,x,y){
  if(kind==='clear'){ g.fillStyle='#fbbf24'; g.beginPath(); g.arc(x,y,20,0,7); g.fill(); g.strokeStyle='#fbbf24'; g.lineWidth=3;
    for(let k=0;k<8;k++){ const a=k*Math.PI/4; g.beginPath(); g.moveTo(x+Math.cos(a)*27,y+Math.sin(a)*27); g.lineTo(x+Math.cos(a)*35,y+Math.sin(a)*35); g.stroke(); } return; }
  const col=kind==='stormy'?'#64748b':'#94a3b8';
  if(kind==='cloudy'){ g.fillStyle='#fbbf24'; g.beginPath(); g.arc(x+12,y-10,15,0,7); g.fill(); }
  g.fillStyle=col; g.beginPath(); g.arc(x-12,y+4,14,0,7); g.arc(x+4,y-6,18,0,7); g.arc(x+20,y+6,12,0,7); g.fill(); rr(x-26,y+4,58,16,8,col);
  if(kind==='stormy'){ g.fillStyle='#facc15'; g.beginPath(); g.moveTo(x+2,y+18); g.lineTo(x-8,y+36); g.lineTo(x+1,y+36); g.lineTo(x-5,y+52); g.lineTo(x+12,y+30); g.lineTo(x+3,y+30); g.lineTo(x+10,y+18); g.closePath(); g.fill(); }
}
function spark(xs,x0,y0,w,h,col,hi){ const pts=xs.map((v,i)=>[i,v]).filter(p=>p[1]!=null); if(pts.length<2) return; const X=i=>x0+i*w/Math.max(1,xs.length-1), Y=v=>y0+h-Math.min(1,v/hi)*h;
  g.strokeStyle=col; g.lineWidth=2; g.beginPath(); pts.forEach((p,k)=>k?g.lineTo(X(p[0]),Y(p[1])):g.moveTo(X(p[0]),Y(p[1]))); g.stroke(); }
function bar(x,y,w,pct,label){ txt(label,x,y,13,'#8b94a6'); rr(x+70,y-9,w,8,4,'rgba(255,255,255,.1)'); if(pct!=null){ rr(x+70,y-9,Math.max(3,w*Math.min(100,pct)/100),8,4,pct>85?'#ef4444':pct>65?'#f59e0b':'#22c55e'); txt(Math.round(pct)+'%',x+78+w,y,13,'#cbd5e1'); } }

function render(d){
  if(d.warming||!d.verdict){ txt('Measuring your connection…',712,150,20,'#8b94a6','center'); return; }
  const V=d.verdict, L=d.levels||{};
  // --- left: verdict and latency
  sky(V.sky,52,72);
  txt(V.headline,104,66,26,V.sky==='stormy'?'#f87171':V.sky==='cloudy'?'#fcd34d':'#fff','left','700');
  wrap(V.detail,104,92,14,'#cbd5e1',320,3);
  const H=d.history||{}, gw=H.gw||[], net=H.net||[];
  const hi=Math.max(20,...gw.filter(v=>v!=null),...net.filter(v=>v!=null))*1.15;
  g.fillStyle='rgba(255,255,255,.08)'; g.fillRect(20,252,400,1);
  spark(net,20,170,400,82,'#fb923c',hi); spark(gw,20,170,400,82,'#60a5fa',hi);
  txt('— router',20,272,12,'#60a5fa'); txt('— internet',90,272,12,'#fb923c'); txt('last 10 min · '+ms(hi/1.15)+' peak',420,272,12,'#6b7280','right');
  // --- middle: the path
  const M=446; g.fillStyle='rgba(255,255,255,.08)'; g.fillRect(M-14,16,1,248);
  const W=d.wifi, I=d.internet||{}, G=d.gateway||{}, P=d.isp||{};
  const svcMax=(d.services||[]).filter(s=>s.ms!=null).reduce((a,s)=>Math.max(a,s.ms),0);
  const nodes=[['Mac','ok',''],[d.wired?'Cable':'Wi-Fi',L.wifi,d.wired?'wired':W?W.rssi+' dBm':''],['Router',L.router,ms(G.avg)],['Provider',L.isp,ms(P.avg)],
               ['Internet',L.internet,ms(I.avg)+(I.loss>0?' · '+Math.round(I.loss*100)+'%':'')],['Services',L.services,svcMax?'≤ '+ms(svcMax):'']];
  const culprit={wifi:1,router:2,isp:3,service:5}[V.culprit];
  txt('THE PATH',M,32,14,'#8b94a6','left','600');
  nodes.forEach((n,i)=>{ const x=M+30+i*88, y=88;
    if(i){ g.strokeStyle=LV[n[1]]||LV.unknown; g.lineWidth=4; g.beginPath(); g.moveTo(x-88+20,y); g.lineTo(x-20,y); g.stroke(); }
    if(i===culprit){ g.strokeStyle=LV[n[1]]||'#fff'; g.lineWidth=3; g.beginPath(); g.arc(x,y,26,0,7); g.stroke(); }
    g.fillStyle=LV[n[1]]||LV.unknown; g.beginPath(); g.arc(x,y,17,0,7); g.fill();
    txt(n[0],x,y+42,14,'#e5e7eb','center','600'); if(n[2]) txt(n[2],x,y+60,12,'#8b94a6','center'); });
  (d.services||[]).slice(0,6).forEach((s,i)=>{ const x=M+(i%3)*160, y=200+Math.floor(i/3)*30;
    g.fillStyle=LV[s.level]; g.beginPath(); g.arc(x+5,y-5,5,0,7); g.fill(); txt(s.name.replace('Microsoft 365','Microsoft'),x+16,y,14,'#cbd5e1'); txt(s.ms==null?'no answer':ms(s.ms),x+152,y,13,s.ms==null?'#f87171':'#8b94a6','right'); });
  // --- right: the router (or the Wi-Fi when there is no router login)
  const R=968; g.fillStyle='rgba(255,255,255,.08)'; g.fillRect(R-14,16,1,248);
  const r=d.router;
  if(r){
    txt((r.model||'ROUTER').replace(/_/g,' ').toUpperCase(),R,32,14,'#8b94a6','left','600');
    txt(r.wanUp===false?'Internet down':'Internet up',R+436,32,14,r.wanUp===false?'#f87171':'#4ade80','right','600');
    txt((r.wired+r.wireless)+' devices',R,70,24,'#fff','left','700'); txt(r.wireless+' on Wi-Fi · '+r.wired+' wired',R+150,70,14,'#8b94a6');
    bar(R,102,250,r.cpu,'CPU'); bar(R,124,250,r.memory,'Memory');
    (r.nodes||[]).slice(0,3).forEach((n,i)=>{ const y=158+i*30; g.fillStyle=n.online?'#22c55e':'#ef4444'; g.beginPath(); g.arc(R+6,y-5,6,0,7); g.fill();
      txt(clip(n.name,24),R+20,y,16,'#e5e7eb'); txt(n.online?(n.clients?n.clients+' devices':'online'):'offline',R+436,y,13,n.online?'#8b94a6':'#f87171','right'); });
    if(r.firmware) txt('Firmware '+r.firmware,R,262,12,'#6b7280');
  } else {
    txt(d.wired?'CABLE':'WI-FI',R,32,14,'#8b94a6','left','600');
    if(W){ txt(W.rssi+' dBm',R,72,28,LV[W.level]||'#fff','left','700'); txt('signal · '+W.snr+' dB above noise',R+120,72,14,'#8b94a6');
      txt((W.band?W.band+' · ':'')+(W.channel?'channel '+W.channel+' · ':'')+Math.round(W.rate)+' Mbit/s',R,104,15,'#cbd5e1'); }
    else txt(d.wired?'Connected by cable.':'No Wi-Fi reading.',R,72,16,'#8b94a6');
    if(d.routerError) wrap(d.routerError,R,170,14,'#f59e0b',436,3);
    else if(!d.routerLogin) wrap('Add your ASUS router login under Apps → Connection for the mesh nodes and connected devices.',R,170,14,'#8b94a6',436,3);
  }
}
let lastD=null;
function frame(){ if(D&&D!==lastD){ lastD=D; bg(); render(D); } setTimeout(frame,500); }
