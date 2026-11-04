const POLL=2000; let artKey=null, img=null;
document.body.insertAdjacentHTML('beforeend','<div class="btn" id="p" style="left:330px">⏮</div><div class="btn" id="pp" style="left:410px">⏯</div><div class="btn" id="n" style="left:490px">⏭</div>');
for(const [id,cmd] of [['p','previous'],['pp','play'],['n','next']]) document.getElementById(id).onclick=()=>act('/music/cmd/'+cmd).then(poll);
function render(d){
  if(d.hasTrack && d.artKey!==artKey){ artKey=d.artKey; const i=new Image(); i.onload=()=>{img=i}; i.onerror=()=>{img=null}; i.src='/music/art.jpg?k='+encodeURIComponent(artKey); }
  // Forget the art key too, so the same track coming back after a stop reloads its cover.
  if(!d.hasTrack){ txt('Nothing playing in Music',330,140,30,'#8b94a6','left','600'); img=null; artKey=null; }
  if(img){ g.save(); rr(40,20,240,240,18,'#000'); g.clip(); g.drawImage(img,40,20,240,240); g.restore(); } else { rr(40,20,240,240,18,'rgba(255,255,255,.08)'); txt('♪',160,170,90,'#4b5363','center'); }
  if(d.hasTrack){ txt(clip(d.title,40),330,70,38,'#fff','left','700'); txt(clip(d.artist,50),330,112,26,'#d6dbe6'); txt(clip(d.album,60),330,146,20,'#8b94a6');
    txt(d.playing?'Playing':'Paused',330,182,17,d.playing?'#4ade80':'#fbbf24','left','600'); }
  const t=Date.now()/1000; if(d.playing){ for(let i=0;i<24;i++){ const h=18+Math.abs(Math.sin(t*2+i*.7))*60; rr(820+i*24,150-h/2,14,h,5,'#4f8cff'); } }
  document.getElementById('pp').textContent=d.playing?'⏸':'▶';
}
