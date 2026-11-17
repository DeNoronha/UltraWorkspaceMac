const POLL=20000;
// Walk: on the left where the day stands (out walking, time for a walk, after this meeting, when the next one is) with
// Going now / Back home; in the middle today's active hours with the meetings (only that you are busy), the walks,
// the best moment and the rain; on the right this week's walks. Taps send start, back, done or undo; the Mac keeps
// the log.
const GREEN='#4ade80', RED='#f87171', AMBER='#fbbf24', GREY='#8b94a6', DIM='#5b6475', BLUE='#60a5fa', WALK='#22c55e';
const DAYS=['','S','M','T','W','T','F','S'];
let hits=[], toast=null, toastUntil=0, lastDraw=0, lastD=null, busyTap=false;

function font(size,weight){ g.font=(weight||'400')+' '+size+'px -apple-system,Roboto,Helvetica,Arial,sans-serif'; }
function width(s,size,weight){ font(size,weight); return g.measureText(s).width; }
function fit(s,w,size,weight){ font(size,weight); s=s||''; if(g.measureText(s).width<=w) return s;
  let lo=0, hi=s.length; while(lo<hi){ const m=(lo+hi+1)>>1; if(g.measureText(s.slice(0,m)+'…').width<=w) lo=m; else hi=m-1; } return s.slice(0,lo).trimEnd()+'…'; }
function hit(x,y,w,h,fn){ hits.push({x,y,w,h,fn}); }
function hhmm(t){ const d=new Date(t*1000); return String(d.getHours()).padStart(2,'0')+':'+String(d.getMinutes()).padStart(2,'0'); }
function dur(s){ s=Math.max(0,Math.floor(s/60)); return s<60? s+' min' : Math.floor(s/60)+' h'+(s%60?' '+(s%60)+' min':''); }
function say(s,ok){ toast={s,ok}; toastUntil=Date.now()+3000; }
function send(what,label){ if(busyTap) return; busyTap=true; say(label,true); redraw();
  act('walk/'+what).then(r=>{ busyTap=false; if(!r||!r.ok) say("The Mac didn't take it. Is Deckhand running?",false); poll().then(redraw); }); }

function button(label,x,y,w,h,col,size,fn){ rr(x,y,w,h,Math.min(18,h/2),col); txt(label,x+w/2,y+h/2+size*0.36,size,'#fff','center','700'); hit(x-6,y-6,w+12,h+12,fn); }

// A paw print: four toes and a pad.
function paw(x,y,s,col){ g.fillStyle=col; g.beginPath(); g.ellipse(x,y+s*0.35,s*0.42,s*0.34,0,0,7); g.fill();
  [[-0.42,-0.12],[-0.15,-0.42],[0.15,-0.42],[0.42,-0.12]].forEach(p=>{ g.beginPath(); g.ellipse(x+p[0]*s,y+p[1]*s,s*0.15,s*0.19,0,0,7); g.fill(); }); }

function skyLine(d){ const s=d.sky; if(!s) return null;
  const t=(d.temp!=null?d.temp+'° · ':'');
  if(s.wet) return t+(s.until?'Rain until '+hhmm(s.until):'Rain for the next hours');
  return t+(s.until?'Dry until '+hhmm(s.until):'Dry for the next hours'); }

function render(d){
  hits=[];
  const now=Date.now()/1000, dog=d.dog||'the dog';
  renderLeft(d,now,dog);
  renderDay(d,now);
  renderWeek(d);
  if(toast&&Date.now()<toastUntil){ const w=width(toast.s,15,'600')+36; rr(712-w/2,240,w,32,16,toast.ok?'rgba(30,41,59,.96)':'rgba(127,29,29,.96)'); txt(toast.s,712,261,15,'#fff','center','600'); }
}

