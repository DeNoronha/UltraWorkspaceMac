const POLL=30000;
// The whisky collection at auction prices: on the left what it is worth, against what was paid and a month ago;
// on the right one tile per bottle (six to a page, the most valuable first, pages turn every 12 s) with its market
// value, its month and a two-year sparkline. Tap a bottle for its auctions; tap again (or wait 90 s) to go back.
// Prices are Whiskystats' market values (90-day average of auction buyer prices), in euros, cached by Deckhand.
const UP='#4ade80', DOWN='#f87171', AMBER='#e0a458', DIM='#8b94a6', FAINT='#4b5363', TEXT='#e5e9f0';
let hit=[], sel=null, selAt=0, page=0, pageAt=Date.now(), fmt={};
c.addEventListener('click',e=>{ if(sel){ sel=null; return; }
  const x=e.offsetX, y=e.offsetY; for(const h of hit){ if(x>=h.x&&x<=h.x+h.w&&y>=h.y&&y<=h.y+h.h){ sel=h.id; selAt=Date.now(); return; } } });
function font(size,weight){ g.font=(weight||'400')+' '+size+'px -apple-system,Roboto,Helvetica,Arial,sans-serif'; }
function eur(v,dec){ const k=(D&&D.locale||'')+'|'+(dec||0);
  if(!fmt[k]){ try{ fmt[k]=new Intl.NumberFormat(D&&D.locale||undefined,{style:'currency',currency:'EUR',minimumFractionDigits:dec||0,maximumFractionDigits:dec||0}); }catch(e){ fmt[k]={format:n=>'€ '+Math.round(n)}; } }
  return fmt[k].format(v); }
function pct(x){ const p=x*100, a=Math.abs(p); return (p>=0.05?'+':p<=-0.05?'−':'±')+a.toFixed(a<10?1:0)+'%'; }
function col(x){ return x>=0.005?UP:x<=-0.005?DOWN:DIM; }
// Cut a text to a width in pixels, with an ellipsis.
function fit(s,w,size,weight){ s=s||''; font(size,weight); if(g.measureText(s).width<=w) return s;
  while(s.length>1&&g.measureText(s+'…').width>w) s=s.slice(0,-1); return s.trimEnd()+'…'; }
// Up to `lines` lines within a width, the last one cut.
function wrap(s,w,size,weight,lines){ font(size,weight); const words=(s||'').split(' '), out=[]; let cur='';
  for(let i=0;i<words.length;i++){ const t=cur?cur+' '+words[i]:words[i];
    if(g.measureText(t).width<=w||!cur){ cur=t; continue; }
    if(out.length===lines-1){ cur=cur+' '+words.slice(i).join(' '); break; } out.push(cur); cur=words[i]; }
  out.push(fit(cur,w,size,weight)); return out; }
function spark(pts,x,y,w,h,colr,buy,fill){ if(!pts||pts.length<2) return;
  const lo0=Math.min(...pts,buy||Infinity), hi0=Math.max(...pts,buy||-Infinity), pad=(hi0-lo0)*0.08||1, lo=lo0-pad, hi=hi0+pad;
  const Y=v=>y+h-(v-lo)/(hi-lo)*h, X=j=>x+j*w/(pts.length-1);
  if(buy){ g.strokeStyle='rgba(224,164,88,.55)'; g.setLineDash([5,5]); g.lineWidth=1.5; g.beginPath(); g.moveTo(x,Y(buy)); g.lineTo(x+w,Y(buy)); g.stroke(); g.setLineDash([]); }
  if(fill){ g.beginPath(); pts.forEach((v,j)=>{ j?g.lineTo(X(j),Y(v)):g.moveTo(X(j),Y(v)); }); g.lineTo(x+w,y+h); g.lineTo(x,y+h); g.closePath();
    const gr=g.createLinearGradient(0,y,0,y+h); gr.addColorStop(0,colr+'66'); gr.addColorStop(1,colr+'08'); g.fillStyle=gr; g.fill(); }
  g.beginPath(); pts.forEach((v,j)=>{ j?g.lineTo(X(j),Y(v)):g.moveTo(X(j),Y(v)); }); g.strokeStyle=colr; g.lineWidth=fill?3:2.5; g.lineJoin='round'; g.stroke();
  return {lo,hi,Y}; }
function trend(b){ const s=b.spark||[]; return s.length>1? (s[s.length-1]-s[0])/(s[0]||1) : 0; }

function render(d){
  hit=[]; if(sel&&Date.now()-selAt>90000) sel=null;
  if(!d.hasKey){ txt('Add your Whiskystats key in Deckhand',40,130,32,'#9aa3b2','left','700'); txt('Apps → Cask. The key stays on the Mac.',40,172,19,'#6b7280'); return; }
  const bs=d.bottles||[];
  if(!bs.length){ txt('Add your bottles in Deckhand',40,124,32,'#9aa3b2','left','700');
    txt('Apps → Cask: search Whiskystats or paste a Whiskybase ID, with how many you have and what you paid.',40,166,19,'#6b7280');
    if(d.error) txt(clip(d.error,110),40,200,15,DOWN); return; }
  const b=sel&&bs.find(q=>q.id===sel); if(sel&&!b) sel=null;
  if(b) detail(b,d); else overview(bs,d);
}

