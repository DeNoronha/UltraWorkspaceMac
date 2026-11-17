const POLL=30000;
// Chess: on the left the player and their ratings (tap one for its chart), recent results and the puzzle chip; in the
// middle the board of the game in focus with the last move and a check marked (tap it for the next game); on the right
// that game: whose move, the time left or how it ended, the last moves and the material, then the games list and the
// rating chart. Puzzle mode: tap a piece and then its square; the answer is checked against the day's solution.
const GREEN='#4ade80', RED='#f87171', AMBER='#fbbf24', GREY='#8b94a6', DIM='#5b6475', BLUE='#93c5fd';
const LIGHT='#ebd7b5', DARK='#b0855c';
const BX=318, BY=16, S=31;                               // the board: 8 × 31 = 248 px
const R0=588, RW=816;                                    // the right panel

let focus=null, chartCls=null, mode='games', listPage=0, lastDraw=0, lastD=null;
let hits=[];                                             // tappable areas of the last drawing
let P=null;                                              // the puzzle being solved

function font(size,weight){ g.font=(weight||'400')+' '+size+'px -apple-system,Roboto,Helvetica,Arial,sans-serif'; }
function width(s,size,weight){ font(size,weight); return g.measureText(s).width; }
function fit(s,w,size,weight){ font(size,weight); s=s||''; if(g.measureText(s).width<=w) return s;
  let lo=0, hi=s.length; while(lo<hi){ const m=(lo+hi+1)>>1; if(g.measureText(s.slice(0,m)+'…').width<=w) lo=m; else hi=m-1; } return s.slice(0,lo).trimEnd()+'…'; }
function nowS(){ return Date.now()/1000; }
function since(s){ s=Math.max(0,Math.round(s)); return s<172800? ago(s)+' ago' : Math.round(s/86400)+' days ago'; }
function left(s){ if(s<=0) return "time's up"; const d=Math.floor(s/86400), h=Math.floor(s%86400/3600), m=Math.floor(s%3600/60);
  return d? d+' d '+h+' h left' : h? h+' h '+m+' min left' : m+' min left'; }
function hit(x,y,w,h,fn){ hits.push({x,y,w,h,fn}); }
function chip(label,x,y,col,fn,strong){ const w=width(label,14,'600')+24; rr(x,y,w,30,15,strong?col:'rgba(255,255,255,.12)');
  txt(label,x+w/2,y+20,14,strong?'#111':(col||'#fff'),'center','600'); hit(x-4,y-6,w+8,42,fn); return w; }

// --- pieces: drawn shapes in a 100 × 100 box, each part filled and outlined in turn
const SHAPES={
  p:['M22 80h56v9a3 3 0 0 1-3 3H25a3 3 0 0 1-3-3z','M40 52C40 66 31 71 29 80h42c-2-9-11-14-11-28z','M35 44h30l-5 9H40z','C50 30 13'],
  r:['M20 82h60v10H20z','M30 48h40l4 34H26z','M26 40h48v8H26z','M24 40V16h12v8h8v-8h12v8h8v-8h12v24z'],
  n:['M24 82h52v10H24z','M30 82c0-14 9-21 14-30-8 2-15 6-20 10-6-4-7-10-2-16 6-12 12-20 18-26l-2-10 8 6 6-6 2 8c14 4 24 20 22 42-1 10-4 16-4 22z','E42 31 3'],
  b:['M24 84h52v8H24z','M32 76h36l-4 8H36z','M34 66h32v9H34z','M50 20C30 36 30 54 38 66h24c8-12 8-30-12-46z','C50 14 6','L55 33 45 49'],
  q:['M22 84h56v8H22z','M30 84l-8-50 7 24 7-30 7 28 7-32 7 32 7-28 7 30 7-24-8 50z','C22 31 5','C36 25 5','C50 21 5','C64 25 5','C78 31 5','L31 73 69 73'],
  k:['M22 84h56v8H22z','M44 36h12l2 14H42z','M30 84c-12-18-8-36 10-36 6 0 8 4 10 8 2-4 4-8 10-8 18 0 22 18 10 36z','M46 6h8v8h8v8h-8v14h-8V22h-8v-8h8z','L32 74 68 74']};
