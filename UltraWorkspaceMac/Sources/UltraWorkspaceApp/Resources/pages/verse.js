const POLL=600000;
function wrapText(s,max){ const words=(s||'').split(' '), lines=[]; let cur=''; for(const w of words){ const t=cur?cur+' '+w:w; if(t.length>max){ lines.push(cur); cur=w; } else cur=t; } if(cur) lines.push(cur); return lines; }
function render(d){
  const gr=g.createLinearGradient(0,0,1424,280); gr.addColorStop(0,'#1f2433'); gr.addColorStop(1,'#2b2340'); g.fillStyle=gr; g.fillRect(0,0,1424,280);
  if(!d.text){ txt('Fetching today’s verse…',712,150,22,'#8b94a6','center'); return; }
  const long=d.text.length>230, size=long?24:(d.text.length>150?28:32), lines=wrapText(d.text, long?95:(size>28?70:80)).slice(0,4);
  const lh=size*1.25, y0=140-(lines.length-1)*lh/2-10;
  lines.forEach((l,i)=> txt(l,712,y0+i*lh,size,'#fff','center',i===0?'600':'400'));
  txt('— '+d.reference,712,y0+lines.length*lh+14,20,'#fbbf24','center','700');
  txt((d.date||'')+'  ·  '+(d.translation||''),712,264,13,'#6b7280','center');
}
