const POLL=60000;
// SEO: Lighthouse scores and Core Web Vitals on the left (tap to switch mobile / desktop), Search Console in the middle,
// the top search terms and the page check on the right. Everything comes from Deckhand (/seo/data.json).
let strat='mobile';
function scoreCol(s){ return s>=90?'#22c55e':s>=50?'#f59e0b':'#ef4444'; }
function catCol(c){ return c==='fast'?'#22c55e':c==='average'?'#f59e0b':c==='slow'?'#ef4444':'#cbd5e1'; }
function num(n){ return n>=10000? Math.round(n/1000)+'k' : n>=1000? (n/1000).toFixed(1)+'k' : String(n); }
function ring(cx,cy,r,score,label){
  g.lineWidth=8; g.strokeStyle='rgba(255,255,255,.1)'; g.beginPath(); g.arc(cx,cy,r,0,7); g.stroke();
  if(score!=null){ g.strokeStyle=scoreCol(score); g.lineCap='round'; g.beginPath(); g.arc(cx,cy,r,-Math.PI/2,-Math.PI/2+2*Math.PI*score/100); g.stroke(); g.lineCap='butt'; }
  txt(score==null?'—':String(score),cx,cy+10,28,score==null?'#8b94a6':'#fff','center','700');
  txt(label,cx,cy+r+26,14,'#8b94a6','center','600');
}
function delta(now,prev,lowerIsBetter,fmt){
  if(!prev) return null; const d=now-prev; if(Math.abs(d)<1e-9) return {t:'±0',c:'#8b94a6'};
  const good= lowerIsBetter? d<0 : d>0; const pct= prev? Math.abs(d)/prev*100 : 0;
  return {t:(d>0?'▲ ':'▼ ')+(fmt? fmt(Math.abs(d)) : (pct>=10? Math.round(pct):pct.toFixed(1))+'%'), c: good?'#22c55e':'#ef4444'};
}
function stat(x,y,label,value,dl){
  txt(label,x,y,14,'#8b94a6','left','600'); txt(value,x,y+34,30,'#fff','left','700');
  if(dl) txt(dl.t,x,y+56,14,dl.c,'left','600');
}
function render(d){
  if(!d.url){ txt('Set your website under Apps → SEO in Deckhand.',712,150,22,'#8b94a6','center'); return; }
  // --- left: Lighthouse
  txt(clip(d.host,30),20,32,20,'#fff','left','700');
  const p=d.psi&&d.psi[strat];
  rr(310,14,120,28,14,'rgba(255,255,255,.1)'); txt(strat==='mobile'?'Mobile':'Desktop',370,34,15,'#e5e7eb','center','600');
  const labels=[['performance','Performance'],['seo','SEO'],['accessibility','Access.'],['bestPractices','Best pract.']];
  labels.forEach((l,i)=>ring(62+i*104,112,38,p?p[l[0]]:null,l[1]));
  if(p){
    const f=p.field, lab=p.lab||{}; let parts;
    if(f){ parts=[['LCP',f.lcp&&(f.lcp.p75/1000).toFixed(1)+' s',f.lcp&&f.lcp.cat],['INP',f.inp&&Math.round(f.inp.p75)+' ms',f.inp&&f.inp.cat],['CLS',f.cls&&f.cls.p75.toFixed(2),f.cls&&f.cls.cat]]; }
    else parts=[['LCP',lab.lcp!=null&&(lab.lcp/1000).toFixed(1)+' s',null],['TBT',lab.tbt!=null&&lab.tbt+' ms',null],['CLS',lab.cls!=null&&lab.cls.toFixed(2),null]];
    let x=20; parts.forEach(q=>{ if(!q[1]) return; txt(q[0],x,232,14,'#8b94a6','left','600'); x+=36; txt(q[1],x,232,17,catCol(q[2]),'left','700'); x+=86; });
    txt(f?'Core Web Vitals of real visitors (28 days)':'Lab timings · no field data from Chrome yet',20,258,13,'#8b94a6');
  } else { const m=(d.errors&&d.errors.find(e=>e.indexOf('PageSpeed')>=0)||'Waiting for PageSpeed Insights…').replace('PageSpeed Insights: ','PageSpeed: ').split('. ');
    m.slice(0,2).forEach((l,i)=>txt(clip(l+(i<m.length-1?'.':''),54),20,232+i*22,14,'#8b94a6')); }

  // --- middle: Search Console
  const X=460, gs=d.gsc;
  g.fillStyle='rgba(255,255,255,.08)'; g.fillRect(X-16,16,1,248);
  txt('SEARCH CONSOLE · 28 DAYS',X,32,14,'#8b94a6','left','600');
  if(!gs){
    const msg=!d.gscClient?'Add your Google client under Apps → SEO.':!d.gscConnected?'Connect Google under Apps → SEO.':(d.errors||[]).find(e=>/Search Console|Google/.test(e))||'Reading Search Console…';
    txt(clip(msg,48),X,140,17,'#8b94a6');
  } else {
    const pv=gs.prev||{};
    stat(X,62,'Clicks',num(gs.clicks),delta(gs.clicks,pv.clicks,false));
    stat(X+120,62,'Impressions',num(gs.impressions),delta(gs.impressions,pv.impressions,false));
    stat(X+262,62,'CTR',gs.ctr.toFixed(1)+'%',delta(gs.ctr,pv.ctr,false,v=>v.toFixed(1)+' pt'));
    stat(X+360,62,'Position',gs.position?gs.position.toFixed(1):'—',gs.position&&pv.position?delta(gs.position,pv.position,true,v=>v.toFixed(1)):null);
    // daily clicks (bars) and impressions (line)
    const days=gs.days||[], cx=X, cy=150, cw=460, ch=96;
    if(days.length){
      const mc=Math.max(1,...days.map(q=>q.c)), mi=Math.max(1,...days.map(q=>q.i)), bw=cw/days.length;
      g.fillStyle='rgba(96,165,250,.75)'; days.forEach((q,i)=>{ const h=Math.max(1,q.c/mc*ch); g.fillRect(cx+i*bw+1,cy+ch-h,Math.max(1,bw-2),h); });
      g.strokeStyle='#a78bfa'; g.lineWidth=2; g.beginPath(); days.forEach((q,i)=>{ const x=cx+i*bw+bw/2, y=cy+ch-q.i/mi*ch; i?g.lineTo(x,y):g.moveTo(x,y); }); g.stroke();
      txt('■ clicks',cx,cy+ch+22,13,'rgba(96,165,250,.9)'); txt('— impressions',cx+70,cy+ch+22,13,'#a78bfa');
      txt(gs.from+' – '+gs.to,cx+cw,cy+ch+22,13,'#8b94a6','right');
    }
  }

  // --- right: top searches and the page check
  const R=950;
  g.fillStyle='rgba(255,255,255,.08)'; g.fillRect(R-16,16,1,248);
  txt('TOP SEARCHES',R,32,14,'#8b94a6','left','600');
  const qs=gs&&gs.queries||[];
  if(qs.length) qs.slice(0,4).forEach((q,i)=>{ const y=60+i*28; txt(clip(q.q,30),R,y,17,'#e5e7eb'); txt(num(q.clicks)+' · #'+q.position.toFixed(1),R+456,y,15,'#8b94a6','right'); });
  else txt(gs?'No searches with clicks yet.':'—',R,62,16,'#8b94a6');
  const a=d.audit;
  txt('PAGE CHECK',R,190,14,'#8b94a6','left','600');
  if(a){
    const sum=a.fail?a.fail+' to fix':a.warn?a.warn+' to look at':'all good';
    txt(a.ok+'/'+(a.ok+a.warn+a.fail)+' ok · '+sum,R+456,190,14,a.fail?'#ef4444':a.warn?'#f59e0b':'#22c55e','right','600');
    const bad=(a.checks||[]).filter(c=>c.state!=='ok').slice(0,2);
    if(!bad.length) txt('✓ '+a.ms+' ms · certificate '+(a.certDays!=null?a.certDays+' days':'—'),R,220,16,'#22c55e');
    bad.forEach((c,i)=>txt((c.state==='fail'?'✗ ':'! ')+c.label+(c.detail?': '+c.detail:''),R,220+i*26,16,c.state==='fail'?'#ef4444':'#f59e0b'));
  } else txt((d.errors||[]).find(e=>/site/.test(e))||'Checking the page…',R,220,15,'#8b94a6');
}
c.addEventListener('click',ev=>{ const r=c.getBoundingClientRect(), x=(ev.clientX-r.left)*1424/r.width; if(x<440){ strat= strat==='mobile'?'desktop':'mobile'; } });
