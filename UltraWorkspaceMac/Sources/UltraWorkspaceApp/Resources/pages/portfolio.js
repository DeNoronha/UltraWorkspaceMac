const POLL=30000;
// Portfolio (Kraken): the total with its change and a chart for the chosen period on the left and in the middle, the
// coins on the right. Tap a period to switch, tap a coin for its market statistics (tap again, or wait a minute, to go back).
let period='1D', detail=null, detailUntil=0, chips=[], rows=[];
const COIN={BTC:'#f7931a',ETH:'#627eea',XRP:'#3a3f4b',SOL:'#9945ff',ADA:'#0033ad',DOT:'#e6007a',USDC:'#2775ca',USDT:'#26a17b',DOGE:'#c2a633',LTC:'#345d9d',LINK:'#2a5ada',MATIC:'#8247e5',POL:'#8247e5',AVAX:'#e84142',ATOM:'#2e3148',XLM:'#14b6e7',TRX:'#ef0027',ALGO:'#3a3f4b'};
function nf(cur,dec){ try{ return new Intl.NumberFormat(cur==='EUR'?'nl-NL':'en-US',{style:'currency',currency:cur,minimumFractionDigits:dec,maximumFractionDigits:dec}); }catch(e){ return {format:v=>cur+' '+v.toFixed(dec)}; } }
function money(v,cur,dec){ return nf(cur,dec==null?2:dec).format(v); }
function priceDec(p){ return p<1?4:p<10?3:2; }
function plain(v,dec,cur){ try{ return new Intl.NumberFormat(cur==='EUR'?'nl-NL':'en-US',{minimumFractionDigits:dec,maximumFractionDigits:dec}).format(v); }catch(e){ return v.toFixed(dec); } }
function amountTxt(a,cur){ return plain(a, a>=1000?0:a>=10?2:a>=1?4:4, cur); }
function compact(v,cur){ return v>=1e9? money(v/1e9,cur,1)+' bn' : v>=1e6? money(v/1e6,cur,1)+' M' : v>=1e4? money(v/1e3,cur,0)+'k' : money(v,cur,0); }
function pill(x,y,text,up,size,align){
  g.font='600 '+size+'px -apple-system,Roboto,sans-serif'; const w=g.measureText(text).width+14, X=align==='right'?x-w:x;
  rr(X,y-size-2,w,size+10,6,up?'rgba(34,197,94,.18)':'rgba(239,68,68,.2)'); txt(text,X+7,y+1,size,up?'#4ade80':'#f87171','left','600'); return w;
}
function pct(v){ return (v>0?'+':v<0?'−':'')+plain(Math.abs(v*100),2)+'%'; }
function signed(v,cur){ return (v>0?'+':v<0?'−':'')+money(Math.abs(v),cur); }
function line(xs,x0,y0,w,h,col,fill,hiLo,cur){
  if(!xs||xs.length<2) return; const hi=Math.max(...xs), lo=Math.min(...xs), span=(hi-lo)||1;
  const X=i=>x0+i*w/(xs.length-1), Y=v=>y0+8+(hi-v)/span*(h-16);
  if(hiLo){ g.strokeStyle='rgba(255,255,255,.28)'; g.setLineDash([2,4]); g.lineWidth=1; [hi,lo].forEach(v=>{ g.beginPath(); g.moveTo(x0,Y(v)); g.lineTo(x0+w,Y(v)); g.stroke(); }); g.setLineDash([]);
    txt(money(hi,cur),x0+w,Y(hi)-6,13,'#8b94a6','right'); txt(money(lo,cur),x0+w,Y(lo)+18,13,'#8b94a6','right'); }
  if(fill){ const gr=g.createLinearGradient(0,y0,0,y0+h); gr.addColorStop(0,col.replace('1)','.28)')); gr.addColorStop(1,col.replace('1)','0)'));
    g.fillStyle=gr; g.beginPath(); g.moveTo(X(0),y0+h); xs.forEach((v,i)=>g.lineTo(X(i),Y(v))); g.lineTo(X(xs.length-1),y0+h); g.closePath(); g.fill(); }
  g.strokeStyle=col; g.lineWidth=2.2; g.lineJoin='round'; g.beginPath(); xs.forEach((v,i)=>i?g.lineTo(X(i),Y(v)):g.moveTo(X(i),Y(v))); g.stroke();
}
function icon(x,y,sym){ g.fillStyle=COIN[sym]||'#475569'; g.beginPath(); g.arc(x,y,20,0,7); g.fill(); txt(sym.slice(0,sym.length>4?3:4),x,y+5,sym.length>3?11:14,'#fff','center','700'); }

