const POLL=20000;
// Jira Board: on the left the board, how many cards are open and how many are yours; on the right its columns, each
// with its count and top three cards, yours marked in blue. The last column (Done, usually) is dimmed. Tap a column to
// see up to eight of its cards across the width (tap again, or wait a minute, to go back); with more than six
// columns the arrow chip pages through them.
const BLUE='#60a5fa', GREY='#8b94a6', DIM='#5b6475', RED='#f87171', AMBER='#fbbf24';
const X0=270, X1=1404, GAP=8, PER=6;
const TYPE={bug:'#e5493a',story:'#63ba3c',task:'#4bade8',subtask:'#4bade8','sub-task':'#4bade8',epic:'#904ee2'};
let page=0, open=null, openUntil=0, hits=[], chip=null, lastDraw=0, lastD=null;

function font(size,weight){ g.font=(weight||'400')+' '+size+'px -apple-system,Roboto,Helvetica,Arial,sans-serif'; }
function width(s,size,weight){ font(size,weight); return g.measureText(s).width; }
// The text cut with an ellipsis so it fits in w pixels at this size and weight.
function fit(s,w,size,weight){ font(size,weight); s=s||''; if(g.measureText(s).width<=w) return s;
  let lo=0, hi=s.length; while(lo<hi){ const m=(lo+hi+1)>>1; if(g.measureText(s.slice(0,m)+'…').width<=w) lo=m; else hi=m-1; } return s.slice(0,lo).trimEnd()+'…'; }
// Up to n lines of at most w pixels; the last one ends in an ellipsis when the text goes on.
function wrap(s,w,size,n){ font(size); const words=(s||'').split(/\s+/).filter(Boolean), lines=[]; let cur='';
  for(let i=0;i<words.length;i++){ const t=cur?cur+' '+words[i]:words[i];
    if(!cur||g.measureText(t).width<=w){ cur=t; continue; }
    if(lines.length===n-1){ lines.push(fit(cur+' '+words.slice(i).join(' '),w,size)); return lines; }
    lines.push(fit(cur,w,size)); cur=words[i]; }
  if(cur) lines.push(fit(cur,w,size)); return lines; }

function tri(x,y,col){ g.fillStyle=col; g.beginPath(); g.moveTo(x,y-9); g.lineTo(x+5.5,y); g.lineTo(x-5.5,y); g.closePath(); g.fill(); }

function card(cd,x,y,w,h,lines){
  rr(x,y,w,h,12,cd.mine?'rgba(96,165,250,.16)':'rgba(255,255,255,.07)');
  if(cd.mine){ g.fillStyle=BLUE; g.fillRect(x,y+10,3,h-20); }
  let kx=x+12; const tc=TYPE[(cd.type||'').toLowerCase()];
  if(tc){ rr(kx,y+9,10,10,2.5,tc); kx+=16; }
  txt(cd.key||'',kx,y+19,13,GREY,'left','600'); kx+=width(cd.key||'',13,'600')+9;
  const p=(cd.prio||'').toLowerCase(); if(p==='highest'||p==='blocker') tri(kx,y+19,RED); else if(p==='high'||p==='critical') tri(kx,y+19,AMBER);
  if(cd.who){ g.fillStyle=cd.mine?BLUE:'#475066'; g.beginPath(); g.arc(x+w-19,y+14,10.5,0,7); g.fill();
    txt(cd.who,x+w-19,y+18.5,11,cd.mine?'#0b1220':'#fff','center','700'); }
  wrap(cd.summary,w-24,15,lines).forEach((l,i)=>txt(l,x+12,y+39+i*19,15,'#fff'));
}

function header(col,x,y,w){
  const n=String(col.count), pw=width(n,13,'700')+14;
  const name=fit(col.name,w-pw-12,16,'700'); txt(name,x+2,y,16,'#fff','left','700');
  const px=x+2+width(name,16,'700')+8; rr(px,y-15,pw,20,10,col.mine?'rgba(96,165,250,.28)':'rgba(255,255,255,.12)');
  txt(n,px+pw/2,y,13,col.mine?'#dbeafe':'#fff','center','700');
}

