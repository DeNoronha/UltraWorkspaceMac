const POLL=60000;
// NOS Teletekst as on television: each page's 40×25 cells in the eight teletext colours, the mosaic graphics as
// blocks. The strip is wide and low, so the page body (rows 1–23; the header and the fast-text row are left out) is
// split into two columns side by side: rows 1–12 on the left, 13–23 on the right, read like a newspaper. A page that
// is mostly graphics (the weather map) is drawn whole instead, so its picture stays in one piece. On the right the
// page number, subpage, clock and the turn timer. The pages turn by themselves every `interval` seconds; a tap on
// the right half turns to the next page, on the left half to the previous one.
const TT={black:'#000000',red:'#ff0000',green:'#00ff00',yellow:'#ffff00',blue:'#0000ff',magenta:'#ff00ff',cyan:'#00ffff',white:'#ffffff'};
const MONO='"DejaVu Sans Mono","Droid Sans Mono","Roboto Mono",Menlo,Consolas,monospace';
let cur=null, shownAt=Date.now(), lastList='';
const grids=new Map();   // page id → {content, img}
// The page's HTML into 25 rows of 40 cells {c: character or null, m: sextant bits or -1, fg, bg}. Parsed, never
// put into the document; only the text and the colour classes are used.
function parse(content){
  const rows=[]; for(let r=0;r<25;r++){ const row=[]; for(let k=0;k<40;k++) row.push({c:' ',m:-1,fg:'white',bg:'black'}); rows.push(row); }
  const doc=new DOMParser().parseFromString('<div>'+content+'</div>','text/html');
  let r=0, k=0;
  (function walk(n,fg,bg){
    if(n.nodeType===3){ for(const ch of n.nodeValue){
        if(ch==='\n'){ r++; k=0; continue; }
        if(r<25&&k<40){ const cell=rows[r][k], u=ch.codePointAt(0); cell.fg=fg; cell.bg=bg;
          if(u>=0xF020&&u<=0xF07F){ const g1=u-0xF000; if(g1>=0x40&&g1<0x60) cell.c=String.fromCharCode(g1); else { cell.c=null; cell.m=(g1&0x1F)|((g1&0x40)>>1); } }
          else cell.c=ch; }
        k++; } return; }
    if(n.nodeType!==1) return;
    for(const cl of (n.getAttribute&&n.getAttribute('class')||'').split(/\s+/)){
      if(TT[cl]) fg=cl; else if(cl.startsWith('bg-')&&TT[cl.slice(3)]) bg=cl.slice(3); }
    for(const x of n.childNodes) walk(x,fg,bg);
  })(doc.body.firstChild||doc.body,'white','black');
  return rows;
}
// Each page is drawn once into its own canvas (the area left of the strip) and copied every frame.
function image(p){ let x=grids.get(p.id); if(x&&x.content===p.content) return x.img;
  const cells=parse(p.content||''), img=document.createElement('canvas'); img.width=1252; img.height=280;
  const q=img.getContext('2d');
  if(graphic(cells)) draw(q,cells,1,23,392,8,11.5,264/23);   // whole page (body rows) near the TV's cell shape, the picture in one piece
  else { draw(q,cells,1,12,20,8,15,22); draw(q,cells,13,23,644,8,15,22); }
  grids.set(p.id,{content:p.content,img}); return img; }