const PATHS={};
function shape(s){ if(PATHS[s]) return PATHS[s]; let p;
  if(s[0]==='C'||s[0]==='E'){ const [x,y,r]=s.slice(1).trim().split(/\s+/).map(Number); p=new Path2D(); p.arc(x,y,r,0,7); }
  else if(s[0]==='L'){ const n=s.slice(1).trim().split(/\s+/).map(Number); p=new Path2D(); p.moveTo(n[0],n[1]); p.lineTo(n[2],n[3]); }
  else p=new Path2D(s);
  return PATHS[s]=p; }
function piece(ch,x,y,size){
  const white=ch===ch.toUpperCase(), parts=SHAPES[ch.toLowerCase()]; if(!parts) return;
  g.save(); g.translate(x,y); g.scale(size/100,size/100); g.lineJoin='round'; g.lineCap='round';
  for(const s of parts){ const p=shape(s);
    if(s[0]==='L'){ g.strokeStyle=white?'#1a1a1a':'#e5e7eb'; g.lineWidth=4; g.stroke(p); continue; }
    if(s[0]==='E'){ g.fillStyle=white?'#1a1a1a':'#e5e7eb'; g.fill(p); continue; }
    g.fillStyle=white?'#fafafa':'#262626'; g.fill(p); g.strokeStyle=white?'#1a1a1a':'#000'; g.lineWidth=white?4.5:4; g.stroke(p); }
  g.restore(); }

function parse(fen){ const b=new Array(64).fill(null); (fen||'').split(' ')[0].split('/').forEach((row,i)=>{ let f=0;
  for(const ch of row){ if(ch>='1'&&ch<='8') f+=+ch; else { b[(7-i)*8+f]=ch; f++; } } }); return b; }
function sqXY(sq,flip){ const f=sq%8, r=Math.floor(sq/8); return [BX+(flip?7-f:f)*S, BY+(flip?r:7-r)*S]; }
function sqAt(x,y,flip){ if(x<BX||x>=BX+8*S||y<BY||y>=BY+8*S) return null; const c=Math.floor((x-BX)/S), r=Math.floor((y-BY)/S);
  return (flip? r : 7-r)*8 + (flip? 7-c : c); }

function board(fen,flip,o){ o=o||{}; const b=parse(fen);
  rr(BX-4,BY-4,8*S+8,8*S+8,8,'#11141a');
  for(let sq=0;sq<64;sq++){ const [x,y]=sqXY(sq,flip), light=(sq%8+Math.floor(sq/8))%2===1;
    g.fillStyle=light?LIGHT:DARK; g.fillRect(x,y,S,S);
    if(o.last&&o.last.includes(sq)){ g.fillStyle='rgba(250,204,21,.45)'; g.fillRect(x,y,S,S); }
    if(o.sel===sq){ g.fillStyle='rgba(56,189,248,.55)'; g.fillRect(x,y,S,S); }
    if(o.wrong===sq){ g.fillStyle='rgba(239,68,68,.6)'; g.fillRect(x,y,S,S); } }
  if(o.check){ const k=b.indexOf(o.check); if(k>=0){ const [x,y]=sqXY(k,flip), gr=g.createRadialGradient(x+S/2,y+S/2,2,x+S/2,y+S/2,S*0.7);
    gr.addColorStop(0,'rgba(239,68,68,.95)'); gr.addColorStop(1,'rgba(239,68,68,0)'); g.fillStyle=gr; g.fillRect(x,y,S,S); } }
  // Coordinates in the corner squares, in the other square colour.
  for(let i=0;i<8;i++){ const fl=flip?7-i:i, rk=flip?i+1:8-i;
    txt('abcdefgh'[fl],BX+i*S+S-3,BY+8*S-3,9,(i%2===0)?LIGHT:DARK,'right','700');
    txt(String(rk),BX+2,BY+i*S+10,9,(i%2===0)?DARK:LIGHT,'left','700'); }
  for(let sq=0;sq<64;sq++) if(b[sq]){ const [x,y]=sqXY(sq,flip); piece(b[sq],x+S*0.05,y+S*0.05,S*0.9); }
}

