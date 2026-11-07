//! Fixed private-world transaction source. Native adapters supply arguments
//! through their isolated-world SDK, never page evaluation/IPC/tool source.
//! No field value, text, HTML, selector or frame document is returned.
//!
//! Mask all editable controls conservatively, and whole embedded documents,
//! canvases and custom-element hosts whose private/shadow content cannot be
//! inspected reliably. Native snapshot painting flushes layout/style; do not
//! await requestAnimationFrame (hidden/minimized documents can suspend it).
//! WebKitGTK2.40 FrameView::paintContentsForSnapshot calls
//! updateLayoutAndStyleIfNeededRecursive before painting:
//! https://github.com/WebKit/WebKit/blob/webkitgtk-2.40.0/Source/WebCore/page/FrameView.cpp#L4418
//! WKSnapshotConfiguration additionally requests afterScreenUpdates.
//! A MutationObserver invalidates *any* intervening page
//! mutation. Moving/animated pages may therefore refuse a screenshot safely.
//! This does not promise detection of secrets drawn as ordinary page content.

pub const PREPARE: &str = r#"
const key='__coincidePrivateSnapshotV1';
if (globalThis[key] || typeof ticket!=='string' || ticket.length!==36 ||
    location.href!==expectedURL || document.readyState!=='complete') return '';
const root=document.documentElement;
if (!root || visualViewport && visualViewport.scale!==1) return '';
const width=innerWidth,height=innerHeight,sx=scrollX,sy=scrollY;
if (!(width>0 && width<=20000 && height>0 && height<=20000)) return '';
const docHeight=Math.max(root.scrollHeight,document.body?.scrollHeight||0);
const docWidth=Math.max(root.scrollWidth,document.body?.scrollWidth||0);
// Never resize/scroll a real view. Full-page is admitted only when already
// contained in this bounded native viewport; adapters may implement a separate
// genuinely bounded SDK full-page operation later.
if (fullPage==='yes' && (docHeight>height || docWidth>width)) return '';
const nodes=[],walker=document.createTreeWalker(root,NodeFilter.SHOW_ELEMENT);
let node=root;
while(node){if(nodes.length>=10000)return '';nodes.push(node);node=walker.nextNode();}
const masks=[], saved=[];
const props=[['opacity','0'],['transition','none'],['animation','none']];
function restore(){
 for(const [node,old] of saved) for(let i=0;i<props.length;i++){
  const [name,value]=props[i], [original,priority]=old[i];
  // A newer page/user style owns the property; never overwrite it.
  if(node.style.getPropertyValue(name)!==value || node.style.getPropertyPriority(name)!=='important') continue;
  if(original) node.style.setProperty(name,original,priority);else node.style.removeProperty(name);
 }
}
try {
 for(const node of nodes){
  const tag=node.localName;
  const sensitive=(tag==='input' && !['button','submit','reset','image','hidden'].includes(node.type)) ||
    tag==='textarea' || node.isContentEditable || node.getAttribute('role')==='textbox' ||
    ['iframe','frame','object','embed','canvas','foreignObject'].includes(tag) || node.shadowRoot || tag.includes('-');
  if(!sensitive) continue;
  const r=node.getBoundingClientRect();
  if(r.bottom<=0 || r.right<=0 || r.left>=width || r.top>=height) continue;
  if(masks.length>=2048) {restore();return '';}
  masks.push({x:r.x,y:r.y,width:r.width,height:r.height});
  const old=props.map(([name])=>[node.style.getPropertyValue(name),node.style.getPropertyPriority(name)]);
  saved.push([node,old]);
  for(const [name,value] of props)node.style.setProperty(name,value,'important');
 }
 const state={ticket,root,width,height,sx,sy,url:location.href,saved,props,restore,dirty:false};
 state.observer=new MutationObserver(()=>{state.dirty=true;});
 state.observer.observe(root,{subtree:true,childList:true,attributes:true,characterData:true});
 globalThis[key]=state;
 // Flush style synchronously; the actual native snapshot API paints current
 // layout again after this real JS callback. No frame/timer is a completion ACK.
 root.getBoundingClientRect();
 for(const [node] of saved) if(getComputedStyle(node).opacity!=='0'){
  state.observer.disconnect();restore();delete globalThis[key];return '';
 }
 if(state.dirty || state.observer.takeRecords().length || root!==document.documentElement ||
    location.href!==expectedURL || innerWidth!==width || innerHeight!==height || scrollX!==sx || scrollY!==sy){
  state.observer.disconnect();restore();delete globalThis[key];return '';
 }
 return JSON.stringify({width,height,masks});
}catch(_){restore();delete globalThis[key];return '';}
"#;

pub const FINISH: &str = r#"
const key='__coincidePrivateSnapshotV1',s=globalThis[key];
if(!s || s.ticket!==ticket) return false;
let valid=!s.dirty && !s.observer.takeRecords().length && s.root===document.documentElement &&
  s.url===location.href && location.href===expectedURL && s.width===innerWidth &&
  s.height===innerHeight && s.sx===scrollX && s.sy===scrollY;
for(const [node] of s.saved) for(const [name,value] of s.props)
 if(!node.isConnected || node.style.getPropertyValue(name)!==value || node.style.getPropertyPriority(name)!=='important')valid=false;
s.observer.disconnect();s.restore();delete globalThis[key];return valid;
"#;
