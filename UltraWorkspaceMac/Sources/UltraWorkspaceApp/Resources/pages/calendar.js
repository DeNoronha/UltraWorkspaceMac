const POLL=30000;
function render(d){
  if(d.authorized===false){ txt('Calendar access is off — allow it in Deckhand (Widgets → Calendar).',40,150,22,'#8b94a6'); return; }
  (d.days||[]).forEach((day,i)=>{ const x=40+i*455, y=20, W=435, H=240; rr(x,y,W,H,16,'rgba(255,255,255,.07)');
    txt(day.name,x+18,y+38,24,'#fff','left','700'); txt(day.date,x+W-18,y+38,18,'#8b94a6','right');
    const evs=day.events||[]; if(!evs.length) txt('Nothing planned',x+18,y+90,18,'#6b7280');
    evs.slice(0,5).forEach((e,j)=>{ const ey=y+66+j*34; rr(x+18,ey,6,24,3,e.color||'#4f8cff');
      txt(e.time,x+34,ey+18,15,e.past?'#6b7280':'#b4bccb','left','600'); txt(clip(e.title,34),x+150,ey+18,17,e.past?'#6b7280':'#fff'); });
    if(evs.length>5) txt('+'+(evs.length-5)+' more',x+18,y+H-14,14,'#8b94a6');
  });
}