// Mostly graphics: more mosaic cells than letters in the body.
function graphic(cells){ let m=0,t=0; for(let r=1;r<24;r++) for(const x of cells[r]){ if(x.m>0) m++; else if(x.c&&x.c.trim()) t++; } return m>t; }
// Rows a..b of the page at (x,y) on q, cells w×h. Letters are widened to fill their cell, as a teletext set's are.
function draw(q,cells,a,b,x,y,w,h){
  const fs=Math.round(h*0.86);
  q.font='700 '+fs+'px '+MONO; q.textAlign='center'; q.textBaseline='alphabetic';
  const sx=Math.min(1.6,Math.max(1,(w-1)/q.measureText('M').width));
  for(let r=a;r<=b;r++){ const yy=Math.round(y+(r-a)*h), y1=Math.round(y+(r-a+1)*h);
    for(let k=0;k<40;k++){ const cell=cells[r][k], xx=Math.round(x+k*w), x1=Math.round(x+(k+1)*w);
      if(cell.bg!=='black'){ q.fillStyle=TT[cell.bg]; q.fillRect(xx,yy,x1-xx,y1-yy); }
      q.fillStyle=TT[cell.fg];
      if(cell.m>0){   // contiguous sextants: bits 1,2 top row, 4,8 middle, 16,32 bottom; left then right
        const xm=Math.round(x+(k+0.5)*w), ya=Math.round(yy+(y1-yy)/3), yb=Math.round(yy+2*(y1-yy)/3), ys=[yy,ya,yb,y1];
        for(let s=0;s<6;s++) if(cell.m&(1<<s)){ const col=s&1, row=s>>1; q.fillRect(col?xm:xx,ys[row],col?x1-xm:xm-xx,ys[row+1]-ys[row]); }
      } else if(cell.c&&cell.c.trim()){ q.save(); q.translate((xx+x1)/2,yy+(y1-yy)*0.8); q.scale(sx,1); q.fillText(cell.c,0,0); q.restore(); }
    } }
}
function turn(by){ const ps=(D&&D.pages)||[]; if(!ps.length) return; let i=ps.findIndex(p=>p.id===cur); i=(((i<0?0:i)+by)%ps.length+ps.length)%ps.length; cur=ps[i].id; shownAt=Date.now(); }
c.addEventListener('click',e=>{ const r=c.getBoundingClientRect(); turn((e.clientX-r.left)/r.width<0.5?-1:1); });
function tt(s,x,y,size,col,align){ g.font='700 '+size+'px '+MONO; g.fillStyle=col; g.textAlign=align||'center'; g.textBaseline='alphabetic'; g.fillText(s,x,y); }
function render(d){
  g.fillStyle='#000'; g.fillRect(0,0,1424,280);
  const ps=d.pages||[];
  const ids=ps.map(p=>p.id).join(','); if(ids!==lastList){ lastList=ids; for(const k of [...grids.keys()]) if(!ps.some(p=>p.id===k)) grids.delete(k); }
  if(!ps.length){
    tt('NOS Teletekst',40,70,26,TT.green,'left'); tt(d.error||'Loading…',40,124,24,TT.yellow,'left');
    if((d.missing||[]).length) tt('Not on NOS Teletekst: '+d.missing.join(', '),40,166,20,TT.cyan,'left');
    tt('Pages: Deckhand → Apps → Teletekst',40,232,18,TT.white,'left'); return;
  }
  let i=ps.findIndex(p=>p.id===cur); if(i<0){ i=0; cur=ps[0].id; shownAt=Date.now(); }
  const iv=Math.max(8,d.interval||20)*1000;
  if(Date.now()-shownAt>=iv){ turn(1); i=ps.findIndex(p=>p.id===cur); }
  const p=ps[i]; g.drawImage(image(p),0,0);
  // The strip on the right: page number as in the teletext header, subpage, where it came from, clock, turn timer.
  const X=1342;
  tt('P'+p.page,X,134,34,TT.yellow);
  if(p.subs>1) tt(p.sub+'/'+p.subs,X,162,20,TT.cyan);
  else if(p.from) tt('from '+p.from,X,162,16,TT.cyan);
  const now=new Date(); tt(now.toTimeString().slice(0,8),X,206,22,TT.white);
  tt((i+1)+' of '+ps.length,X,240,16,TT.green);
  const f=Math.min(1,(Date.now()-shownAt)/iv); g.fillStyle='#202020'; g.fillRect(X-60,256,120,6); g.fillStyle=TT.blue; g.fillRect(X-60,256,Math.round(120*f),6);
}
