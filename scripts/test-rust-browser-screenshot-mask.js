#!/usr/bin/env node
// Inert DOM regressions for the actual private-world transaction source.
// No browser, page, native SDK, profile, network or password manager is opened.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const source = fs.readFileSync(path.join(__dirname, '../crates/coincide-core/src/browser_screenshot_mask.rs'), 'utf8');
const script = name => {
  const body = source.match(new RegExp('pub const ' + name + ': &str = r#"([\\s\\S]*?)"#;'))?.[1];
  assert.ok(body, name + ' source missing');
  return new Function('ticket', 'expectedURL', 'mode', 'restoreX', 'restoreY', 'restoreHeight', body);
};
const prepare = script('PREPARE');
const finish = script('FINISH');
const ticket = '12345678-1234-1234-1234-123456789012';
let elements;
Object.assign(globalThis, {location: {href: 'https://owned.invalid/'}, innerWidth: 800, innerHeight: 600, scrollX: 0, scrollY: 0, devicePixelRatio: 1, window: {}, scrollTo() {}, requestAnimationFrame() {}});
globalThis.document = {
  documentElement: {clientWidth: 800, clientHeight: 600, scrollWidth: 800, scrollHeight: 600},
  body: {scrollWidth: 800, scrollHeight: 600},
  contains: el => elements.includes(el), querySelectorAll: () => elements,
};
const form = {contains: el => el.form === form};
function element(tag, type, autocomplete, x, associated = true) {
  const styles = new Map();
  const node = {localName: tag, type, autocomplete, id: '', name: '', shadowRoot: null, isConnected: true, form: associated ? form : null,
    getRootNode: () => document,
    getAttribute: key => key === 'autocomplete' ? node.autocomplete : null,
    getBoundingClientRect: () => ({x, y: 5, width: 100, height: 20}),
    style: {getPropertyValue: key => styles.get(key)?.[0] || '', getPropertyPriority: key => styles.get(key)?.[1] || '',
      setProperty: (key, value, priority) => styles.set(key, [value, priority]), removeProperty: key => styles.delete(key)},
  };
  return node;
}
function transaction(change, expected) {
  const password = element('input', 'password', '', 0);
  const ordinary = element('input', 'text', '', 120);
  const frame = element('iframe', undefined, '', 240, false);
  elements = [password, ordinary, frame];
  const metrics = JSON.parse(prepare(ticket, location.href, 'mask', '', '', ''));
  assert.equal(metrics.masks.length, 2);
  assert.equal(frame.style.getPropertyValue('opacity'), '0');
  assert.equal(ordinary.style.getPropertyValue('opacity'), '');
  change({password, ordinary, frame});
  assert.equal(finish(ticket, location.href, '', '', '', ''), expected);
  assert.equal(password.style.getPropertyValue('opacity'), '');
  assert.equal(frame.style.getPropertyValue('opacity'), '');
  assert.equal(globalThis.__coincidePrivateSnapshotV1, undefined);
}
transaction(() => {}, true);
transaction(() => elements.push(element('input', 'email', 'username', 360)), 'added');
transaction(({ordinary}) => { ordinary.autocomplete = 'email'; }, 'added');
transaction(({ordinary}) => { ordinary.id = 'login-user'; }, 'added');
transaction(() => elements.push(element('iframe', undefined, '', 360, false)), 'added');
transaction(() => elements.push(element('input', 'text', '', 360, false)), true);
console.log('PASS: new and reclassified login usernames refuse publication; opaque surfaces masked; ordinary inputs visible; styles restored');
