//! Fixed private-world transaction source. Native adapters supply arguments
//! through their isolated-world SDK, never page evaluation/IPC/tool source.
//! No field value, text, HTML, selector or frame document is returned.
//!
//! Sensitive fields are password inputs, credential, one-time-code and payment
//! card autocomplete fields, and the username fields of login forms (the
//! fields Coincide's credential fill can write). They are hidden in the page
//! for the capture and redacted again in the pixels. Ordinary fields,
//! canvases and page content stay visible. Opaque frame/plugin surfaces are
//! masked as whole rectangles because their fields cannot be inspected. FINISH
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
 const inputs=[], opaque=[], pending=[document];
 let visited=0;
 while(pending.length){
  const scope=pending.pop();
  for(const el of scope.querySelectorAll('*')){
   if(++visited>250000) return null;
   if(el.localName==='input') inputs.push(el);
   if(['iframe','frame','object','embed'].includes(el.localName)) opaque.push(el);
   if(el.shadowRoot) pending.push(el.shadowRoot);
  }
 }
 const secret=['current-password','new-password','one-time-code','cc-number','cc-csc','cc-exp','cc-exp-month','cc-exp-year'];
 const tokens=el=>String(el.getAttribute('autocomplete')||'').toLowerCase().split(/\s+/);
 const found=new Set(opaque.concat(inputs.filter(el=>el.type==='password' || tokens(el).some(t=>secret.includes(t)))));
 for(const pass of inputs.filter(el=>el.type==='password')){
  const scope=pass.form||pass.getRootNode();
  for(const el of inputs) if(scope.contains(el) && ['text','email','tel'].includes(el.type) &&
    (tokens(el).some(t=>t==='username'||t==='email') || /user|email|login/i.test((el.name||'')+' '+(el.id||'')))) found.add(el);
 }
 return Array.from(found);
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
// Longhands only: shorthand serializations differ between engines, and
// FINISH/restore must recognize exactly the values set here.
const props=[['opacity','0'],['transition-property','none'],['animation-name','none']];
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
/// Returns `true`, or one fixed reason code from [`finish_failure`].
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
if(!s || s.ticket!==ticket) return 'missing';
delete globalThis[key];
function check(){
 if(s.url!==location.href || location.href!==expectedURL) return 'navigated';
 if(s.innerWidth!==innerWidth || s.innerHeight!==innerHeight) return 'resized';
 if(s.scrollX!==scrollX || s.scrollY!==scrollY) return 'scrolled';
 const now=[], pending=[document];
 let visited=0;
 while(pending.length){
  for(const el of pending.pop().querySelectorAll('*')){
   if(++visited>250000) return 'large';
   if(el.localName==='input' || ['iframe','frame','object','embed'].includes(el.localName)) now.push(el);
   if(el.shadowRoot) pending.push(el.shadowRoot);
  }
 }
 // Every field PREPARE hid is still connected, still ours and unmoved, and
 // no detectable sensitive field or opaque surface appeared. Closed shadow
 // roots and secrets drawn as ordinary content remain outside this contract.
 const kept=new Set(s.fields);
 if(now.some(el=>!kept.has(el) && (['iframe','frame','object','embed'].includes(el.localName) || el.type==='password' ||
   /password|one-time-code|cc-/i.test(String(el.getAttribute('autocomplete')||''))))) return 'added';
 const masks=[];
 for(const el of s.fields){
  if(!el.isConnected) return 'removed';
  const r=el.getBoundingClientRect();
  if(r.width>0 && r.height>0) masks.push({x:r.x,y:r.y,width:r.width,height:r.height});
 }
 if(JSON.stringify(masks)!==s.masks) return 'moved';
 for(const [node] of s.saved) for(const [name,value] of s.props)
  if(node.style.getPropertyValue(name)!==value || node.style.getPropertyPriority(name)!=='important') return 'restyled';
 return true;
}
let result;
try { result=check(); } catch(_) { result='failed'; }
s.restore();
return result;
"#;

/// Maps FINISH's reason code to a fixed message; anything else is invalid.
pub fn finish_failure(reason: &str) -> &'static str {
    match reason {
        "navigated" => "The page navigated during its snapshot",
        "resized" => "The page viewport changed during its snapshot",
        "scrolled" => "The page scrolled during its snapshot; try again",
        "large" => "The page has too many elements to check its sensitive fields",
        "added" => "A sensitive field or opaque surface appeared during the snapshot; try again",
        "removed" | "moved" => "A sensitive field moved during the snapshot; try again",
        "restyled" => "The page restyled a hidden sensitive field during the snapshot",
        "missing" => "The snapshot mask transaction was lost",
        _ => "Snapshot document changed or was cancelled",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn finish_reasons_are_fixed_messages_and_unknown_codes_stay_generic() {
        assert!(finish_failure("moved").contains("moved"));
        assert_eq!(finish_failure("removed"), finish_failure("moved"));
        for unknown in ["", "true", "<page supplied text>"] {
            assert_eq!(
                finish_failure(unknown),
                "Snapshot document changed or was cancelled"
            );
        }
        // Engines serialize shorthands differently; only longhands are set.
        assert!(!PREPARE.contains("['transition','none']"));
        assert!(PREPARE.contains("['transition-property','none']"));
    }
}
