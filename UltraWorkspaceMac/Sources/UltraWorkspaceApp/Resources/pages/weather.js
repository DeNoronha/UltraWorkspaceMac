const POLL=60000;
function icon(sky,x,y,r,isDay){ // simple canvas glyphs
  const sun=()=>{ g.fillStyle='#fbbf24'; g.beginPath(); g.arc(x,y,r*.55,0,7); g.fill(); g.strokeStyle='#fbbf24'; g.lineWidth=r*.12; for(let a=0;a<8;a++){ g.beginPath(); g.moveTo(x+Math.cos(a*Math.PI/4)*r*.75,y+Math.sin(a*Math.PI/4)*r*.75); g.lineTo(x+Math.cos(a*Math.PI/4)*r,y+Math.sin(a*Math.PI/4)*r); g.stroke(); } };
  const moon=()=>{ g.fillStyle='#e5e7eb'; g.beginPath(); g.arc(x,y,r*.6,0,7); g.fill(); g.fillStyle='#1c2029'; g.beginPath(); g.arc(x+r*.3,y-r*.2,r*.5,0,7); g.fill(); };
  const cloud=(dx,dy,s,col)=>{ g.fillStyle=col; g.beginPath(); g.arc(x+dx-s*.5,y+dy,s*.45,0,7); g.arc(x+dx,y+dy-s*.3,s*.6,0,7); g.arc(x+dx+s*.55,y+dy,s*.45,0,7); g.fill(); g.fillRect(x+dx-s*.5,y+dy,s*1.05,s*.45); };
  const drops=(col,len)=>{ g.strokeStyle=col; g.lineWidth=r*.1; g.lineCap='round'; for(let i=-1;i<=1;i++){ g.beginPath(); g.moveTo(x+i*r*.35,y+r*.5); g.lineTo(x+i*r*.35-r*.1,y+r*.5+len); g.stroke(); } };
  switch(sky){
    case 'clear': isDay?sun():moon(); break;
    case 'partlyCloudy': isDay?sun():moon(); cloud(r*.15,r*.25,r*.75,'#cbd5e1'); break;
    case 'cloudy': case 'fog': cloud(0,r*.1,r*.9,'#cbd5e1'); break;
    case 'drizzle': case 'rain': case 'showers': cloud(0,-r*.1,r*.85,'#94a3b8'); drops('#60a5fa',r*.4); break;
    case 'snow': cloud(0,-r*.1,r*.85,'#cbd5e1'); drops('#fff',r*.3); break;
    case 'thunder': cloud(0,-r*.1,r*.85,'#64748b'); g.fillStyle='#fbbf24'; g.beginPath(); g.moveTo(x,y+r*.3); g.lineTo(x-r*.25,y+r*.8); g.lineTo(x+r*.05,y+r*.7); g.lineTo(x-r*.1,y+r*1.1); g.lineTo(x+r*.3,y+r*.55); g.lineTo(x,y+r*.65); g.closePath(); g.fill(); break;
    default: cloud(0,r*.1,r*.9,'#94a3b8');
  }
}
const names={clear:'Clear',partlyCloudy:'Partly cloudy',cloudy:'Cloudy',fog:'Fog',drizzle:'Drizzle',rain:'Rain',showers:'Showers',snow:'Snow',thunder:'Thunderstorm',unknown:''};
function render(d){
  if(!d.place && !d.days){ txt('Waiting for the weather…',40,150,22,'#8b94a6'); return; }
  icon(d.sky,130,130,80,d.isDay);
  txt(Math.round(d.temp)+(d.unit||'°'),250,150,96,'#fff','left','700');
  txt(d.place||'',250,46,22,'#d6dbe6','left','600');
  txt((names[d.sky]||'')+'  ·  '+d.humidity+' %  ·  wind '+d.wind+' '+(d.windUnit||''),250,200,19,'#8b94a6');
  const days=(d.days||[]).slice(1,4); days.forEach((day,i)=>{ const x=760+i*215, y=24, W=200, H=232; rr(x,y,W,H,16,'rgba(255,255,255,.07)');
    const dt=new Date(day.date+'T12:00:00'); txt(i===0?'Tomorrow':dt.toLocaleDateString(undefined,{weekday:'long'}),x+16,y+36,20,'#fff','left','700');
    icon(day.sky,x+W/2,y+110,46,true);
    txt(Math.round(day.max)+'°',x+16,y+205,30,'#fff','left','700'); txt(Math.round(day.min)+'°',x+W-16,y+205,24,'#8b94a6','right','600');
    if(day.rain>0) txt(day.rain+' % rain',x+W/2,y+H-16,14,'#60a5fa','center');
  });
  const today=(d.days||[])[0]; if(today) txt('Today '+Math.round(today.max)+'° / '+Math.round(today.min)+'°'+(today.rain>0?'  ·  '+today.rain+' % rain':''),250,236,17,'#b4bccb');
}
