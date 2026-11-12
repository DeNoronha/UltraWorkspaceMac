const POLL=10000;
// The owner's Zeekr: the car (their own picture from Deckhand's private folder, else a drawn one) with where it is,
// charge and range, the charging state, lock and climate, and the tyres. Tap for the charge curve Deckhand recorded
// and the doors and tyres; tap again (or wait 90 s) to go back. Read-only: nothing here changes the car.
const CYAN='#38bdf8', GREEN='#4ade80', AMBER='#fbbf24', RED='#f87171', DIM='#8b94a6', FAINT='#4b5363', TEXT='#e5e9f0';
let detailOn=false, detailAt=0, picKey=null, pic=null;
c.addEventListener('click',()=>{ detailOn=!detailOn; detailAt=Date.now(); });
function font(size,weight){ g.font=(weight||'400')+' '+size+'px -apple-system,Roboto,Helvetica,Arial,sans-serif'; }
function width(s,size,weight){ font(size,weight); return g.measureText(s).width; }
function line(x1,y1,x2,y2,col,w){ g.strokeStyle=col; g.lineWidth=w||1; g.beginPath(); g.moveTo(x1,y1); g.lineTo(x2,y2); g.stroke(); }
function socColor(s,charging){ return charging?CYAN : s<20?RED : s<35?AMBER : GREEN; }
const OPEN={driver:'driver door',passenger:'passenger door',rearLeft:'rear left door',rearRight:'rear right door',trunk:'trunk',hood:'bonnet',chargeLid:'charge flap',
  windowDriver:'driver window',windowPassenger:'passenger window',windowRearLeft:'rear left window',windowRearRight:'rear right window',sunroof:'sunroof'};
function openText(o){ return o.length? (o.length>2? o.length+' things open' : o.map(k=>OPEN[k]||k).join(', ')+' open') : 'all closed'; }

function render(d){
  if(detailOn&&Date.now()-detailAt>90000) detailOn=false;
  if(d.pic&&d.picKey!==picKey){ picKey=d.picKey; const i=new Image(); i.onload=()=>{pic=i}; i.onerror=()=>{pic=null}; i.src='/zeekr/car/'+d.pic+'.png?k='+encodeURIComponent(picKey); }
  if(!d.pic){ pic=null; picKey=null; }
  if(!d.hasAuth){ carPicture(24,40,330,170); txt('Connect your Zeekr in Deckhand',400,130,32,'#9aa3b2','left','700'); txt('Apps → Zeekr. The sign-in stays on the Mac; this page only reads the car.',400,172,19,'#6b7280'); return; }
  if(!d.car){ carPicture(24,40,330,170); txt(d.error?clip(d.error,70):'Asking Zeekr…',400,150,26,d.error?RED:DIM,'left','600'); return; }
  if(detailOn) detail(d); else overview(d);
}

// The car itself: the owner's picture fitted into the box, or a plain drawn side view.
function carPicture(x,y,w,h){
  if(pic){ const k=Math.min(w/pic.width,h/pic.height), pw=pic.width*k, ph=pic.height*k; g.drawImage(pic,x+(w-pw)/2,y+(h-ph)/2,pw,ph); return; }
  const s=Math.min(w/300,h/120), cx=x+w/2, by=y+h/2+30*s;   // drawn car: 300 × 120 units
  const X=u=>cx+(u-150)*s, Y=v=>by+(v-80)*s;
  g.fillStyle='#d6dbe4'; g.beginPath(); g.moveTo(X(8),Y(80)); g.lineTo(X(10),Y(52)); g.quadraticCurveTo(X(14),Y(40),X(40),Y(36)); g.lineTo(X(88),Y(30));
  g.quadraticCurveTo(X(120),Y(4),X(168),Y(2)); g.lineTo(X(214),Y(4)); g.quadraticCurveTo(X(258),Y(10),X(282),Y(36)); g.quadraticCurveTo(X(294),Y(48),X(292),Y(80)); g.closePath(); g.fill();
  g.fillStyle='#3a4352'; g.beginPath(); g.moveTo(X(100),Y(32)); g.quadraticCurveTo(X(126),Y(12),X(166),Y(10)); g.lineTo(X(208),Y(11)); g.quadraticCurveTo(X(240),Y(16),X(258),Y(34)); g.closePath(); g.fill();
  g.fillStyle='#d6dbe4'; g.fillRect(X(172),Y(10),4*s,24*s);
  g.fillStyle='#9aa3b2'; g.fillRect(X(16),Y(56),266*s,3*s);
  for(const u of [66,232]){ g.fillStyle='#1c2029'; g.beginPath(); g.arc(X(u),Y(80),27*s,0,7); g.fill(); g.fillStyle='#2b313c'; g.beginPath(); g.arc(X(u),Y(80),22*s,0,7); g.fill(); g.fillStyle='#8b94a6'; g.beginPath(); g.arc(X(u),Y(80),10*s,0,7); g.fill(); }
}

