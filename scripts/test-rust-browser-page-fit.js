#!/usr/bin/env node
// Exercise the actual document-start script with an inert, deterministic DOM.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(path.join(__dirname, '../crates/coincide-desktop/src/browser_page_fit.rs'), 'utf8');
const script = source.match(/pub\(crate\) const WIDTH_SCRIPT: &str = r#"([\s\S]*?)"#;/)?.[1];
assert.ok(script, 'production fit script missing');

function fixture({url = 'https://example.invalid/', ipc = true, initial = '', priority = '', rootInitially = true} = {}) {
  const properties = new Map(initial ? [['opacity', [initial, priority]]] : []);
  const style = {
    getPropertyValue: key => properties.get(key)?.[0] || '',
    getPropertyPriority: key => properties.get(key)?.[1] || '',
    setProperty: (key, value, priority) => properties.set(key, [value, priority || '']),
    removeProperty: key => properties.delete(key),
  };
  const root = {style, scrollWidth: 1000};
  const events = new Map();
  const timers = [];
  const messages = [];
  let rootObserver;
  const document = {
    documentElement: rootInitially ? root : null,
    body: {scrollWidth: 1000},
    readyState: 'loading',
    addEventListener: (name, callback) => events.set('document:' + name, callback),
  };
  const window = {
    innerWidth: 550,
    addEventListener: (name, callback) => events.set('window:' + name, callback),
  };
  window.top = window;
  if (ipc) window.ipc = {postMessage: value => messages.push(JSON.parse(value))};
  class MutationObserver {
    constructor(callback) { this.callback = callback; rootObserver = this; }
    observe() {}
    disconnect() {}
  }
  class ResizeObserver { observe() {} }
  let nextTimer = 0;
  const context = {window, document, location: {href: url}, MutationObserver, ResizeObserver,
    setTimeout: (callback, delay) => { const id = ++nextTimer; timers.push({id, callback, delay}); return id; },
    clearTimeout: id => { const index = timers.findIndex(timer => timer.id === id); if (index !== -1) timers.splice(index, 1); }};
  vm.runInNewContext(script, context);
  return {window, document, root, style, messages, timers, events,
    insertRoot() { document.documentElement = root; rootObserver.callback(); },
    domReady() { events.get('document:DOMContentLoaded')?.(); },
    runTimer(delay) { const index = timers.findIndex(timer => timer.delay === delay); assert.notEqual(index, -1); timers.splice(index, 1)[0].callback(); },
  };
}

{
  const f = fixture({initial: '0.6'});
  assert.equal(f.style.getPropertyValue('opacity'), '0');
  assert.equal(f.style.getPropertyPriority('opacity'), 'important');
  assert.equal(f.messages.length, 0);
  f.domReady();
  const first = f.messages[0];
  assert.equal(first.viewport, 550);
  assert.equal(first.content, 1000);
  assert.equal(first.held, true);
  f.window.__coincidePageFitV1.reveal('anotherDocument');
  assert.equal(f.style.getPropertyValue('opacity'), '0');
  f.runTimer(100);
  assert.equal(f.messages.length, 2, 'held pages retry until native acknowledges');
  f.window.__coincidePageFitV1.reveal(first.document, 1000);
  assert.equal(f.style.getPropertyValue('opacity'), '0', 'wait for native zoom to take effect');
  f.window.__coincidePageFitV1.reveal(first.document, 1000);
  assert.equal(f.timers.filter(timer => timer.delay === 16).length, 1, 'coalesce reveal retries');
  f.window.innerWidth = 1000;
  f.runTimer(16);
  assert.equal(f.style.getPropertyValue('opacity'), '0.6');
  assert.equal(f.style.getPropertyPriority('opacity'), '');
  f.events.get('window:pagehide')({persisted: true});
  assert.equal(f.style.getPropertyValue('opacity'), '0', 'hide a page retained for back/forward');
  f.events.get('window:pageshow')({persisted: true});
  assert.equal(f.messages.at(-1).held, true, 'remeasure a restored page before revealing it');
  f.window.__coincidePageFitV1.reveal(first.document);
  assert.equal(f.style.getPropertyValue('opacity'), '0.6');
}
{
  const f = fixture();
  f.domReady();
  f.style.setProperty('opacity', '0.7', '');
  f.window.__coincidePageFitV1.reveal(f.messages[0].document);
  assert.equal(f.style.getPropertyValue('opacity'), '0.7', 'preserve a site change');
}
{
  const f = fixture({rootInitially: false});
  f.insertRoot();
  assert.equal(f.style.getPropertyValue('opacity'), '0');
  f.runTimer(8000);
  assert.equal(f.style.getPropertyValue('opacity'), '', 'watchdog restores a stalled page');
}
{
  const f = fixture();
  f.root.scrollWidth = 2000000;
  f.domReady();
  assert.equal(f.messages[0].content, 1000000, 'extremely wide documents still reach native fitting');
  f.window.__coincidePageFitV1.reveal(f.messages[0].document);
  assert.equal(f.style.getPropertyValue('opacity'), '');
}
for (const options of [{url: 'about:blank'}, {ipc: false}]) {
  assert.equal(fixture(options).style.getPropertyValue('opacity'), '');
}
console.log('PASS: first paint is held until the matching fit, restored safely, and bounded by a watchdog');