// The pieces one side lost, small, with the material difference after them.
function captured(lost,x,y,diff,draw){ let cx=x; for(const ch of lost||''){ if(draw!==false) piece(ch,cx,y-19,24); cx+=14; } if(diff>0){ if(draw!==false) txt('+'+diff,cx+12,y,15,GREY,'left','600'); cx+=width('+'+diff,15,'600')+12; } return cx-x+10; }

function render(d){
  hits=[];
  if(!d.hasUser){ txt('Add your Chess.com username under Apps → Chess in Deckhand.',712,150,22,GREY,'center'); return; }
  if(!d.ratings&&!d.games){ txt(d.error||'Reading Chess.com…',712,150,20,d.error?'#f59e0b':GREY,'center'); return; }
  renderLeft(d);
  if(mode==='puzzle'&&d.puzzle){ renderPuzzle(d); return; }
  mode='games';
  const games=d.games||[];
  let G=games.find(x=>x.id===focus); if(!G){ G=games[0]; focus=G&&G.id; }
  if(!G){ board('rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR',false,{});
    txt('No daily games and no games in the last two months.',R0,48,20,GREY); renderChart(d,R0,124,RW); return; }
  const flip=G.you==='b';
  board(G.fen,flip,{last:G.last,check:G.check?(G.toMove==='w'?'K':'k'):null});
  hit(BX,BY,8*S,8*S,()=>{ const i=games.findIndex(x=>x.id===focus); focus=games[(i+1)%games.length].id; });
  renderGame(G);
  renderList(games,R0,124,404);
  renderChart(d,R0+428,124,RW-428);
}

function renderLeft(d){
  const p=d.profile||{}, rs=d.ratings||[];
  let x=20; if(p.title){ const w=width(p.title,13,'700')+12; rr(x,16,w,24,6,'#b91c1c'); txt(p.title,x+w/2,33,13,'#fff','center','700'); x+=w+8; }
  txt(fit(p.name||d.user,280-x,20,'700'),x,35,20,'#fff','left','700');
  const cls=chartCls||d.main, main=rs.find(r=>r.id===cls)||rs[0];
  if(main){ txt(main.label.toUpperCase(),20,64,13,GREY,'left','600');
    txt(String(main.rating),20,108,46,'#fff','left','700');
    const dx=20+width(String(main.rating),46,'700')+12;
    if(main.delta){ txt((main.delta>0?'▲ ':'▼ ')+Math.abs(main.delta),dx,88,16,main.delta>0?GREEN:RED,'left','700'); txt('this month',dx,107,13,GREY); }
    else if(main.best) { txt('best '+main.best,dx,107,13,GREY); }
    if(main.w!=null) txt(main.w+' W · '+main.d+' D · '+main.l+' L',20,132,13,GREY);
    hit(10,44,290,96,()=>{ const i=rs.indexOf(main); chartCls=rs[(i+1)%rs.length].id; }); }
  // The other ratings as chips: tap one for its chart.
  let cx=20; rs.filter(r=>r!==main).forEach(r=>{ const label=r.label+' '+r.rating, w=width(label,13,'600')+18; if(cx+w>300) return;
    rr(cx,146,w,26,13,'rgba(255,255,255,.1)'); txt(label,cx+w/2,164,13,'#d4d8e0','center','600'); hit(cx-3,140,w+6,38,()=>{ chartCls=r.id; }); cx+=w+6; });
  // Recent results, newest first.
  (d.recent||[]).forEach((o,i)=>{ const x=20+i*27, col=o==='win'?GREEN:o==='loss'?RED:GREY; rr(x,186,23,23,5,col);
    txt(o==='win'?'W':o==='loss'?'L':'D',x+11.5,202,12,'#111','center','700'); });
  if(!(d.recent||[]).length) txt('No finished games lately.',20,202,13,DIM);
  if(d.puzzle) chip(mode==='puzzle'?'Back to games':'Puzzle of the day',20,232,mode==='puzzle'?'#fff':BLUE,()=>{ mode=mode==='puzzle'?'games':'puzzle'; if(mode==='puzzle') startPuzzle(d.puzzle,false); });
  else if(d.puzzleBest) txt('Puzzles best '+d.puzzleBest,20,252,13,GREY);
  if(d.error) txt(fit(d.error,270,12),20,276,12,'#f59e0b');
}