function render(d){
  hits=[]; chip=null;
  if(!d.hasToken||!d.hasSite){ txt('Add your Atlassian site and API token under Apps → Jira Board in Deckhand.',712,148,22,GREY,'center'); return; }
  if(!d.hasBoard){ txt('Choose a board under Apps → Jira Board.',712,148,22,GREY,'center'); return; }
  if(!d.columns){ txt(fit(d.error||'Reading your board…',1300,20),712,148,20,d.error?AMBER:GREY,'center'); return; }
  const cols=d.columns, work=cols.filter(c=>!c.done);
  const total=work.reduce((a,c)=>a+c.count,0), mine=work.reduce((a,c)=>a+c.mine,0);
  // --- left: the board
  txt(d.onlyMine?'JIRA · ONLY MINE':'JIRA',20,32,14,GREY,'left','600');
  txt(fit(clip((d.board&&d.board.name)||'Board',18),230,22,'700'),20,62,22,'#fff','left','700');
  txt(total+' open',20,116,30,'#fff','left','700');
  if(!d.onlyMine) txt(mine+' yours',20,146,18,mine?BLUE:DIM,'left','600');
  if(d.updated){ const s=Math.max(0,Math.round(Date.now()/1000-d.updated)); txt(s<60?'Updated just now':'Updated '+ago(s)+' ago',20,d.error?184:200,14,GREY); }
  if(d.error) txt(fit(d.error,230,13),20,204,13,AMBER);

  const pages=Math.max(1,Math.ceil(cols.length/PER)); if(page>=pages) page=0;
  if(pages>1){ const label=(page+1)+'/'+pages+'  ›'; const w=width(label,15,'700')+22, x=250-w;
    rr(x,224,w,32,16,'rgba(255,255,255,.12)'); txt(label,x+w/2,245,15,'#fff','center','700'); chip={x,w}; }

  const shown=open!==null&&Date.now()<openUntil? cols.find(c=>c.name===open) : null;
  if(shown){ renderOpen(shown); return; }
  open=null;
  if(!cols.length){ txt('This board has no columns.',(X0+X1)/2,148,20,GREY,'center'); return; }
  const vis=cols.slice(page*PER,page*PER+PER), n=vis.length, w=(X1-X0-GAP*(n-1))/n;
  vis.forEach((col,i)=>{ const x=X0+i*(w+GAP); hits.push({x,w,name:col.name});
    if(col.done) g.globalAlpha=0.5;
    header(col,x,30,w);
    const max=col.done?2:3, list=(col.cards||[]).slice(0,max);
    list.forEach((cd,j)=>card(cd,x,44+j*70,w,64,2));
    if(!list.length) txt(d.onlyMine?'None of yours':'No cards',x+4,70,14,DIM);
    const more=col.count-list.length; if(more>0) txt('+'+more+' more',x+4,col.done&&list.length<3?44+list.length*70+16:268,13,GREY);
    g.globalAlpha=1; });
}

// One column across the whole right part: up to eight cards in two rows of four.
function renderOpen(col){
  const n=String(col.count)+(col.count===1?' card':' cards')+(col.mine?' · '+col.mine+' yours':'');
  txt(fit(col.name,600,18,'700'),X0+2,30,18,'#fff','left','700');
  txt(n,X0+2+width(fit(col.name,600,18,'700'),18,'700')+14,30,15,col.mine?BLUE:GREY,'left','600');
  txt('Tap to go back',X1,30,13,DIM,'right');
  const w=(X1-X0-GAP*3)/4, list=(col.cards||[]).slice(0,8);
  if(col.done) g.globalAlpha=0.6;
  list.forEach((cd,i)=>card(cd,X0+(i%4)*(w+GAP),44+Math.floor(i/4)*114,w,106,3));
  g.globalAlpha=1;
  if(!list.length) txt('No cards in this column.',(X0+X1)/2,150,18,GREY,'center');
}

// Redrawn once a second at most (the "updated" text, the open column's minute), and at once on new data or a tap.
// The shell's frame() would redraw 60 times a second.
const STEP=1000;
function frame(){ const t=Date.now(); if(D&&(D!==lastD||t-lastDraw>=STEP-20)){ lastD=D; lastDraw=t; bg(); render(D); } setTimeout(frame,STEP); }

c.addEventListener('click',ev=>{
  const r=c.getBoundingClientRect(), x=(ev.clientX-r.left)*1424/r.width, y=(ev.clientY-r.top)*280/r.height;
  if(chip&&x>=chip.x-8&&x<=chip.x+chip.w+8&&y>=214&&y<=266){ page++; open=null; }
  else if(open!==null){ open=null; }
  else { const h=hits.find(o=>x>=o.x&&x<o.x+o.w); if(h){ open=h.name; openUntil=Date.now()+60000; } }
  if(D){ lastD=D; lastDraw=Date.now(); bg(); render(D); }
});
