const POLL=60000; let start=0, tick=Math.floor(Date.now()/15000);   // tick starts "now", so the page opens on headline 1
function wrapText(s,max){ const words=(s||'').split(' '), lines=[]; let cur=''; for(const w of words){ const t=cur?cur+' '+w:w; if(t.length>max&&cur){ lines.push(cur); cur=w; } else cur=t; } if(cur) lines.push(cur); return lines; }
function render(d){
  const items=d.items||[]; if(!items.length){ txt(d.error||'Loading '+(d.source||'headlines')+'…',40,150,22,'#8b94a6'); return; }
  const t=Math.floor(Date.now()/15000); if(t!==tick){ tick=t; start=(start+4)%items.length; }
  if(start>=items.length) start=0;   // the list shrank since the last page turn
  txt(d.source||'',40,34,15,'#8b94a6','left','600'); txt(d.at? 'updated '+ago(Math.floor(Date.now()/1000-d.at))+' ago':'',1384,34,13,'#6b7280','right');
  for(let i=0;i<Math.min(4,items.length);i++){ const it=items[(start+i)%items.length]; const col=i%2, row=Math.floor(i/2); const x=40+col*700, y=70+row*105;
    rr(x,y,660,90,12,'rgba(255,255,255,.06)');
    const lines=wrapText(it.title,52).slice(0,2); lines.forEach((l,j)=> txt(l,x+18,y+34+j*28,22,'#fff','left',j?'400':'600'));
    if(it.ago!=null) txt(ago(it.ago)+' ago',x+642,y+78,13,'#8b94a6','right'); else if(it.day) txt(it.day,x+642,y+78,13,'#8b94a6','right'); }
  txt((start+1)+'–'+Math.min(items.length,start+4)+' of '+items.length,712,272,12,'#4b5363','center');
}