function renderGame(G){
  const you=G.you, opp=G.opp+(G.oppRating?' ('+G.oppRating+')':'');
  let head, col;
  if(G.kind==='daily'){ head=G.turn?'Your move':'Their move'; col=G.turn?AMBER:'#d4d8e0'; }
  else { head=G.result==='win'?'You won':G.result==='loss'?'You lost':'Draw'; col=G.result==='win'?GREEN:G.result==='loss'?RED:'#d4d8e0'; }
  txt(head,R0,42,24,col,'left','700'); const hw=width(head,24,'700');
  txt(fit(' vs '+opp,RW-hw-150,20),R0+hw,42,20,'#e5e7eb');
  // Right: the side you play and the material.
  const youLost=you==='w'?(G.lost||{}).w:(G.lost||{}).b, theyLost=you==='w'?(G.lost||{}).b:(G.lost||{}).w;
  const myDiff=(you==='w'?1:-1)*(G.diff||0);
  const cw=captured(theyLost,0,0,myDiff,false); captured(theyLost,R0+RW-cw,40,myDiff);
  const meta=[];
  if(G.kind==='daily'){ meta.push(G.tc+' per move'); if(G.moveBy) meta.push(left(G.moveBy-nowS())); }
  else { meta.push(G.tc+' '+G.cls); if(G.how) meta.push('by '+G.how); if(G.ended) meta.push(since(nowS()-G.ended)); }
  if(G.opening) meta.push(G.opening);
  const urgent=G.kind==='daily'&&G.turn&&G.moveBy&&G.moveBy-nowS()<12*3600;
  txt(fit(meta.join(' · '),RW,15),R0,70,15,urgent?(G.moveBy-nowS()<2*3600?RED:AMBER):GREY);
  // The last moves, the newest in white.
  const mv=G.moves||[]; let x=R0;
  mv.forEach((m,i)=>{ const last=i===mv.length-1, w=width(m+'  ',17,last?'700':'400'); if(x+w>R0+RW-200) return; txt(m,x,102,17,last?'#fff':'#9aa3b2','left',last?'700':'400'); x+=w; });
  if(!mv.length) txt(G.ply===0?'No moves yet.':'',R0,102,17,GREY);
  if(G.acc) txt('accuracy '+G.acc[0]+' vs '+G.acc[1],R0+RW,102,15,GREY,'right');
  else if(G.kind==='daily') txt('you play '+(you==='w'?'white':'black'),R0+RW,102,15,GREY,'right');
  g.fillStyle='rgba(255,255,255,.08)'; g.fillRect(R0,114,RW,1);
}

