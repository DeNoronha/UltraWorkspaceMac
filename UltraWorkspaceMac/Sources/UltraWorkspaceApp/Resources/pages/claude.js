const POLL=2000;
// Width-aware text: cut to fit `maxW` (with an ellipsis), or split over two lines.
function fontOf(size,weight){ return (weight||'400')+' '+size+'px -apple-system,Roboto,Helvetica,Arial,sans-serif'; }
function fit(s,maxW,size,weight){ s=s||''; g.font=fontOf(size,weight); if(g.measureText(s).width<=maxW) return s;
  while(s.length>1 && g.measureText(s+'…').width>maxW) s=s.slice(0,-1); return s+'…'; }
function two(s,maxW,size){ s=(s||'').trim(); g.font=fontOf(size); if(g.measureText(s).width<=maxW) return [s,''];
  let cut=s.length; while(cut>1 && g.measureText(s.slice(0,cut)).width>maxW) cut--;
  const sp=s.lastIndexOf(' ',cut); if(sp>cut*0.6) cut=sp; return [s.slice(0,cut), fit(s.slice(cut).trim(),maxW,size)]; }
function render(d){
  // The tiles keep clear of the close button in the top-right corner (about 80 px).
  const sessions=d.sessions||[], M=16, GAP=12, H=248, Y=16, AREA=1424-M-84;
  const maxTiles=Math.floor((AREA-M+GAP)/(150+GAP)), shown=sessions.slice(0,maxTiles-1);
  const n=1+Math.max(shown.length,1), W=Math.min(222,Math.floor((AREA-M-GAP*(n-1))/n)), P=Math.max(12,Math.round(W*0.07)), IW=W-2*P;
  const pulse=0.5+0.5*Math.sin(Date.now()/350);
  // Tile 1: today's usage.
  let x=M;
  rr(x,Y,W,H,14,'rgba(255,255,255,.07)');
  txt('Claude Code today',x+P,Y+34,15,'#9aa3b2','left','600');
  txt(fit(d.tokens||'0',IW,44,'700'),x+P,Y+96,44,'#fff','left','700');
  txt('tokens',x+P,Y+120,15,'#8b94a6');
  const budget=d.budget||0, used=d.tokensRaw||0;
  if(budget>0){ const pct=Math.min(1,used/budget), col=pct>=0.9?'#f87171':pct>=0.7?'#facc15':'#4ade80';
    rr(x+P,Y+140,IW,10,5,'rgba(255,255,255,.12)'); if(pct>0) rr(x+P,Y+140,Math.max(10,IW*pct),10,5,col);
    txt(fit(Math.round(used/budget*100)+'% of your daily budget',IW,14),x+P,Y+172,14,'#c7cdd8'); }
  else if(d.plan) txt(fit(d.plan,IW,14),x+P,Y+160,14,'#8b94a6');
  const w=d.waiting||0;
  txt(fit(sessions.length+(sessions.length===1?' session':' sessions')+(w?' · '+w+' waiting':''),IW,14,'600'),x+P,Y+H-18,14,w?'#fde047':'#8b94a6','left','600');
  // One tile per session: waiting ones (yellow) first, most recent first.
  if(!shown.length){ txt('No Claude Code session open.',M+W+GAP+P,Y+H/2,20,'#6b7280'); return; }
  const nameSize=Math.min(24,Math.round(W/8.5)), small=Math.min(15,Math.round(W/13));
  shown.forEach((s,i)=>{ x=M+(i+1)*(W+GAP);
    const wait=s.state!=='working';
    rr(x,Y,W,H,14, wait? 'rgba(250,204,21,'+(0.16+0.12*pulse)+')' : 'rgba(255,255,255,.07)');
    if(wait){ g.strokeStyle='rgba(250,204,21,'+(0.55+0.45*pulse)+')'; g.lineWidth=3; g.strokeRect(x+1.5,Y+1.5,W-3,H-3); }
    txt(fit(s.project,IW,nameSize,'700'),x+P,Y+38,nameSize,'#fff','left','700');
    txt(fit(s.state==='question'?'asks a question': wait?'waiting for you':'working…',IW,small,'600'),x+P,Y+64,small, wait?'#fde047':'#8b94a6','left','600');
    const [t1,t2]=two(s.title,IW,small); txt(t1,x+P,Y+98,small,'#c7cdd8'); if(t2) txt(t2,x+P,Y+98+small+6,small,'#c7cdd8');
    const ls=small-1, [l1,l2]=two(s.last,IW,ls); txt(l1,x+P,Y+160,ls,'#8b94a6'); if(l2) txt(l2,x+P,Y+160+ls+6,ls,'#8b94a6');
    txt(ago(s.ago)+' ago',x+P,Y+H-16,13,'#6b7280');
  });
}