function renderLeft(d,now,dog){
  let head, col, big, sub=[];
  const last=d.last, since=last?now-last[1]:null;
  if(d.walking){ head='OUT WITH '+dog.toUpperCase()+' · SINCE '+hhmm(d.walking); col=GREEN; big=dur(now-d.walking); }
  else if(!d.active){ head='QUIET HOURS'; col=GREY; big=dog[0].toUpperCase()+dog.slice(1)+' is resting'; if(d.resume) sub.push('Reminders again at '+hhmm(d.resume)); }
  else if(d.due&&d.due<=now&&d.meetingUntil){ head='AFTER THIS MEETING'; col=AMBER; big='Walk '+dog+' at '+hhmm(d.meetingUntil); }
  else if(d.due&&d.due<=now){ const over=now-d.due; head=over>3600?'OVERDUE · '+dur(over).toUpperCase():'TIME FOR A WALK'; col=over>3600?RED:AMBER; big='Time to walk '+dog; }
  else if(d.due){ head='NEXT WALK · IN '+dur(d.due-now).toUpperCase(); col=GREY; big='Around '+hhmm(d.due); }
  else { head='DONE FOR TODAY'; col=GREEN; big='No more walks due'; }
  paw(34,30,22,col); txt(head,58,36,14,col,'left','700');
  txt(fit(big,520,34,'700'),20,86,34,'#fff','left','700');
  if(!d.walking&&last) sub.unshift('Last walk '+(since<90?'just now':dur(since)+' ago')+' · '+dur(last[1]-last[0]));
  if(!d.walking&&!last) sub.unshift('No walks logged yet');
  const sk=skyLine(d); if(sk) sub.push(sk);
  txt(fit(sub.join(' · '),540,16),20,118,16,'#cbd5e1');
  // Buttons.
  const y=150, h=Math.min(76,236-150);
  if(d.walking){
    button('Back home',20,y,250,h,WALK,26,()=>send('back','Welcome back'));
    if(d.undo) button('Call off',290,y,140,h,'#475569',20,()=>send('undo','Walk called off'));
  } else {
    const due=d.active&&d.due&&d.due<=now&&!d.meetingUntil;
    button('Going now',20,y,due?250:200,h,due?WALK:'#334155',due?26:22,()=>send('start','Have a nice walk'));
    button('Walked already',(due?290:240),y,190,h,'#334155',19,()=>send('done','Walk logged'));
    if(d.undo) { const ux=(due?500:450); button('Undo',ux,y,80,h,'#3f3f46',17,()=>send('undo','Undone')); }
  }
}

