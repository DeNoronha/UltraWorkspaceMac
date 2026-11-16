const POLL=5000;
// Traffic: this Mac's network traffic. Left the rate now and its chart (incoming above, outgoing below), middle the
// hosts (tap the title for the services), right the apps; each line its bytes in the window with an in/out bar.
// From Deckhand (/traffic/data.json), which samples only while this page asks.
const IN='#f5b400', OUT='#0ea5e9';
let mid='hosts', hits=[];
function bytes(b){ return b>=1e9?(b/1e9).toFixed(1)+' GB':b>=1e6?(b/1e6).toFixed(1)+' MB':b>=1e3?Math.round(b/1e3)+' KB':Math.round(b)+' B'; }
function rate(b){ return b>=1e6?(b/1e6).toFixed(1)+' MB/s':b>=1e3?Math.round(b/1e3)+' KB/s':Math.round(b)+' B/s'; }
function list(rows,x,y0,w,title,alt){
  txt(title,x,32,14,'#8b94a6','left','600'); if(alt){ txt(alt,x+w,32,13,'#6b7280','right'); }
  if(!rows||!rows.length){ txt('Nothing yet.',x,70,16,'#8b94a6'); return; }
  const max=Math.max(1,...rows.map(r=>r.in+r.out));
  rows.slice(0,5).forEach((r,i)=>{ const y=y0+i*44;
    txt((r.local?'⌂ ':'')+clip(r.name,30),x,y,17,'#e5e7eb'); txt(bytes(r.in+r.out),x+w,y,16,'#fff','right','600');
    const full=(r.in+r.out)/max*w, wi=full*(r.in/((r.in+r.out)||1));
    rr(x,y+8,Math.max(2,wi),5,2,IN); if(full-wi>1) rr(x+wi,y+8,full-wi,5,2,OUT); });
}
function render(d){
  hits=[];
  if(d.warming||!d.rate){ txt(d.error||'Measuring this Mac’s traffic…',712,150,20,d.error?'#f59e0b':'#8b94a6','center'); return; }
  // --- left: rate and chart
  txt('TRAFFIC · LAST '+(d.window===1?'MINUTE':d.window===60?'HOUR':d.window+' MINUTES'),20,32,14,'#8b94a6','left','600');
  txt('↓ '+rate(d.rate.down),20,72,28,IN,'left','700'); txt('↑ '+rate(d.rate.up),230,72,28,OUT,'left','700');
  const C=d.chart||{}, dn=C.down||[], up=C.up||[], x0=20, w=420, mid0=172, hh=70;
  const peak=Math.max(1,...dn,...up);
  g.fillStyle='rgba(255,255,255,.12)'; g.fillRect(x0,mid0,w,1);
  function area(xs,dir,col){ if(xs.length<2) return; const X=i=>x0+i*w/(xs.length-1);
    g.fillStyle=col+'55'; g.beginPath(); g.moveTo(X(0),mid0); xs.forEach((v,i)=>g.lineTo(X(i),mid0-dir*v/peak*hh)); g.lineTo(X(xs.length-1),mid0); g.closePath(); g.fill();
    g.strokeStyle=col; g.lineWidth=1.8; g.beginPath(); xs.forEach((v,i)=>{ const y=mid0-dir*v/peak*hh; i?g.lineTo(X(i),y):g.moveTo(X(i),y); }); g.stroke(); }
  area(dn,1,IN); area(up,-1,OUT);
  txt(rate(peak),x0+w,mid0-hh+4,11,'#6b7280','right');
  const t=d.total||{}; txt('In '+bytes(t.in||0)+' · out '+bytes(t.out||0),20,266,14,'#8b94a6');
  // --- middle: hosts or services
  const M=476; g.fillStyle='rgba(255,255,255,.08)'; g.fillRect(M-18,16,1,248);
  list(mid==='hosts'?d.hosts:d.services,M,64,430,mid==='hosts'?'HOSTS':'SERVICES',mid==='hosts'?'tap for services':'tap for hosts');
  hits.push({x:M-18,y:0,w:470,h:280,mid:true});
  // --- right: apps
  const R=960; g.fillStyle='rgba(255,255,255,.08)'; g.fillRect(R-18,16,1,248);
  list(d.programs,R,64,444,'APPS');
}
c.addEventListener('click',ev=>{
  const r=c.getBoundingClientRect(), x=(ev.clientX-r.left)*1424/r.width, y=(ev.clientY-r.top)*280/r.height;
  const h=hits.find(o=>x>=o.x&&x<o.x+o.w&&y>=o.y&&y<o.y+o.h); if(h&&h.mid) mid=mid==='hosts'?'services':'hosts';
});
let lastD=null, dirty=false;
c.addEventListener('click',()=>{ dirty=true; });
function frame(){ if(D&&(D!==lastD||dirty)){ lastD=D; dirty=false; bg(); render(D); } setTimeout(frame,250); }