// On the right, so the page's ✕ (top-right corner) only covers empty panel.
function summary(d){ const x=1000, y=18, W=316, H=238;
  rr(x,y,W,H,14,'rgba(255,255,255,.06)');
  txt(d.n+(d.n===1?' bottle':' bottles'),x+18,y+32,16,DIM,'left','600');
  txt(d.priced?eur(d.total):'—',x+18,y+86,44,'#fff','left','700');
  if(d.priced<(d.bottles||[]).length) txt((d.bottles.length-d.priced)+' without prices yet',x+18,y+108,13,FAINT);
  let ry=y+140;
  if(d.cost){ const gain=d.costValue-d.cost;
    txt('vs what you paid',x+18,ry,15,DIM); txt((gain>=0?'+':'−')+eur(Math.abs(gain))+'  '+pct(d.vsBuy),x+W-16,ry,17,col(d.vsBuy),'right','700'); ry+=34; }
  if(d.priced){ txt('vs a month ago',x+18,ry,15,DIM); txt(pct(d.d30||0),x+W-16,ry,17,col(d.d30||0),'right','700'); ry+=34; }
  const cr=d.credits;
  if(d.error){ const l=wrap(d.error,W-36,12,'400',2); l.forEach((s,j)=>txt(s,x+18,y+H-14-(l.length-1-j)*16,12,DOWN)); }
  else txt(cr?cr.left+' credits left · prices every '+d.every+' days':'auction prices via Whiskystats',x+18,y+H-14,12,FAINT);
}

function overview(bs,d){
  summary(d);
  const per=bs.length<=3?bs.length:bs.length===4?4:6, pages=Math.ceil(bs.length/per);
  if(Date.now()-pageAt>12000){ page=(page+1)%pages; pageAt=Date.now(); } if(page>=pages) page=0;
  const show=bs.slice(page*per,page*per+per), rows=per<=3?1:2, cols=Math.ceil(per/rows);
  const X0=24, X1=984, Y0=18, gap=12, H=pages>1?226:238, W=(X1-X0-gap*(cols-1))/cols, TH=(H-gap*(rows-1))/rows;
  show.forEach((b,i)=>{ const x=X0+(i%cols)*(W+gap), y=Y0+Math.floor(i/cols)*(TH+gap); tile(b,x,y,W,TH); hit.push({x,y,w:W,h:TH,id:b.id}); });
  if(pages>1) for(let p=0;p<pages;p++){ g.fillStyle=p===page?'#cbd2dc':FAINT; g.beginPath(); g.arc((X0+X1)/2+(p-(pages-1)/2)*16,Y0+H+12,4,0,7); g.fill(); }
  txt('tap a bottle for its auctions',X0,272,12,FAINT,'left');
}

function tile(b,x,y,w,h){
  rr(x,y,w,h,14,'rgba(255,255,255,.06)');
  const tall=h>150, ns=tall?18:15, qty=b.qty>1?b.qty+'×':'';
  font(ns,'700'); const qw=qty?g.measureText(qty).width+7:0;
  if(qty) txt(qty,x+14,y+26,ns,AMBER,'left','700');
  const name=wrap(b.name,w-28-qw,ns,'700',tall?2:1); name.forEach((l,j)=>txt(l,x+14+(j?0:qw),y+26+j*22,ns,'#fff','left','700'));
  const top=y+26+(name.length-1)*22;
  if(b.value==null){ txt(fit(b.pending||'waiting for prices',w-28,13),x+14,top+30,13,b.err?DOWN:DIM); return; }
  const tr=trend(b), sc=col(tr), big=tall?34:24;
  txt(eur(b.value),x+14,top+(tall?46:34),big,'#fff','left','700');
  font(big,'700'); const vw=g.measureText(eur(b.value)).width, mt=pct(b.d30||0)+' month';
  txt(mt,x+14+vw+10,top+(tall?46:34),13,col(b.d30||0),'left','600');
  font(13,'600'); const textEnd=x+14+vw+10+g.measureText(mt).width+14;
  if(tall){
    const sx=x+14, sw=w-28, sy=top+64, sh=h-(top-y)-118;
    spark(b.spark,sx,sy,sw,sh,sc,b.buy,true);
    let ly=y+h-44;
    if(b.last) txt(fit('Last sold '+b.last.date+': '+(b.last.min===b.last.max?eur(b.last.avg):eur(b.last.min)+'–'+eur(b.last.max))+(b.last.n>1?' ('+b.last.n+')':''),sw,14),sx,ly,14,TEXT);
    ly+=20;
    const l=(b.lots||[])[0]; if(l) txt(fit('At auction: '+l.house+', ends '+l.end,sw,13),sx,ly,13,AMBER);
    else if(b.vsBuy!=null) txt('Paid '+eur(b.buy)+' · '+pct(b.vsBuy),sx,ly,13,col(b.vsBuy));
  } else {
    // The sparkline takes the right of the tile, after the value and its month, never under them.
    const sx=Math.max(x+w*0.56,textEnd), sw=x+w-14-sx, sy=top+10, sh=h-(top-y)-38;
    spark(b.spark,sx,sy,sw,sh,sc,b.buy,false);
    let lw=0; if((b.nLots||0)>0){ const t=b.nLots+' at auction'; font(12,'600'); lw=g.measureText(t).width+12; txt(t,x+w-14,y+h-14,12,AMBER,'right','600'); }
    if(b.last) txt(fit('Sold '+b.last.date+': '+(b.last.min===b.last.max?eur(b.last.avg):eur(b.last.min)+'–'+eur(b.last.max)),w-28-lw,12),x+14,y+h-14,12,DIM);
  }
}