function renderDay(d,now){
  const X=620, W=470, from=d.from, to=d.to, span=Math.max(3600,to-from);
  const xs=t=>X+Math.max(0,Math.min(1,(t-from)/span))*W;
  g.fillStyle='rgba(255,255,255,.08)'; g.fillRect(X-20,16,1,248);
  txt('TODAY',X,34,13,GREY,'left','600');
  if(d.suggest&&!d.walking){ const s=d.suggest; txt(fit((s.start<=now+60?'Best now':'Best '+hhmm(s.start))+'–'+hhmm(s.end)+(s.dry?' · dry':' · rain likely'),W-70,15,'600'),X+W,34,15,s.dry?GREEN:AMBER,'right','600'); }
  else if(!d.authorized) txt('No calendar access on the Mac',X+W,34,13,DIM,'right');
  // The day bar.
  const by=64, bh=40;
  rr(X,by,W,bh,8,'rgba(255,255,255,.06)');
  (d.busy||[]).forEach(b=>{ const a=xs(b[0]), e=xs(b[1]); if(e-a>0.5) rr(a,by,Math.max(2,e-a),bh,4,'#3b4a6b'); });
  if(d.suggest&&!d.walking){ const a=xs(d.suggest.start), e=xs(d.suggest.end); g.strokeStyle=d.suggest.dry?GREEN:AMBER; g.lineWidth=3; g.setLineDash([6,4]); g.strokeRect(a+1.5,by+1.5,Math.max(4,e-a-3),bh-3); g.setLineDash([]); }
  (d.walks||[]).forEach(w=>{ const a=xs(w[0]), e=xs(w[1]); if(e>X&&a<X+W) rr(a,by+6,Math.max(4,e-a),bh-12,4,WALK); });
  if(d.walking){ const a=xs(d.walking), e=xs(now); rr(a,by+6,Math.max(4,e-a),bh-12,4,GREEN); }
  if(now>=from&&now<=to){ const nx=xs(now); g.fillStyle='#fff'; g.fillRect(nx-1,by-8,2,bh+16); g.beginPath(); g.arc(nx,by-8,4,0,7); g.fill(); }
  // The rain, in the same hours: millimetres per quarter hour, 2 mm fills the strip.
  const ry=168, rh=44;
  g.fillStyle='rgba(255,255,255,.06)'; g.fillRect(X,ry,W,1);
  const rain=(d.rain||[]);
  if(rain.length){ const bw=Math.max(2,W*900/span-1);
    rain.forEach(r=>{ if(r[1]<0.05) return; const x=xs(r[0]), hh=Math.max(3,Math.min(1,r[1]/2)*rh); g.fillStyle=r[1]>=0.5?BLUE:'rgba(96,165,250,.55)'; g.fillRect(x,ry-hh,bw,hh); });
    if(!rain.some(r=>r[1]>=0.1)) txt('Dry as far as the forecast goes',X+6,ry-12,13,DIM);
  }
  // Hours.
  const step=span>12*3600?3:2, h0=new Date(from*1000); h0.setMinutes(0,0,0);
  for(let t=h0.getTime()/1000; t<=to; t+=3600){ const h=new Date(t*1000).getHours(); if(t<from||h%step) continue; const x=xs(t);
    g.fillStyle='rgba(255,255,255,.10)'; g.fillRect(x,by+bh+4,1,6); txt(String(h).padStart(2,'0'),x,ry+22,13,GREY,'center'); }
  // Legend.
  const lx=X, ly=ry+52; rr(lx,ly-10,12,10,3,'#3b4a6b'); txt('Busy',lx+18,ly,13,GREY);
  rr(lx+70,ly-10,12,10,3,WALK); txt('Walks',lx+88,ly,13,GREY);
  g.fillStyle=BLUE; g.fillRect(lx+150,ly-10,6,10); txt('Rain',lx+162,ly,13,GREY);
}

function renderWeek(d){
  const X=1128, W=276;
  g.fillStyle='rgba(255,255,255,.08)'; g.fillRect(X-20,16,1,248);
  txt('TODAY',X,34,13,GREY,'left','600');
  const t=d.today||{count:0,minutes:0};
  txt(String(t.count),X,88,44,'#fff','left','700');
  txt(t.count===1?'walk':'walks',X+width(String(t.count),44,'700')+8,88,18,GREY);
  txt(dur(t.minutes*60),X+W,88,22,'#e5e7eb','right','600');
  const wk=d.week||[], max=Math.max(60,...wk.map(x=>x.minutes)), bx=X, by=230, bh=96, bw=(W-6*10)/7;
  txt('THIS WEEK',X,122,13,GREY,'left','600');
  wk.forEach((x,i)=>{ const h=x.minutes?Math.max(4,x.minutes/max*bh):2, cx=bx+i*(bw+10);
    rr(cx,by-h,bw,h,Math.min(6,h/2),i===wk.length-1?WALK:x.minutes?'#15803d':'rgba(255,255,255,.12)');
    txt(DAYS[x.day]||'',cx+bw/2,by+20,13,i===wk.length-1?'#fff':GREY,'center',i===wk.length-1?'700':'400'); });
}

// Redrawn on new data and taps, and every 10 s for the clock.
function redraw(){ if(D){ lastD=D; lastDraw=Date.now(); bg(); render(D); } }
function frame(){ if(D&&(D!==lastD||Date.now()-lastDraw>=10000||(toast&&Date.now()>toastUntil&&Date.now()-toastUntil<600))) redraw(); setTimeout(frame,250); }

c.addEventListener('click',ev=>{
  const r=c.getBoundingClientRect(), x=(ev.clientX-r.left)*1424/r.width, y=(ev.clientY-r.top)*280/r.height;
  const h=hits.slice().reverse().find(o=>x>=o.x&&x<=o.x+o.w&&y>=o.y&&y<=o.y+o.h);
  if(h&&h.fn) h.fn();
  redraw();
});