// Top view: body, doors, trunk and bonnet (amber when open), the tyres with their pressure in bar.
function carTop(cx,cy,h,car,labels){
  const w=h*0.44, x=cx-w/2, y=cy-h/2, o=car.open||[], open=k=>o.includes(k), tw=h*0.07, th=h*0.17;
  const tyres=car.tyres||[], warn=car.tyreWarn||[];
  [[x-tw*0.6,y+h*0.16],[x+w-tw*0.4,y+h*0.16],[x-tw*0.6,y+h*0.68],[x+w-tw*0.4,y+h*0.68]].forEach(([tx,ty],i)=>{
    rr(tx,ty,tw,th,3,warn[i]?AMBER:'#5b6476');
    if(labels){ const t=tyres[i]==null?'–':tyres[i], left=i%2===0; txt(t,left?tx-10:tx+tw+10,ty+th/2+7,labels,warn[i]?AMBER:TEXT,left?'right':'left','700'); } });
  rr(x,y,w,h,w*0.28,'#3a4352');
  rr(x+w*0.12,y+h*0.24,w*0.76,h*0.2,6,'#252b36');           // windscreen
  rr(x+w*0.14,y+h*0.74,w*0.72,h*0.1,5,'#252b36');           // rear window
  rr(x+w*0.16,y+h*0.47,w*0.68,h*0.24,5,open('sunroof')?AMBER:'#2b313c');
  g.lineWidth=Math.max(3,h*0.025); g.lineCap='round';
  const side=(k,sx,y1,y2,out)=>line(open(k)?sx+out:sx,y1,sx,y2,open(k)?AMBER:'#6b7486',g.lineWidth);
  side('driver',x+1,y+h*0.30,y+h*0.50,-h*0.09); side('rearLeft',x+1,y+h*0.52,y+h*0.72,-h*0.09);
  side('passenger',x+w-1,y+h*0.30,y+h*0.50,h*0.09); side('rearRight',x+w-1,y+h*0.52,y+h*0.72,h*0.09);
  if(open('hood')) rr(x+w*0.1,y-h*0.04,w*0.8,h*0.12,6,AMBER);
  if(open('trunk')) rr(x+w*0.1,y+h*0.93,w*0.8,h*0.12,6,AMBER);
  if(open('chargeLid')){ g.fillStyle=CYAN; g.beginPath(); g.arc(x+w-2,y+h*0.82,Math.max(4,h*0.03),0,7); g.fill(); }
  g.lineCap='butt';
}

function lockIcon(x,y,locked,col){ g.strokeStyle=col; g.lineWidth=3; g.beginPath(); g.arc(x+9,y-14,6,Math.PI,locked?0:-0.5); g.stroke(); rr(x,y-14,18,15,3,col); }

