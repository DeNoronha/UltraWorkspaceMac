const POLL=20000;
// Teams: on the left the meeting on now or next, with a countdown and a big Join button; in the middle the meetings
// after it, each with its own Join; on the right the speed dial. Tap a person for Call, Video or Chat. Every tap is
// sent to Deckhand as a meeting key or a position only; the Mac opens Teams (or Zoom, or Meet) itself.
const GREEN='#4ade80', RED='#f87171', AMBER='#fbbf24', GREY='#8b94a6', DIM='#5b6475', JOIN='#5b5fc7';
const KIND={teams:'Teams',zoom:'Zoom',meet:'Google Meet'};
const TINTS=['#2563eb','#7c3aed','#db2777','#ea580c','#0d9488','#65a30d','#0891b2','#c026d3'];
let hits=[], person=null, personUntil=0, toast=null, toastUntil=0, lastDraw=0, lastD=null;

function font(size,weight){ g.font=(weight||'400')+' '+size+'px -apple-system,Roboto,Helvetica,Arial,sans-serif'; }
function width(s,size,weight){ font(size,weight); return g.measureText(s).width; }
function fit(s,w,size,weight){ font(size,weight); s=s||''; if(g.measureText(s).width<=w) return s;
  let lo=0, hi=s.length; while(lo<hi){ const m=(lo+hi+1)>>1; if(g.measureText(s.slice(0,m)+'…').width<=w) lo=m; else hi=m-1; } return s.slice(0,lo).trimEnd()+'…'; }
// Up to `lines` lines of `s` in `w` pixels; the last one cut with an ellipsis.
function lines(s,w,size,weight,max){ font(size,weight); const words=(s||'').split(/\s+/), out=[]; let line='';
  for(let i=0;i<words.length;i++){ const t=line?line+' '+words[i]:words[i];
    if(g.measureText(t).width>w&&line){ if(out.length===max-1){ out.push(fit(words.slice(i).length?line+' '+words.slice(i).join(' '):line,w,size,weight)); return out; } out.push(line); line=words[i]; } else line=t; }
  if(line) out.push(fit(line,w,size,weight)); return out; }
function hit(x,y,w,h,fn){ hits.push({x,y,w,h,fn}); }
function hhmm(t){ const d=new Date(t*1000); return String(d.getHours()).padStart(2,'0')+':'+String(d.getMinutes()).padStart(2,'0'); }
function dayLabel(t){ const d=new Date(t*1000), n=new Date(); const a=new Date(n.getFullYear(),n.getMonth(),n.getDate()).getTime(), b=new Date(d.getFullYear(),d.getMonth(),d.getDate()).getTime();
  const k=Math.round((b-a)/86400000); return k===0?'':k===1?'Tomorrow ':['Sun','Mon','Tue','Wed','Thu','Fri','Sat'][d.getDay()]+' '; }
function mins(s){ s=Math.max(0,Math.round(s/60)); return s<60? s+' min' : Math.floor(s/60)+' h'+(s%60?' '+(s%60)+' min':''); }
function say(s,ok){ toast={s,ok}; toastUntil=Date.now()+3500; }
function send(path,label){ say('Opening '+label+' on the Mac…',true); redraw();
  act(path).then(r=>{ if(!r||!r.ok) say("The Mac didn't open it. Is Deckhand running?",false); redraw(); }); }

function joinButton(m,x,y,w,h,size){
  rr(x,y,w,h,h/2>18?16:h/2,JOIN); txt('Join',x+w/2,y+h/2+size*0.36,size,'#fff','center','700');
  hit(x-6,y-6,w+12,h+12,()=>send('teams/join/'+m.key,KIND[m.kind]||'the meeting')); }