function renderList(games,x0,y0,w){
  const per=4, pages=Math.max(1,Math.ceil(games.length/per)); if(listPage>=pages) listPage=0;
  txt('GAMES',x0,y0+16,13,GREY,'left','600');
  if(pages>1) chip((listPage+1)+'/'+pages+' ›',x0+w-62,y0-2,'#fff',()=>{ listPage=(listPage+1)%pages; });
  games.slice(listPage*per,listPage*per+per).forEach((G,i)=>{ const y=y0+26+i*30, on=G.id===focus;
    if(on) rr(x0-6,y,w+6,28,8,'rgba(255,255,255,.08)');
    const col=G.kind==='daily'?(G.turn?AMBER:GREY):G.result==='win'?GREEN:G.result==='loss'?RED:GREY;
    g.fillStyle=col; g.beginPath(); g.arc(x0+6,y+14,5,0,7); g.fill();
    const right=G.kind==='daily'? (G.turn?(G.moveBy?left(G.moveBy-nowS()).replace(' left',''):'your move'):'their move')
                               : (G.result==='win'?'won':G.result==='loss'?'lost':'draw')+' · '+G.cls+' · '+(G.ended?ago(Math.max(0,Math.round(nowS()-G.ended))):'');
    const rw=width(right,13); txt(right,x0+w-4,y+19,13,G.kind==='daily'&&G.turn?AMBER:GREY,'right');
    txt(fit(G.opp+(G.oppRating?' '+G.oppRating:''),w-rw-34,15,on?'700':'400'),x0+18,y+19,15,on?'#fff':'#d4d8e0','left',on?'700':'400');
    hit(x0-6,y,w+6,28,()=>{ focus=G.id; });
  });
}

function renderChart(d,x0,y0,w){
  const rs=d.ratings||[], cls=chartCls||d.main, r=rs.find(o=>o.id===cls);
  const xs=((d.history||{})[cls]||[]);
  txt(((r&&r.label)||cls||'').toUpperCase()+' · LAST '+xs.length+' GAMES',x0,y0+16,13,GREY,'left','600');
  if(xs.length<2){ txt('Not enough rated games yet.',x0,y0+70,15,DIM); return; }
  const lo=Math.min(...xs), hi=Math.max(...xs), pad=Math.max(8,(hi-lo)*0.12), a=lo-pad, b=hi+pad;
  const top=y0+30, h=110, X=i=>x0+i*(w-44)/(xs.length-1), Y=v=>top+h-(v-a)/(b-a)*h;
  g.beginPath(); xs.forEach((v,i)=>i?g.lineTo(X(i),Y(v)):g.moveTo(X(i),Y(v)));
  g.lineTo(X(xs.length-1),top+h); g.lineTo(X(0),top+h); g.closePath();
  const gr=g.createLinearGradient(0,top,0,top+h); gr.addColorStop(0,'rgba(147,197,253,.35)'); gr.addColorStop(1,'rgba(147,197,253,0)'); g.fillStyle=gr; g.fill();
  g.strokeStyle=BLUE; g.lineWidth=2; g.lineJoin='round'; g.beginPath(); xs.forEach((v,i)=>i?g.lineTo(X(i),Y(v)):g.moveTo(X(i),Y(v))); g.stroke();
  const lx=X(xs.length-1), ly=Y(xs[xs.length-1]); g.fillStyle='#fff'; g.beginPath(); g.arc(lx,ly,4,0,7); g.fill();
  txt(String(hi),x0+w,top+10,12,GREY,'right'); txt(String(lo),x0+w,top+h,12,GREY,'right');
  hit(x0,y0,w,150,()=>{ const i=rs.indexOf(r); if(rs.length) chartCls=rs[(i+1)%rs.length].id; });
}