function overview(d){
  const car=d.car, soc=car.soc, charging=car.charging;
  // the car and where it is
  carPicture(16,14,340,186);
  if(car.place){ if(car.home){ g.fillStyle=GREEN; g.beginPath(); g.moveTo(28,224); g.lineTo(37,216); g.lineTo(46,224); g.lineTo(46,234); g.lineTo(28,234); g.closePath(); g.fill(); }
    else { g.fillStyle=TEXT; g.beginPath(); g.arc(37,222,7,Math.PI,0); g.lineTo(37,236); g.closePath(); g.fill(); g.fillStyle='#1c2029'; g.beginPath(); g.arc(37,222,2.5,0,7); g.fill(); }
    txt(clip(car.place,30),56,234,20,car.home?GREEN:TEXT,'left','700'); }
  const status=d.signIn?'sign-in expired: connect again in Apps → Zeekr':d.error?clip(d.error,44):car.ago!=null?'updated '+ago(car.ago)+' ago':'';
  txt(status,28,262,14,d.signIn||d.error?RED:FAINT);
  // charge and range
  const X=388;
  if(soc!=null){ const s=String(soc); txt(s,X,116,96,'#fff','left','700'); txt('%',X+width(s,96,'700')+2,116,40,DIM,'left','700'); }
  else txt('–',X,116,96,DIM,'left','700');
  const bw=260, by=138; rr(X,by,bw,20,10,'rgba(255,255,255,.10)');
  if(soc!=null) rr(X,by,Math.max(20,bw*soc/100),20,10,socColor(soc,charging));
  if(car.target){ const tx=X+bw*car.target/100; line(tx,by-6,tx,by+26,'#fff',2); }
  if(car.range!=null){ txt(car.range+' km',X,206,34,'#fff','left','700'); }
  txt('range'+(car.target?' · charge limit '+car.target+'%':''),X,234,15,DIM);
  // charging
  const C=690, st=car.charge, plug=car.plug?' · '+car.plug:'';
  const title={charging:'Charging'+plug,complete:'Charge complete',paused:'Charging paused'+plug,error:'Charging error',plugged:'Plugged in'+plug,unplugged:'Not plugged in'}[st]||'';
  const tcol={charging:CYAN,complete:GREEN,paused:AMBER,error:RED,plugged:TEXT,unplugged:DIM}[st]||DIM;
  txt(title,C,50,22,tcol,'left','700');
  if(charging){
    if(car.kW){ txt(car.kW,C,112,56,CYAN,'left','700'); txt('kW',C+width(car.kW,56,'700')+8,112,22,DIM,'left','700'); }
    if(car.mins!=null) txt((car.target?car.target+'% ':'full ')+'at '+car.fullAt+' · '+(car.mins<60?car.mins+' min':Math.floor(car.mins/60)+' h '+String(car.mins%60).padStart(2,'0')),C,car.kW?146:96,19,TEXT,'left','600');
  } else if(d.session&&!d.session.live){ const p=d.session.points, a=p[0][1], b=p[p.length-1][1];
    txt('last charge '+d.session.day,C,90,17,DIM); txt(Math.round(a)+'% → '+Math.round(b)+'%'+(d.session.dc?' · DC':''),C,116,19,TEXT,'left','600'); }
  // lock and climate
  const locked=car.locked, o=car.open||[];
  lockIcon(C,206,locked!==false,locked===false?AMBER:GREEN);
  txt((locked===false?'Unlocked':locked?'Locked':'Lock unknown')+(o.length?' · '+openText(o):''),C+30,206,19,locked===false||o.length?AMBER:TEXT,'left','600');
  g.strokeStyle=car.climate?CYAN:DIM; g.lineWidth=2.5; for(let k=0;k<3;k++){ const a=k*2.094; g.beginPath(); g.ellipse(C+9+Math.cos(a)*5,236+Math.sin(a)*5,6,3,a,0,7); g.stroke(); }
  txt((car.climate?'Climate on':'Climate off')+(car.temp!=null?' · '+car.temp+'° inside':''),C+30,242,19,car.climate?CYAN:TEXT,'left','600');
  // tyres and odometer
  const T=1170;
  txt('TYRES · BAR',T,30,12,FAINT,'center','700');
  carTop(T,124,150,car,17);
  if(car.odo) txt(car.odo+' km',T,240,19,TEXT,'center','600');
  txt('tap for charge curve and doors',1316,272,12,FAINT,'right');
}

