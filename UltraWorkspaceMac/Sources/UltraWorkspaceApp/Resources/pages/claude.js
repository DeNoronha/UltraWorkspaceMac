const POLL=2000;
function render(d){
  const w=d.waiting||0;
  txt('Claude Code',40,46,20,'#d6dbe6','left','600');
  txt(w? (w===1?'1 terminal needs you':w+' terminals need you') : 'Nothing waiting', 40,100,40,w?'#fbbf24':'#9aa3b2','left','700');
  txt((d.active||0)+' active · '+(d.tokens||'0')+' tokens today',40,136,17,'#8b94a6');
  const list=(d.sessions||[]).slice().sort((a,b)=> (a.state!=='working')===(b.state!=='working') ? 0 : (a.state!=='working'? -1:1)).slice(0,4);
  const pulse=0.5+0.5*Math.sin(Date.now()/350);
  list.forEach((s,i)=>{ const x=470+i*235, y=28, W=222, H=224;
    const wait=s.state!=='working';
    rr(x,y,W,H,14, wait? 'rgba(251,191,36,'+(0.22+0.18*pulse)+')' : 'rgba(255,255,255,.07)');
    if(wait){ g.strokeStyle='rgba(251,191,36,'+(0.6+0.4*pulse)+')'; g.lineWidth=3; g.strokeRect(x+1.5,y+1.5,W-3,H-3); }
    txt(clip(s.project,16),x+16,y+40,24,'#fff','left','700');
    txt(s.state==='question'?'asks a question': wait?'waiting for you':'working…', x+16,y+68,16, wait?'#fde68a':'#8b94a6','left','600');
    // Two lines each: the first line is cut without an ellipsis (the text goes on below), the second is clipped.
    const ti=s.title||'', la=s.last||'';
    txt(ti.slice(0,25),x+16,y+100,15,'#c7cdd8'); const t2=clip(ti,52).slice(25); if(t2) txt(t2,x+16,y+122,15,'#c7cdd8');
    txt(la.slice(0,29),x+16,y+170,14,'#8b94a6'); const l2=clip(la,60).slice(29); if(l2) txt(l2,x+16,y+190,14,'#8b94a6');
    txt(ago(s.ago)+' ago',x+16,y+H-16,14,'#6b7280');
  });
  if(!list.length) txt('No Claude Code session in the last hour.',470,150,20,'#6b7280');
}
