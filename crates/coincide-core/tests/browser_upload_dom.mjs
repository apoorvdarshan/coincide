// Lightweight contract tests for the actual fixed upload script. Native WebKit
// acceptance is still required; these doubles do not prove browser API support.
import { readFileSync } from 'node:fs';
import assert from 'node:assert/strict';
import { runInNewContext } from 'node:vm';
import { test } from 'node:test';
const rust = readFileSync(new URL('../src/browser_protocol.rs', import.meta.url), 'utf8');
const script = rust.split('const SCRIPT: &str = r#"')[1].split('"#;')[0];
function fixture(options = {}) {
  const events = [];
  class Input {
    type = 'file'; multiple = false; disabled = false; files = [];
    getAttribute() { return null; }
    hasAttribute(name) { return options.directory && name === 'webkitdirectory'; }
    dispatchEvent(e) { events.push(e.type); }
  }
  class Transfer {
    files = [];
    items = { add: file => this.files.push(file) };
  }
  class File {
    constructor(parts, name, opts) { this.bytes = [...parts[0]]; this.name = name; this.type = opts.type; }
  }
  const target = Object.assign(new Input(), options.target);
  const win = { HTMLInputElement: Input, DataTransfer: Transfer, File,
    Event: class { constructor(type) { this.type = type; } }, atob: s => Buffer.from(s, 'base64').toString('binary') };
  const doc = { defaultView: win, querySelectorAll: () => options.ambiguous ? [target, target] : [target] };
  const request = {kind: 'upload', selector: '#file', files: options.files ?? [{name: 'test.bin', mime: 'application/octet-stream', data: 'AP8KQQ=='}]};
  const context = { request, frameId: options.frame ?? null, document: doc, window: win, URL, Uint8Array };
  if (options.frame === 'valid') {
    const element = { isConnected: true, ownerDocument: doc, contentDocument: doc };
    win.__coincideSameOriginFramesV1 = new Map([['valid', {doc, chain: [{element, doc}]}]]);
  }
  const result = runInNewContext(`(() => { ${script} })()`, context);
  return {result, target, events};
}

test('hidden direct file input attaches exact binary bytes and sends input/change without submitting', () => {
  const {result, target, events} = fixture();
  assert.equal(result.attached, true);
  assert.equal(result.submissionRequested, false);
  assert.deepEqual(target.files[0].bytes, [0, 255, 10, 65]);
  assert.deepEqual(events, ['input', 'change']);
});
test('same-origin frame attachment uses resolved document', () => {
  assert.equal(fixture({frame: 'valid'}).result.frame, 'valid');
});
test('expired frame refuses before attachment', () => {
  const {result, events} = fixture({frame: 'expired'});
  assert.match(result.error, /expired/);
  assert.deepEqual(events, []);
});
for (const [name, options, error] of [
  ['ambiguous selector', {ambiguous: true}, /multiple elements/],
  ['non-file input', {target: {type: 'text'}}, /file input directly/],
  ['disabled input', {target: {disabled: true}}, /disabled/],
  ['directory input', {directory: true}, /Directory uploads/],
  ['single input with multiple files', {files: [{}, {}]}, /multiple files/],
]) {
  test(name + ' fails without events', () => {
    const {result, events, target} = fixture(options);
    assert.match(result.error, error);
    assert.deepEqual(events, []);
    assert.deepEqual(target.files, []);
  });
}
test('multiple input accepts multiple files including empty files', () => {
  const {result, target} = fixture({target: {multiple: true}, files: [
    {name: 'one', mime: '', data: ''}, {name: 'two', mime: '', data: 'QQ=='}
  ]});
  assert.equal(result.count, 2);
  assert.deepEqual(target.files.map(f => f.bytes), [[], [65]]);
});