function detail(d){
  const car=d.car, s=d.session;
  // charge curve, as Deckhand recorded it while the car charged (Zeekr keeps no history of it)
  const L=78, R=760, T=64, B=226;
  if(!s){ txt('Charge curve',24,40,22,'#fff','left','700'); txt('Nothing recorded yet: Deckhand draws the curve while the car charges with Zeekr on the bar.',24,140,18,DIM); }
  else {
    txt(s.live?'Charging now':'Last charge',24,40,22,'#fff','left','700');
    txt(s.day+' · '+s.from+(s.to?'–'+s.to:'')+(s.dc?' · DC':''),24+width(s.live?'Charging now':'Last charge',22,'700')+14,40,16,DIM);
    const p=s.points, tMax=Math.max(10,p[p.length-1][0]), kMax=Math.max(50,Math.ceil(Math.max(...p.map(q=>q[2]))/50)*50), hasKW=p.some(q=>q[2]>0);
    const X=t=>L+t/tMax*(R-L), Ys=v=>B-v/100*(B-T), Yk=v=>B-v/kMax*(B-T);
    for(const v of [0,25,50,75,100]){ line(L,Ys(v),R,Ys(v),'rgba(255,255,255,.07)'); txt(v+'%',L-10,Ys(v)+5,12,GREEN,'right'); }
    if(hasKW) for(const v of [0,kMax/2,kMax]) txt(Math.round(v)+'',R+10,Yk(v)+5,12,CYAN,'left');
    const step=tMax>120?30:tMax>40?10:5; for(let t=0;t<=tMax;t+=step) txt(t+' min',X(t),B+20,12,FAINT,'center');
    if(hasKW){ g.fillStyle='rgba(56,189,248,.22)'; g.beginPath(); g.moveTo(X(p[0][0]),B); p.forEach(q=>g.lineTo(X(q[0]),Yk(q[2]))); g.lineTo(X(p[p.length-1][0]),B); g.closePath(); g.fill();
      g.strokeStyle=CYAN; g.lineWidth=2; g.beginPath(); p.forEach((q,i)=>i?g.lineTo(X(q[0]),Yk(q[2])):g.moveTo(X(q[0]),Yk(q[2]))); g.stroke(); txt('kW',R+10,T-12,12,CYAN,'left','700'); }
    g.strokeStyle=GREEN; g.lineWidth=3; g.beginPath(); p.forEach((q,i)=>i?g.lineTo(X(q[0]),Ys(q[1])):g.moveTo(X(q[0]),Ys(q[1]))); g.stroke();
    const last=p[p.length-1]; g.fillStyle=GREEN; g.beginPath(); g.arc(X(last[0]),Ys(last[1]),5,0,7); g.fill();
    txt(Math.round(p[0][1])+'% → '+Math.round(last[1])+'%'+(hasKW?' · peak '+Math.round(Math.max(...p.map(q=>q[2])))+' kW':''),R,40,16,TEXT,'right','600');
  }
  // doors, windows and tyres
  const o=car.open||[], locked=car.locked;
  txt(locked===false?'Unlocked':locked?'Locked':'Lock unknown',880,40,22,locked===false?AMBER:'#fff','left','700');
  txt(openText(o),880,64,16,o.length?AMBER:DIM);
  carTop(1100,160,170,car,18);
  const tw=car.tyreWarn||[]; if(tw.some(Boolean)) txt('check tyre pressure',1100,272,13,AMBER,'center','600');
  txt('tap to go back',24,272,12,FAINT,'left');
}