function render(d){
  if(!d.hasKey){ txt('Add a read-only Kraken API key under Apps → Portfolio in Deckhand.',712,150,22,'#8b94a6','center'); return; }
  if(d.total==null){ txt(d.error||'Reading your Kraken account…',712,150,20,'#8b94a6','center'); return; }
  const cur=d.currency, P=(d.periods||{})[period];
  // --- left: total, change, periods, cash
  txt('PORTFOLIO · KRAKEN',20,32,14,'#8b94a6','left','600');
  txt(money(d.total,cur),20,92,d.total>=1e6?40:50,'#fff','left','700');
  if(P){ const up=P.chgAbs>=0; txt(signed(P.chgAbs,cur),20,132,22,up?'#4ade80':'#f87171','left','600');
    g.font='600 22px -apple-system,Roboto,sans-serif'; pill(30+g.measureText(signed(P.chgAbs,cur)).width,132,pct(P.chg),up,20); }
  chips=[]; ['1D','1W','1M','1Y'].forEach((p,i)=>{ const x=20+i*70, on=p===period; if(on) rr(x,170,62,36,18,'rgba(255,255,255,.14)');
    txt(p,x+31,195,17,on?'#fff':'#8b94a6','center','700'); chips.push({x,p}); });
  txt('Cash '+money(d.cash||0,cur)+(d.hidden?' · '+d.hidden+' more '+money(d.hiddenValue||0,cur,0):''),20,248,15,'#8b94a6');
  if(d.error) txt(clip(d.error,52),20,272,13,'#f59e0b');

  const showDetail=detail&&Date.now()<detailUntil&&(d.coins||[]).find(c=>c.sym===detail);
  if(showDetail){ renderDetail(showDetail,cur); return; }
  // --- middle: the portfolio's line
  if(P){ const up=P.chgAbs>=0; line(P.v,420,24,450,232,up?'rgba(74,222,128,1)':'rgba(248,113,113,1)',true,true,cur); }
  else txt('Collecting prices…',645,150,16,'#8b94a6','center');
  // --- right: the coins
  rows=[]; const list=(d.coins||[]).slice(0,4), R=898;
  rr(R,14,510,list.length*62+8,16,'rgba(255,255,255,.06)');
  list.forEach((c,i)=>{ const y=18+i*62; rows.push({y,sym:c.sym});
    if(i) { g.fillStyle='rgba(255,255,255,.08)'; g.fillRect(R+14,y,482,1); }
    icon(R+34,y+31,c.sym);
    txt(c.sym,R+66,y+27,20,'#fff','left','700');
    txt(amountTxt(c.amount,cur)+'  |  '+money(c.price,cur,priceDec(c.price)),R+66,y+50,15,'#8b94a6');
    txt(money(c.value,cur),R+496,y+27,20,'#fff','right','700');
    if(c.chg!=null){ const up=c.chg>=0, w=pill(R+496,y+52,pct(c.chg),up,14,'right'); txt(signed(c.chgAbs||0,cur),R+490-w,y+51,14,up?'#4ade80':'#f87171','right'); }
  });
  if(!list.length) txt('No coins above the minimum.',R+20,60,16,'#8b94a6');
}

function renderDetail(c,cur){
  const R=420, dec=priceDec(c.price);
  icon(R+20,40,c.sym); txt(c.sym,R+52,48,24,'#fff','left','700');
  txt(money(c.price,cur,dec),R+52,92,34,'#fff','left','700');
  if(c.chg!=null) pill(R+52+g.measureText(money(c.price,cur,dec)).width+30,90,pct(c.chg),c.chg>=0,18);
  // 24h range with the price and the VWAP
  if(c.high!=null&&c.low!=null){ const x0=R+8, w=430, y=134, span=(c.high-c.low)||1, X=v=>x0+Math.max(0,Math.min(1,(v-c.low)/span))*w;
    rr(x0,y-4,w,8,4,'rgba(255,255,255,.12)'); rr(x0,y-4,X(c.price)-x0,8,4,c.chg>=0?'#22c55e':'#ef4444');
    if(c.vwap!=null){ g.fillStyle='#a78bfa'; g.fillRect(X(c.vwap)-1,y-10,2,20); }
    g.fillStyle='#fff'; g.beginPath(); g.arc(X(c.price),y,7,0,7); g.fill();
    txt('24h low '+money(c.low,cur,dec),x0,y+30,14,'#8b94a6'); txt('24h high '+money(c.high,cur,dec),x0+w,y+30,14,'#8b94a6','right'); txt('VWAP',X(c.vwap||c.price),y-16,12,'#a78bfa','center','600'); }
  if(c.spark&&c.spark.length>1) line(c.spark,R+8,186,430,80,c.chg>=0?'rgba(74,222,128,1)':'rgba(248,113,113,1)',true,false,cur);
  // statistics
  const S=898; rr(S,14,510,252,16,'rgba(255,255,255,.06)');
  const spread=c.ask!=null&&c.bid!=null&&c.price? (c.ask-c.bid)/c.price*10000 : null;
  const stats=[['VWAP 24h',c.vwap!=null?money(c.vwap,cur,dec):'—'],['Open today',c.open!=null?money(c.open,cur,dec):'—'],
    ['Volume 24h',c.volume!=null?plain(c.volume,c.volume>=1000?0:2,cur)+' '+c.sym:'—'],['Turnover 24h',c.volume!=null&&c.vwap!=null?compact(c.volume*c.vwap,cur):'—'],
    ['Trades 24h',c.trades!=null?plain(c.trades,0,cur):'—'],['Spread',spread!=null?plain(spread,1,cur)+' bp':'—'],
    ['Bid',c.bid!=null?money(c.bid,cur,dec):'—'],['Ask',c.ask!=null?money(c.ask,cur,dec):'—'],
    ['You hold',amountTxt(c.amount,cur)+' '+c.sym+(c.earn>0?' ('+amountTxt(c.earn,cur)+' in Earn)':'')],['Worth',money(c.value,cur)]];
  stats.forEach((s,i)=>{ const col=i%2, row=Math.floor(i/2), x=S+20+col*250, y=46+row*46;
    txt(s[0],x,y,13,'#8b94a6','left','600'); txt(clip(s[1],26),x,y+22,17,'#fff','left','600'); });
}

c.addEventListener('click',ev=>{
  const r=c.getBoundingClientRect(), x=(ev.clientX-r.left)*1424/r.width, y=(ev.clientY-r.top)*280/r.height;
  const chip=chips.find(o=>x>=o.x&&x<o.x+62&&y>=164&&y<=212); if(chip){ period=chip.p; return; }
  if(detail&&Date.now()<detailUntil&&x>=420){ detail=null; return; }
  if(x>=898){ const row=rows.find(o=>y>=o.y&&y<o.y+62); if(row){ detail=row.sym; detailUntil=Date.now()+60000; } }
});