function render(d){
  hits=[];
  const now=Date.now()/1000, ms=(d.meetings||[]).filter(m=>m.end>now);
  // --- left: now or next
  if(!d.authorized) txt("Deckhand can't read your calendars. Allow it on the Mac.",20,140,18,GREY);
  else if(!ms.length) { txt('NEXT 36 HOURS',20,34,13,GREY,'left','600'); txt('No meetings.',20,92,30,'#fff','left','700'); txt('Nothing in your calendars until '+dayLabel(now+36*3600).trim().toLowerCase()+' '+hhmm(now+36*3600)+'.',20,124,16,GREY); }
  else renderNext(ms[0],now);
  // --- middle: later
  const X=640, later=ms.slice(1,5);
  g.fillStyle='rgba(255,255,255,.08)'; g.fillRect(X-20,16,1,248);
  txt('LATER',X,34,13,GREY,'left','600');
  if(!later.length) txt(ms.length?'Nothing after this one.':'',X,70,15,DIM);
  later.forEach((m,i)=>{ const y=52+i*54;
    g.fillStyle=m.color||'#60a5fa'; g.beginPath(); g.arc(X+5,y+16,5,0,7); g.fill();
    txt(dayLabel(m.start)+hhmm(m.start),X+18,y+21,15,'#d4d8e0','left','600');
    const tx=X+18+Math.max(54,width(dayLabel(m.start)+hhmm(m.start)+'  ',15,'600'));
    txt(fit(m.title,(m.kind?280:350)-(tx-X-18),16,'600'),tx,y+21,16,'#fff','left','600');
    txt(fit([m.kind?KIND[m.kind]:null,m.place,m.kind?null:m.calendar].filter(Boolean).join(' · '),m.kind?270:340,13),X+18,y+40,13,GREY);
    if(m.kind) joinButton(m,X+300,y+4,58,32,15); });
  // --- right: speed dial
  renderDial(d);
  // A toast after a tap.
  if(toast&&Date.now()<toastUntil){ const w=width(toast.s,15,'600')+36; rr(712-w/2,240,w,32,16,toast.ok?'rgba(30,41,59,.96)':'rgba(127,29,29,.96)'); txt(toast.s,712,261,15,'#fff','center','600'); }
}

function renderNext(m,now){
  const on=m.start<=now, left=on?m.end-now:m.start-now;
  let head, col;
  if(on){ head='NOW · '+mins(left).toUpperCase()+' LEFT'; col=GREEN; }
  else if(left<=60){ head='STARTING NOW'; col=RED; }
  else if(left<=36*3600&&dayLabel(m.start)==='' ){ head='IN '+mins(left).toUpperCase(); col=left<=300?RED:left<=600?AMBER:GREY; }
  else { head=(dayLabel(m.start)||'').toUpperCase()+hhmm(m.start); col=GREY; }
  txt(head,20,34,14,col,'left','700');
  if(on){ const p=Math.min(1,(now-m.start)/Math.max(60,m.end-m.start)); rr(20+width(head,14,'700')+14,25,140,6,3,'rgba(255,255,255,.12)'); rr(20+width(head,14,'700')+14,25,Math.max(6,140*p),6,3,GREEN); }
  const ls=lines(m.title,560,28,'700',2); ls.forEach((l,i)=>txt(l,20,74+i*34,28,'#fff','left','700'));
  const y=ls.length>1?150:118;
  g.fillStyle=m.color||'#60a5fa'; g.beginPath(); g.arc(25,y-5,5,0,7); g.fill();
  txt(fit(hhmm(m.start)+'–'+hhmm(m.end)+' · '+[m.kind?KIND[m.kind]+' meeting':null,m.kind?m.place:null,m.calendar].filter(Boolean).join(' · '),540,16),38,y,16,'#cbd5e1');
  if(m.kind) joinButton(m,20,y+24,240,Math.min(70,256-(y+24)),28);
  else if(m.place) txt(fit(m.place,560,22,'600'),20,y+56,22,'#e5e7eb','left','600');
}

