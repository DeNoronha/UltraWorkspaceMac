const POLL=15000;
function render(d){
  const coins=d.coins||[], n=Math.max(1,Math.min(5,coins.length)), W=Math.floor((1424-80-(n-1)*20)/n);
  coins.slice(0,5).forEach((c,i)=>{ const x=40+i*(W+20), y=24, H=232; rr(x,y,W,H,16,'rgba(255,255,255,.07)');
    const up=(c.change||0)>=0, col=up?'#4ade80':'#f87171';
    txt(c.symbol,x+18,y+42,26,'#fff','left','700');
    txt((up?'+':'')+(c.change||0).toFixed(2)+'%',x+W-18,y+42,22,col,'right','700');
    const p=c.price||0; txt(p.toLocaleString(undefined,{maximumFractionDigits:p<10?4:2})+' '+(d.suffix||''),x+18,y+84,34,'#fff','left','700');
    const pts=c.points||[]; if(pts.length>1){ const lo=Math.min(...pts,c.open||Infinity), hi=Math.max(...pts,c.open||-Infinity), gx=x+18, gy=y+104, gw=W-36, gh=100;
      const Y=v=> gy+gh-(hi>lo?(v-lo)/(hi-lo):0.5)*gh;
      if(c.open){ g.strokeStyle='rgba(255,255,255,.25)'; g.setLineDash([4,4]); g.beginPath(); g.moveTo(gx,Y(c.open)); g.lineTo(gx+gw,Y(c.open)); g.stroke(); g.setLineDash([]); }
      g.beginPath(); pts.forEach((v,j)=>{ const px=gx+j*gw/(pts.length-1); j?g.lineTo(px,Y(v)):g.moveTo(px,Y(v)); });
      g.lineTo(gx+gw,gy+gh); g.lineTo(gx,gy+gh); g.closePath(); const gr=g.createLinearGradient(0,gy,0,gy+gh); gr.addColorStop(0,col+'c0'); gr.addColorStop(1,col+'20'); g.fillStyle=gr; g.fill();
      g.beginPath(); pts.forEach((v,j)=>{ const px=gx+j*gw/(pts.length-1); j?g.lineTo(px,Y(v)):g.moveTo(px,Y(v)); }); g.strokeStyle=col; g.lineWidth=3; g.stroke();
      txt('today',gx,y+H-14,13,'#8b94a6'); }
  });
  if(!coins.length) txt('No coins set — Widgets → Crypto in Deckhand.',40,150,22,'#8b94a6');
}