function detail(b,d){
  // Left: the bottle and what it is worth.
  const name=wrap(b.name,380,22,'700',2); name.forEach((l,j)=>txt(l,24,44+j*28,22,'#fff','left','700'));
  let y=44+(name.length-1)*28+22;
  txt(b.wid+(b.group?' · prices of group '+b.group:''),24,y,12,FAINT); y+=46;
  if(b.value==null){ txt(fit(b.pending||'waiting for prices',380,16),24,y,16,b.err?DOWN:DIM); txt('tap to go back',24,272,12,FAINT,'left'); return; }
  txt(eur(b.value),24,y,38,'#fff','left','700'); font(38,'700'); const vw=g.measureText(eur(b.value)).width;
  txt('market value',24+vw+12,y-14,13,DIM); txt('per bottle',24+vw+12,y+1,13,DIM); y+=32;
  if(b.qty>1){ txt(b.qty+' bottles: '+eur(b.sub),24,y,16,TEXT,'left','600'); y+=26; }
  if(b.buy!=null){ txt(fit('Paid '+eur(b.buy)+(b.bought?' on '+b.bought:''),250,15),24,y,15,DIM); txt(pct(b.vsBuy),404,y,15,col(b.vsBuy),'right','700'); y+=24; }
  txt('A month',24,y,15,DIM); txt(pct(b.d30||0),404,y,15,col(b.d30||0),'right','700'); y+=24;
  if(b.y12&&y<262){ txt('12 months',24,y,15,DIM); txt(pct(b.y12.chg||0),404,y,15,col(b.y12.chg||0),'right','700'); }
  txt('tap to go back',24,272,12,FAINT,'left');
  // Middle: the market value over (up to) two years, with what was paid as a dashed line.
  const cx=446, cw=440, cy=40, ch=180, s=b.spark||[];
  rr(cx-14,cy-26,cw+28,ch+66,14,'rgba(255,255,255,.05)');
  txt('Market value',cx,cy-6,13,DIM,'left','600');
  const r=spark(s,cx,cy+8,cw,ch-24,col(trend(b)),b.buy,true);
  if(r){ const mx=Math.max(...s), mn=Math.min(...s);
    txt('high '+eur(mx)+' · low '+eur(mn),cx+cw,cy-6,12,DIM,'right');
    txt(b.sparkFrom||'',cx,cy+ch+12,12,FAINT); txt('today',cx+cw,cy+ch+12,12,FAINT,'right');
    if(b.buy!=null) txt('paid',cx+4,r.Y(b.buy)-6,11,AMBER); }
  else txt('not enough trades for a chart',cx,cy+90,15,FAINT);
  // Right: the latest auction results and the lots on offer now.
  const rx=914, rw=300; let ry=44;
  txt('Recent auction results',rx,ry,13,DIM,'left','600'); ry+=24;
  if(b.last){ txt(fit(b.last.date+': '+(b.last.min===b.last.max?eur(b.last.avg):eur(b.last.min)+' – '+eur(b.last.max))+(b.last.n>1?', '+b.last.n+' sold':''),rw,16,'600'),rx,ry,16,TEXT,'left','600'); ry+=22; }
  if(b.y12){ txt(fit('12 months: '+eur(b.y12.min)+' – '+eur(b.y12.max)+', '+b.y12.n+' sold',rw,14),rx,ry,14,DIM); ry+=20; }
  if(b.high){ txt(fit('Highest ever '+eur(b.high.p)+' ('+b.high.date+')',rw,14),rx,ry,14,DIM); ry+=20; }
  ry+=14;
  const lots=b.lots||[];
  if(b.lots){ txt(lots.length?'At auction now'+(b.nLots>lots.length?' ('+b.nLots+')':''):'Not at auction right now',rx,ry,13,DIM,'left','600'); ry+=22;
    lots.slice(0,3).forEach(l=>{ if(ry>262) return; txt(l.end,rx,ry,14,AMBER,'left','600'); txt(fit(l.house+(l.auction?' · '+l.auction:''),rw-70,14),rx+70,ry,14,TEXT); ry+=21; }); }
}