function renderDial(d){
  const X=1028, W=376, cs=(d.contacts||[]);
  g.fillStyle='rgba(255,255,255,.08)'; g.fillRect(X-20,16,1,248);
  if(person!=null&&Date.now()<personUntil&&cs[person]){ renderPerson(cs[person],X,W); return; }
  person=null;
  txt('CALL',X,34,13,GREY,'left','600');
  if(!cs.length){ txt('Add people under Apps → Teams',X,90,16,GREY); txt('in Deckhand.',X,114,16,GREY); return; }
  cs.forEach((c,i)=>{ const col=i%4, row=Math.floor(i/4), cx=X+46+col*94, cy=88+row*104;
    g.fillStyle=c.ok?TINTS[i%TINTS.length]:'#475569'; g.beginPath(); g.arc(cx,cy,32,0,7); g.fill();
    txt(c.initials,cx,cy+9,24,'#fff','center','700');
    txt(fit(c.name.split(' ')[0],88,14,'600'),cx,cy+54,14,'#e5e7eb','center','600');
    if(c.ok) hit(cx-46,cy-40,92,100,()=>{ person=i; personUntil=Date.now()+10000; }); });
}

function renderPerson(c,X,W){
  const i=c.i;
  g.fillStyle=TINTS[i%TINTS.length]; g.beginPath(); g.arc(X+30,52,26,0,7); g.fill(); txt(c.initials,X+30,60,20,'#fff','center','700');
  txt(fit(c.name,W-80,22,'700'),X+68,60,22,'#fff','left','700');
  txt('×',X+W-10,52,28,GREY,'right'); hit(X+W-50,20,56,50,()=>{ person=null; });
  [['Call','audio','#16a34a'],['Video','video',JOIN],['Chat','chat','#475569']].forEach((b,k)=>{ const bx=X+k*126, by=110, bw=114, bh=110;
    rr(bx,by,bw,bh,18,b[2]); icon(b[1],bx+bw/2,by+44); txt(b[0],bx+bw/2,by+92,18,'#fff','center','700');
    hit(bx-4,by-4,bw+8,bh+8,()=>{ person=null; send('teams/call/'+i+'/'+b[1],b[0]==='Chat'?'the chat':'the call'); }); });
}

// Drawn symbols: a handset, a camera, a speech bubble.
function icon(kind,x,y){ g.fillStyle='#fff'; g.strokeStyle='#fff'; g.lineWidth=4; g.lineCap='round'; g.lineJoin='round';
  if(kind==='audio'){ g.save(); g.translate(x,y); g.rotate(-Math.PI/4); rr(-20,-6,40,12,6,'#fff'); rr(-22,-6,12,20,5,'#fff'); rr(10,-6,12,20,5,'#fff'); g.restore(); }
  else if(kind==='video'){ rr(x-22,y-14,32,28,6,'#fff'); g.beginPath(); g.moveTo(x+12,y-4); g.lineTo(x+24,y-12); g.lineTo(x+24,y+12); g.lineTo(x+12,y+4); g.closePath(); g.fill(); }
  else { rr(x-22,y-16,44,28,10,'#fff'); g.beginPath(); g.moveTo(x-10,y+10); g.lineTo(x-14,y+20); g.lineTo(x,y+10); g.closePath(); g.fill(); } }

// Redrawn on new data and taps, and every 10 s for the countdown.
function redraw(){ if(D){ lastD=D; lastDraw=Date.now(); bg(); render(D); } }
function frame(){ if(D&&(D!==lastD||Date.now()-lastDraw>=10000||(toast&&Date.now()>toastUntil&&Date.now()-toastUntil<600))) redraw(); setTimeout(frame,250); }

c.addEventListener('click',ev=>{
  const r=c.getBoundingClientRect(), x=(ev.clientX-r.left)*1424/r.width, y=(ev.clientY-r.top)*280/r.height;
  const h=hits.slice().reverse().find(o=>x>=o.x&&x<=o.x+o.w&&y>=o.y&&y<=o.y+o.h);
  if(h&&h.fn) h.fn(); else if(person!=null&&x>=1008) person=null;
  redraw();
});