// --- the puzzle of the day
function startPuzzle(pz,keep){ if(keep&&P&&P.fen0===pz.fen) return; P={fen0:pz.fen,fen:pz.fen,step:0,sel:null,last:null,wrong:null,wrongAt:0,msg:'',done:false,check:false}; }
function renderPuzzle(d){
  const pz=d.puzzle; if(!P||P.fen0!==pz.fen) startPuzzle(pz);
  const flip=pz.toMove==='b', mover=pz.toMove;
  const wrong=Date.now()-P.wrongAt<900?P.wrong:null;
  board(P.fen,flip,{last:P.last,sel:P.sel,wrong,check:P.check?((P.step%2===0)===(mover==='w')?'K':'k'):null});
  hit(BX,BY,8*S,8*S,null);                                // handled in tapBoard
  txt('PUZZLE OF THE DAY',R0,30,13,GREY,'left','600');
  txt(fit(pz.title,RW,26,'700'),R0,64,26,'#fff','left','700');
  const total=Math.ceil(pz.steps.length/2), mine=Math.ceil(P.step/2);
  const say=P.done?'Solved!':P.msg||((mover==='w'?'White':'Black')+' to move. Tap a piece, then its square.');
  txt(say,R0,100,18,P.done?GREEN:P.msg.startsWith('Not')?RED:P.msg?GREEN:'#e5e7eb','left','600');
  for(let i=0;i<total;i++){ g.fillStyle=i<mine?GREEN:'rgba(255,255,255,.18)'; g.beginPath(); g.arc(R0+8+i*22,130,7,0,7); g.fill(); }
  txt(total+(total===1?' move':' moves')+' to find',R0+8+total*22+6,135,14,GREY);
  // The moves played so far.
  const played=pz.steps.slice(0,P.step).map(s=>s.san).join('  '); if(played) txt(fit(played,RW,17,'600'),R0,170,17,'#d4d8e0','left','600');
  let x=R0;
  if(!P.done) x+=chip('Show the next move',x,226,'#fff',()=>{ playStep(pz,true); })+10;
  x+=chip('Start over',x,226,'#fff',()=>{ startPuzzle(pz); })+10;
  chip('Back to games',x,226,'#fff',()=>{ mode='games'; });
}
function playStep(pz,auto){ const s=pz.steps[P.step]; if(!s) return;
  P.fen=s.fen; P.last=[s.from,s.to]; P.check=!!s.check; P.step++; P.sel=null; P.msg=auto?'':'Correct!';
  if(P.step>=pz.steps.length){ P.done=true; return; }
  // The other side's answer, after a moment.
  if(P.step%2===1) setTimeout(()=>{ if(mode!=='puzzle'||!P) return; const r=pz.steps[P.step]; if(!r) return;
    P.fen=r.fen; P.last=[r.from,r.to]; P.check=!!r.check; P.step++; if(P.step>=pz.steps.length) P.done=true; else if(P.msg) P.msg='Correct! Now the next move.'; redraw(); },700);
}
function tapBoard(x,y,d){
  const pz=d.puzzle; if(!pz||!P||P.done) return; const flip=pz.toMove==='b', sq=sqAt(x,y,flip); if(sq==null||P.step%2===1) return;
  const b=parse(P.fen), mine=ch=>ch&&((ch===ch.toUpperCase())===(pz.toMove==='w'));
  if(P.sel==null||mine(b[sq])&&sq!==P.sel){ if(mine(b[sq])){ P.sel=sq; P.msg=''; } return; }
  if(sq===P.sel){ P.sel=null; return; }
  const want=pz.steps[P.step];
  if(want&&want.from===P.sel&&want.to===sq) playStep(pz,false);
  else { P.wrong=sq; P.wrongAt=Date.now(); P.sel=null; P.msg='Not the move. Try again.'; setTimeout(redraw,950); }
}

// Redrawn on new data and taps, and every 20 s for the clocks. The shell's frame() would redraw 60 times a second.
function redraw(){ if(D){ lastD=D; lastDraw=Date.now(); bg(); render(D); } }
function frame(){ if(D&&(D!==lastD||Date.now()-lastDraw>=20000)) redraw(); setTimeout(frame,250); }

c.addEventListener('click',ev=>{
  const r=c.getBoundingClientRect(), x=(ev.clientX-r.left)*1424/r.width, y=(ev.clientY-r.top)*280/r.height;
  if(mode==='puzzle'&&D&&D.puzzle&&x>=BX&&x<BX+8*S&&y>=BY&&y<BY+8*S) tapBoard(x,y,D);
  else { const h=hits.slice().reverse().find(o=>x>=o.x&&x<=o.x+o.w&&y>=o.y&&y<=o.y+o.h); if(h&&h.fn) h.fn(); }
  redraw();
});
