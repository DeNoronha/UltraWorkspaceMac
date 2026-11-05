const POLL=5000;
// Radar on the left (one card wide, a dark map underneath), up to four flights beside it, each in its own
// colour that also marks its plane and flight number on the radar.
const COLS=['#4ade80','#fbbf24','#60a5fa','#f472b6'];
const tiles={};
// A tile that failed (OSM unreachable, Mac busy) is dropped from the cache after 30 s so it is asked for again,
// instead of staying a blank hole until the page is reopened.
function tile(z,x,y){ const k=z+'/'+x+'/'+y; if(tiles[k]) return tiles[k]; const im=new Image(); im.onerror=()=>setTimeout(()=>{ if(tiles[k]===im) delete tiles[k]; },30000); im.src='/flights/tile/'+z+'/'+x+'/'+y+'.png'; tiles[k]=im; return im; }
// OpenStreetMap road tiles, toned down and cached by the Mac (see MapTiles.swift), scaled so the circle is exactly R km across.
function map(cx,cy,r,lat,lon,R){ if(lat==null||lon==null) return false;
  const mpp=R*1000/r, zf=Math.log2(156543.03*Math.cos(lat*Math.PI/180)/mpp), z=Math.max(2,Math.min(17,Math.floor(zf))), s=Math.pow(2,zf-z), n=Math.pow(2,z);
  const wx=(lon+180)/360*n*256, lr=lat*Math.PI/180, wy=(1-Math.log(Math.tan(lr)+1/Math.cos(lr))/Math.PI)/2*n*256;
  let drew=false; g.save(); g.beginPath(); g.arc(cx,cy,r,0,7); g.clip(); g.globalAlpha=0.9;
  const x0=Math.floor((wx-r/s)/256), x1=Math.floor((wx+r/s)/256), y0=Math.floor((wy-r/s)/256), y1=Math.floor((wy+r/s)/256);
  for(let tx=x0;tx<=x1;tx++) for(let ty=y0;ty<=y1;ty++){ const im=tile(z,tx,ty); if(im.complete&&im.naturalWidth){ g.drawImage(im,cx+(tx*256-wx)*s,cy+(ty*256-wy)*s,256*s+0.5,256*s+0.5); drew=true; } }
  g.restore(); return drew; }
function plane(x,y,r,heading,col){ g.save(); g.translate(x,y); g.rotate((heading||0)*Math.PI/180); g.fillStyle=col; g.beginPath();
  g.moveTo(0,-r); g.lineTo(r*.35,r*.25); g.lineTo(r*.12,r*.15); g.lineTo(r*.12,r*.6); g.lineTo(r*.3,r*.8); g.lineTo(0,r*.65); g.lineTo(-r*.3,r*.8); g.lineTo(-r*.12,r*.6); g.lineTo(-r*.12,r*.15); g.lineTo(-r*.35,r*.25); g.closePath(); g.fill(); g.strokeStyle='rgba(0,0,0,.55)'; g.lineWidth=1.2; g.stroke(); g.restore(); }
