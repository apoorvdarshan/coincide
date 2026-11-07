//! Fixed private-world transaction source. Native adapters supply arguments
//! through their isolated-world SDK, never page evaluation/IPC/tool source.
//! No field value, text, HTML, selector or frame document is returned.
//!
//! Sensitive fields are password inputs, credential, one-time-code and payment
//! card autocomplete fields, and the username fields of login forms (the
//! fields Coincide's credential fill can write). They are hidden in the page
//! for the capture and redacted again in the pixels. Ordinary fields, frames,
//! canvases and page content stay visible, as in the Swift browser. FINISH
//! re-measures the same fields; a moved, added or restyled field refuses the
//! capture. This does not promise detection of secrets drawn as page content.
//!
//! Arguments: `ticket` (UUID), `expectedURL`, and `mode`: `measure` reads
//! metrics only, `mask` hides fields in place, and `mask-top` scrolls to the
//! document top first (a full page inside a temporarily resized view).

pub const PREPARE: &str = r#"
const key='__coincidePrivateSnapshotV1';
if (typeof ticket!=='string' || ticket.length!==36 || location.href!==expectedURL ||
    !['measure','mask','mask-top'].includes(mode)) return '';
if (globalThis[key]) {
 // One transaction per document. An abandoned one (no FINISH) expires.
 const old=globalThis[key];
 if (mode==='measure' || performance.now()-old.at<30000) return '';
 delete globalThis[key];
 try{old.restore();}catch(_){}
}
const root=document.documentElement;
if (!root || (window.visualViewport && visualViewport.scale!==1)) return '';
function sensitive(){
 const inputs=[], pending=[document];
 let visited=0;
 while(pending.length){
  const scope=pending.pop();
  for(const el of scope.querySelectorAll('*')){
   if(++visited>250000) return null;
   if(el.localName==='input') inputs.push(el);
   if(el.shadowRoot) pending.push(el.shadowRoot);
  }
 }
 const secret=['current-password','new-password','one-time-code','cc-number','cc-csc','cc-exp','cc-exp-month','cc-exp-year'];
 const tokens=el=>String(el.getAttribute('autocomplete')||'').toLowerCase().split(/\s+/);
 const found=new Set(inputs.filter(el=>el.type==='password' || tokens(el).some(t=>secret.includes(t))));
 for(const pass of inputs.filter(el=>el.type==='password')){
  const scope=pass.form||pass.getRootNode();
  for(const el of inputs) if(scope.contains(el) && ['text','email','tel'].includes(el.type) &&
    (tokens(el).some(t=>t==='username'||t==='email') || /user|email|login/i.test((el.name||'')+' '+(el.id||'')))) found.add(el);
 }
 return inputs.filter(el=>found.has(el));
}
function rects(fields){
 const out=[];
 for(const el of fields){
  const r=el.getBoundingClientRect();
  if(r.width>0 && r.height>0) out.push({x:r.x,y:r.y,width:r.width,height:r.height});
 }
 return out;
}
const fields=sensitive();
if(!fields || fields.length>2048) return '';
if(mode==='mask-top') scrollTo(0,0);
const props=[['opacity','0'],['transition','none'],['animation','none']];
const saved=[];
function restore(){
 for(const [node,old] of saved) for(let i=0;i<props.length;i++){
  const [name,value]=props[i], [original,priority]=old[i];
  // A newer page/user style owns the property; never overwrite it.
  if(node.style.getPropertyValue(name)!==value || node.style.getPropertyPriority(name)!=='important') continue;
  if(original) node.style.setProperty(name,original,priority);else node.style.removeProperty(name);
 }
}
try {
 if(mode!=='measure') for(const node of fields){
  saved.push([node,props.map(([name])=>[node.style.getPropertyValue(name),node.style.getPropertyPriority(name)])]);
  for(const [name,value] of props) node.style.setProperty(name,value,'important');
 }
 const body=document.body;
 const metrics={innerWidth,innerHeight,clientWidth:root.clientWidth,clientHeight:root.clientHeight,
  documentWidth:Math.max(root.scrollWidth,body?body.scrollWidth:0),
  documentHeight:Math.max(root.scrollHeight,body?body.scrollHeight:0),
  scrollX,scrollY,devicePixelRatio,masks:rects(fields)};
 if(mode!=='measure'){
  globalThis[key]={ticket,at:performance.now(),url:location.href,fields,masks:JSON.stringify(metrics.masks),
   innerWidth,innerHeight,scrollX,scrollY,saved,props,restore};
 }
 return JSON.stringify(metrics);
}catch(_){restore();delete globalThis[key];return '';}
"#;

/// Arguments: `ticket`, `expectedURL`, and `restoreX`/`restoreY`/`restoreHeight`
/// (strings; empty when no scroll position must return after a view resize).
pub const FINISH: &str = r#"
const key='__coincidePrivateSnapshotV1',s=globalThis[key];
if(restoreHeight){
 const x=Number(restoreX), y=Number(restoreY), height=Number(restoreHeight);
 let frames=0;
 // The native view returns to its size asynchronously; restore the reader's
 // scroll position only once the original viewport is back, even on failure.
 const back=()=>{ if(innerHeight===height) scrollTo(x,y); else if(++frames<120) requestAnimationFrame(back); };
 requestAnimationFrame(back);
}
if(!s || s.ticket!==ticket) return false;
delete globalThis[key];
let valid=s.url===location.href && location.href===expectedURL && s.innerWidth===innerWidth &&
  s.innerHeight===innerHeight && s.scrollX===scrollX && s.scrollY===scrollY;
try {
 const now=[], pending=[document];
 let visited=0;
 while(valid && pending.length){
  for(const el of pending.pop().querySelectorAll('*')){
   if(++visited>250000){valid=false;break;}
   if(el.localName==='input') now.push(el);
   if(el.shadowRoot) pending.push(el.shadowRoot);
  }
 }
 // Every field PREPARE hid is still connected, still ours and unmoved, and
 // no sensitive field appeared: the capture saw only masked secrets.
 const kept=new Set(s.fields);
 const added=now.some(el=>!kept.has(el) && (el.type==='password' ||
   /password|one-time-code|cc-/i.test(String(el.getAttribute('autocomplete')||''))));
 const masks=[];
 for(const el of s.fields){
  if(!el.isConnected) {valid=false;break;}
  const r=el.getBoundingClientRect();
  if(r.width>0 && r.height>0) masks.push({x:r.x,y:r.y,width:r.width,height:r.height});
 }
 if(added || JSON.stringify(masks)!==s.masks) valid=false;
 for(const [node] of s.saved) for(const [name,value] of s.props)
  if(node.style.getPropertyValue(name)!==value || node.style.getPropertyPriority(name)!=='important') valid=false;
} catch(_) {valid=false;}
s.restore();
return valid;
"#;
