const POLL=60000;
// Books (e-Boekhouden): the bank on the left, debtors and creditors in the middle (tap one for its largest open
// invoices), revenue per month against last year and the profit so far on the right. From Deckhand (/books/data.json).
// With "Hide amounts until tapped" the amounts are dots until a tap shows them for 30 seconds.
let view=null, viewUntil=0, revealUntil=0, hits=[];
const MON=['J','F','M','A','M','J','J','A','S','O','N','D'];
const EUR=new Intl.NumberFormat('nl-NL',{style:'currency',currency:'EUR',minimumFractionDigits:0,maximumFractionDigits:0});
function hidden(d){ return d.hide&&Date.now()>revealUntil; }
function eur(v,d){ return hidden(d)?'€ ••••':EUR.format(Math.round(v||0)); }
function short(v){ const a=Math.abs(v); return a>=1e6?(v/1e6).toFixed(1).replace('.',',')+' M':a>=1e4?Math.round(v/1e3)+'k':a>=1e3?(v/1e3).toFixed(1).replace('.',',')+'k':String(Math.round(v)); }
function open(d,o,label,x,y){
  txt(label,x,y,14,'#8b94a6','left','600');
  if(!o){ txt('—',x,y+34,26,'#8b94a6','left','700'); return; }
  txt(eur(o.total,d),x,y+36,28,'#fff','left','700');
  const s=o.count===0?'nothing open':o.count+' open'+(o.overdueCount?' · '+o.overdueCount+' older than 30 days':'');
  txt(s,x,y+60,14,o.overdueCount?'#f59e0b':'#8b94a6');
}
function render(d){
  hits=[];
  if(!d.hasToken){ txt('Add your e-Boekhouden API token under Apps → Books in Deckhand.',712,150,22,'#8b94a6','center'); return; }
  if(!d.updated){ txt(d.error||'Reading your administration…',712,150,20,d.error?'#f59e0b':'#8b94a6','center'); return; }
  // --- left: the bank
  txt('BOOKS'+(d.company?' · '+clip(d.company.toUpperCase(),26):''),20,32,14,'#8b94a6','left','600');
  txt(eur(d.bankTotal,d),20,88,44,d.bankTotal<0&&!hidden(d)?'#f87171':'#fff','left','700');
  txt('in the bank',20,112,14,'#8b94a6');
  (d.bank||[]).slice(0,4).forEach((b,i)=>{ const y=148+i*30; txt(clip(b.name,22),20,y,16,'#cbd5e1'); txt(eur(b.balance,d),316,y,16,b.balance<0&&!hidden(d)?'#f87171':'#e5e7eb','right','600'); });
  if(d.error) txt(clip(d.error,44),20,268,12,'#f59e0b');
  // --- middle: debtors and creditors
  const M=356; g.fillStyle='rgba(255,255,255,.08)'; g.fillRect(M-18,16,1,248);
  open(d,d.debtors,'DEBTORS · TO COLLECT',M,32); hits.push({x:M-10,y:10,w:300,h:118,v:'debtors'});
  open(d,d.creditors,'CREDITORS · TO PAY',M,158); hits.push({x:M-10,y:136,w:300,h:130,v:'creditors'});
  if(view&&Date.now()>viewUntil) view=null;
  if(view){ rr(M-10,view==='debtors'?14:140,296,view==='debtors'?118:124,12,'rgba(255,255,255,.06)'); }
  // --- right: the list, or revenue and profit
  const R=676, W=728; g.fillStyle='rgba(255,255,255,.08)'; g.fillRect(R-18,16,1,248);
  if(view){
    const o=d[view]||{}, list=o.top||[];
    txt((view==='debtors'?'LARGEST OPEN INVOICES · DEBTORS':'LARGEST OPEN INVOICES · CREDITORS'),R,32,14,'#8b94a6','left','600');
    if(!list.length) txt('Nothing open.',R,80,18,'#8b94a6');
    list.slice(0,5).forEach((t,i)=>{ const y=70+i*40;
      txt(clip(t.company||'—',34),R,y,18,'#e5e7eb','left','600'); txt((t.number?t.number+' · ':'')+t.days+' days',R+430,y,14,t.days>30?'#f59e0b':'#8b94a6','right');
      txt(eur(t.amount,d),R+W,y,18,'#fff','right','700'); });
    return;
  }
  const y0=d.ytd||{}, prof=y0.profit||0;
  txt('REVENUE PER MONTH · '+d.year,R,32,14,'#8b94a6','left','600');
  txt('PROFIT '+d.year+' SO FAR',R+W,32,14,'#8b94a6','right','600');
  txt(eur(prof,d),R+W,72,34,prof<0&&!hidden(d)?'#f87171':'#4ade80','right','700');
  txt('revenue '+eur(y0.revenue,d)+' · costs '+eur(y0.costs,d),R+W,96,13,'#8b94a6','right');
  // bars: this year (blue) in front of last year (grey)
  const months=d.months||[], last=d.lastYear||[], cx=R, cw=W-250, top=56, ch=180;
  const max=Math.max(1,...months.filter(v=>v!=null),...last.filter(v=>v!=null)), bw=cw/12;
  const now=new Date().getMonth();
  for(let m=0;m<12;m++){ const x=cx+m*bw;
    if(last[m]!=null&&last[m]>0){ const h=last[m]/max*ch; rr(x+3,top+ch-h,bw-6,h,3,'rgba(255,255,255,.10)'); }
    if(months[m]!=null&&months[m]>0){ const h=Math.max(2,months[m]/max*ch); rr(x+bw*0.22,top+ch-h,bw*0.56,h,3,m===now?'#60a5fa':'#3b82f6'); }
    txt(MON[m],x+bw/2,top+ch+20,12,m===now?'#fff':'#6b7280','center',m===now?'700':'400');
  }
  if(!hidden(d)) txt(short(max),cx+cw+6,top+10,11,'#6b7280');
  txt('■ '+d.year,R+W-240,150,13,'#60a5fa'); txt('■ '+(d.year-1),R+W-170,150,13,'rgba(255,255,255,.35)');
  const thisM=months[now]; if(thisM!=null) txt('This month '+eur(thisM,d),R+W,176,14,'#cbd5e1','right');
  const lastM=last[now]; if(lastM!=null) txt('Same month '+(d.year-1)+' '+eur(lastM,d),R+W,198,13,'#8b94a6','right');
  if(d.updated) txt('updated '+ago(Math.max(0,Math.round(Date.now()/1000-d.updated)))+' ago',R+W,262,12,'#6b7280','right');
}
c.addEventListener('click',ev=>{
  const r=c.getBoundingClientRect(), x=(ev.clientX-r.left)*1424/r.width, y=(ev.clientY-r.top)*280/r.height;
  if(D&&D.hide&&Date.now()>revealUntil){ revealUntil=Date.now()+30000; return; }
  const h=hits.find(o=>x>=o.x&&x<o.x+o.w&&y>=o.y&&y<o.y+o.h);
  if(h){ view=view===h.v?null:h.v; viewUntil=Date.now()+60000; } else if(x>=658) view=null;
});
// Redrawn once a second at most (the reveal ends, "updated … ago"), and at once on new data or a tap.
let lastD=null, lastDraw=0, dirty=false;
c.addEventListener('click',()=>{ dirty=true; });
function frame(){ const t=Date.now(); if(D&&(D!==lastD||dirty||t-lastDraw>=1000)){ lastD=D; dirty=false; lastDraw=t; bg(); render(D); } setTimeout(frame,250); }