function render(d){
  const R=d.radius||3, ac=d.aircraft||[], inside=ac.filter(a=>a.inside), show=(inside.length?inside:ac.slice(0,1)).slice(0,4);
  // radar: 250 px circle, full height
  const cx=140,cy=140,rr0=122;
  g.fillStyle='#141821'; g.beginPath(); g.arc(cx,cy,rr0,0,7); g.fill();
  const hasMap=map(cx,cy,rr0,d.lat,d.lon,R);
  g.strokeStyle=hasMap?'rgba(0,0,0,.28)':'rgba(255,255,255,.14)'; g.lineWidth=1.5;
  [1/3,2/3,1].forEach(f=>{ g.beginPath(); g.arc(cx,cy,rr0*f,0,7); g.stroke(); });
  g.beginPath(); g.moveTo(cx-rr0,cy); g.lineTo(cx+rr0,cy); g.moveTo(cx,cy-rr0); g.lineTo(cx,cy+rr0); g.stroke();
  const sweep=(Date.now()/4000*Math.PI*2)%(Math.PI*2);
  g.save(); g.beginPath(); g.moveTo(cx,cy); g.arc(cx,cy,rr0,sweep-0.9,sweep); g.closePath(); g.fillStyle='rgba(74,222,128,.12)'; g.fill(); g.restore();
  g.fillStyle=hasMap?'#1d4ed8':'#fff'; g.beginPath(); g.arc(cx,cy,4,0,7); g.fill();
  const ink=hasMap?'#1f2937':'#c7cdd8', ink2=hasMap?'#374151':'#9aa3b2';
  txt('N',cx,cy-rr0+16,12,ink,'center','600'); txt(R+' km',cx+rr0-6,cy-6,11,ink2,'right');
  if(hasMap) txt('© OpenStreetMap',cx,cy+rr0-6,9,'rgba(0,0,0,.55)','center');
  if(d.at){ const age=Math.max(0,Math.round(Date.now()/1000-d.at)); txt(age<15?'live':ago(age)+' old',cx-rr0+8,cy-6,11,age<30?'#4ade80':'#fbbf24','left','600'); }
  // every aircraft in the circle: the shown ones in their colour with the flight number, the rest grey
  ac.forEach(a=>{ if(a.km>R) return; const i=show.indexOf(a), col=i>=0?COLS[i]:'#8b94a6';
    const rad=a.bearing*Math.PI/180, dd=Math.min(1,a.km/R)*rr0, px=cx+Math.sin(rad)*dd, py=cy-Math.cos(rad)*dd;
    plane(px,py,i>=0?13:9,a.track,col);
    if(i>=0){ const lab=a.callsign||a.reg||''; if(lab){ g.save(); g.shadowColor='rgba(0,0,0,.9)'; g.shadowBlur=4; txt(lab,px+(px<cx?-12:12),py+5,12,col,px<cx?'right':'left','700'); g.restore(); } } });
  // panels
  const X0=296, GAP=12, N=4, W=Math.floor((1424-X0-20-(N-1)*GAP)/N), y=16, H=248;
  if(!show.length){ txt('Nothing within '+R+' km',X0+10,120,34,'#9aa3b2','left','700');
    txt(ac.length? ac.length+' aircraft within 25 km, nearest '+ac[0].km+' km '+ac[0].dir:'Clear skies for 25 km around.',X0+10,160,18,'#6b7280');
    txt(d.place||'',X0+10,200,15,'#6b7280'); return; }
  show.forEach((a,i)=>{ const x=X0+i*(W+GAP), col=COLS[i]; rr(x,y,W,H,14, a.inside?'rgba(255,255,255,.07)':'rgba(255,255,255,.04)');
    g.fillStyle=col; g.fillRect(x,y+18,5,H-36);
    txt(a.callsign||a.reg||'—',x+18,y+40,30,col,'left','700'); plane(x+W-30,y+30,15,a.track,col);
    txt(clip(a.airline||(a.type||'')+(a.reg?' · '+a.reg:''),30),x+18,y+64,14,'#b4bccb');
    if(a.from||a.to){ const f=a.from?a.from.iata:'?', t=a.to?a.to.iata:'?'; txt(f+' → '+t,x+18,y+104,26,'#fff','left','700');
      txt(clip((a.from?a.from.city||a.from.name:'?')+' → '+(a.to?a.to.city||a.to.name:'?'),34),x+18,y+128,13,'#8b94a6'); }
    else txt('route unknown',x+18,y+104,18,'#6b7280');
    const alt=a.ground?'on the ground':(a.alt!=null? Math.max(0,a.alt).toLocaleString()+' m':'—'), vs=a.vs==null?'':(a.vs>1?' ↑':a.vs<-1?' ↓':' →');
    txt(alt+vs+(a.speed!=null?'  ·  '+a.speed+' km/h':''),x+18,y+168,16,'#d6dbe6');
    if(a.airline) txt((a.type||'')+(a.reg?'  ·  '+a.reg:''),x+18,y+192,13,'#8b94a6');
    txt(a.km+' km '+a.dir+(a.inside?'':'  ·  outside the circle'),x+18,y+H-16,14,a.inside?col:'#6b7280','left','600');
  });
  if(inside.length>4) txt('+'+(inside.length-4)+' more',1424-24,y+H-16,13,'#6b7280','right');
}
