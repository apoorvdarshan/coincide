// Optional offline development oracle; no Node/Pi runtime ships in Coincide.
// Usage (with a cleared environment): node script/generate_pi_history_oracle.mjs
//   --session-manager /exact/v0.80.5/session-manager.ts
//   --messages /exact/v0.80.5/messages.ts [--output /private/new-candidate.json]
// Or: --source-dir /exact/v0.80.5/core [--output /private/new-candidate.json]
// A missing output creates a new private temporary candidate. Existing output
// files are never replaced; install a reviewed candidate in the repo separately.
// This evaluates original source bodies under restricted import facades. It is
// not a complete package import, OS sandbox, installed-Pi test, or fork oracle.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import cp from 'node:child_process';
import net from 'node:net';
import tls from 'node:tls';
import http from 'node:http';
import https from 'node:https';
import http2 from 'node:http2';
import dgram from 'node:dgram';
import dns from 'node:dns';
import { StringDecoder } from 'node:string_decoder';
import { stripTypeScriptTypes, syncBuiltinESMExports } from 'node:module';
import assert from 'node:assert/strict';

async function main() {
const MAX_BYTES = 16 * 1024 * 1024;
const sourceSpecs = [
  { name: 'session-manager.ts', hash: 'b135a1d19a70cc840658c995539dbcc01fc4eaa3ca6f0ff1df1cbf2c7fbe3cdd', marker: 'export const CURRENT_SESSION_VERSION = 3;', origin: 'https://raw.githubusercontent.com/earendil-works/pi/v0.80.5/packages/coding-agent/src/core/session-manager.ts' },
  { name: 'messages.ts', hash: '8229aedb49e0cf12ebb9ed72670e24770c23e4d3ea814fe6f4e91cabe0288745', marker: 'export const COMPACTION_SUMMARY_PREFIX =', origin: 'https://raw.githubusercontent.com/earendil-works/pi/v0.80.5/packages/coding-agent/src/core/messages.ts' },
];
const args = process.argv.slice(2);
if (args.length === 1 && args[0] === '--help') {
  console.log('Usage: node generate_pi_history_oracle.mjs --session-manager <pinned.ts> --messages <pinned.ts> [--output <fresh-private-candidate.json>], or --source-dir <pinned-core-directory>.');
  return;
}
let managerPath, messagesPath, requestedOutput;
if (args.some(argument => argument.startsWith('--'))) {
  const options = new Map(), allowedOptions = new Set(['--session-manager', '--messages', '--source-dir', '--output']);
  for (let position = 0; position < args.length; position += 2) {
    const name = args[position], value = args[position + 1];
    assert(allowedOptions.has(name) && value && !value.startsWith('--') && !options.has(name), 'Provide distinct explicit source/output options.');
    options.set(name, value);
  }
  if (options.has('--source-dir')) {
    assert(!options.has('--session-manager') && !options.has('--messages'), 'Choose a source directory or two source files.');
    managerPath = path.join(options.get('--source-dir'), 'session-manager.ts');
    messagesPath = path.join(options.get('--source-dir'), 'messages.ts');
  } else {
    managerPath = options.get('--session-manager'); messagesPath = options.get('--messages');
  }
  requestedOutput = options.get('--output');
} else {
  assert(args.length === 2 || args.length === 3, 'Provide two original source paths and an optional private output path.');
  [managerPath, messagesPath, requestedOutput] = args;
}
assert(managerPath && messagesPath, 'Both exact original source files are required.');
if (!requestedOutput) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'coincide-pi-oracle-candidate-'));
  fs.chmodSync(directory, 0o700); requestedOutput = path.join(directory, 'pi_history_original_0_80_5.candidate.json');
}
const outputPath = path.resolve(requestedOutput);
assert(!fs.existsSync(outputPath), 'Refuse to replace an existing candidate fixture.');
const outputDirectory = fs.realpathSync(path.dirname(outputPath));
assert.equal(fs.statSync(outputDirectory).uid, process.getuid());
assert.equal(fs.statSync(outputDirectory).mode & 0o077, 0, 'Output must live in a private directory.');
const hash = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const sourceIdentity = info => Object.fromEntries(['dev', 'ino', 'size', 'mtimeNs', 'ctimeNs'].map(key => [key, info[key]]));
const matchesIdentity = (first, second) => Object.keys(first).every(key => first[key] === second[key]);
function readPinnedSource(input, expectedHash, expectedIdentity) {
  const descriptor = fs.openSync(input, fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK);
  try {
    const before = fs.fstatSync(descriptor, { bigint: true });
    assert(before.isFile() && before.nlink === 1n && before.uid === BigInt(process.getuid()) && before.size <= 128n * 1024n, 'Original source must be a bounded owned regular file.');
    const identity = sourceIdentity(before);
    if (expectedIdentity) assert(matchesIdentity(expectedIdentity, identity), 'Original source identity changed.');
    const chunks = [], buffer = Buffer.alloc(16 * 1024);
    let total = 0;
    while (true) {
      const count = fs.readSync(descriptor, buffer, 0, buffer.length, null);
      if (count === 0) break;
      total += count; assert(total <= 128 * 1024, 'Original source exceeded its read limit.');
      chunks.push(Buffer.from(buffer.subarray(0, count)));
    }
    const after = fs.fstatSync(descriptor, { bigint: true }), named = fs.lstatSync(input, { bigint: true });
    assert(after.isFile() && named.isFile() && after.nlink === 1n && named.nlink === 1n &&
      matchesIdentity(identity, sourceIdentity(after)) && matchesIdentity(identity, sourceIdentity(named)), 'Original source changed during its read.');
    const bytes = Buffer.concat(chunks);
    assert.equal(hash(bytes), expectedHash, 'Original source hash does not match the v0.80.5 pin.');
    return { bytes, identity };
  } finally { fs.closeSync(descriptor); }
}
const sources = [managerPath, messagesPath].map((input, index) => {
  const inputPath = path.resolve(input), { bytes, identity } = readPinnedSource(inputPath, sourceSpecs[index].hash);
  const text = bytes.toString('utf8');
  const start = text.indexOf(sourceSpecs[index].marker);
  assert(start >= 0 && text.indexOf(sourceSpecs[index].marker, start + 1) === -1, 'Expected one original import-preamble boundary.');
  const body = text.slice(start);
  assert(!/\bimport\s*(?:\(|["'])|\brequire\s*\(/.test(body), 'Original body unexpectedly imports another module.');
  return { ...sourceSpecs[index], inputPath, identity, body, bodyHash: hash(body) };
});
const scratch = fs.mkdtempSync(path.join(outputDirectory, '.pi-oracle-run-'));
fs.chmodSync(scratch, 0o700);
// Also clean the exact owned runtime if a pre-import guard assertion fails.
process.once('exit', () => { try { fs.rmSync(scratch, { recursive: true, force: true }); } catch {} });
const workspace = path.join(scratch, 'Workspace 工作 😀');
const sessionDirectory = path.join(scratch, 'Synthetic Sessions');
fs.mkdirSync(workspace, { mode: 0o700 });
fs.mkdirSync(sessionDirectory, { mode: 0o700 });
for (const name of Object.keys(process.env)) delete process.env[name];
Object.assign(process.env, { HOME: scratch, TMPDIR: scratch, PATH: '/usr/bin:/bin' });

const guards = { subprocess: 0, network: 0, filesystem: 0, configuration: 0, identityCreation: 0 };
const guardSelfTests = { subprocess: 0, network: 0, filesystem: 0, configuration: 0, identityCreation: 0 };
let checkingGuards = false;
const allowed = { opens: 0, closes: 0, reads: 0, readBytes: 0, stats: 0, existenceChecks: 0, pathIdentity: 0 };
const refusalMessage = 'The offline original-source oracle refused a prohibited operation.';
const refuse = category => (..._args) => { (checkingGuards ? guardSelfTests : guards)[category]++; throw new Error(refusalMessage); };
const blockedProcess = refuse('subprocess'), blockedNetwork = refuse('network');
for (const name of ['spawn', 'spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork']) cp[name] = blockedProcess;
for (const [object, names] of [
  [net, ['connect', 'createConnection', 'createServer']], [net.Socket.prototype, ['connect']], [net.Server.prototype, ['listen']],
  [tls, ['connect', 'createServer']], [http, ['request', 'get', 'createServer']], [https, ['request', 'get', 'createServer']],
  [http2, ['connect', 'createServer', 'createSecureServer']], [dgram, ['createSocket']],
  [dns, ['lookup', 'lookupService', 'resolve', 'resolve4', 'resolve6', 'resolveAny', 'resolveCname', 'resolveMx', 'resolveNaptr', 'resolveNs', 'resolvePtr', 'resolveSoa', 'resolveSrv', 'resolveTxt', 'reverse']],
  [dns.promises, ['lookup', 'lookupService', 'resolve', 'resolve4', 'resolve6', 'resolveAny', 'resolveCname', 'resolveMx', 'resolveNaptr', 'resolveNs', 'resolvePtr', 'resolveSoa', 'resolveSrv', 'resolveTxt', 'reverse']],
]) for (const name of names) if (typeof object[name] === 'function') object[name] = blockedNetwork;
globalThis.fetch = blockedNetwork;
if ('WebSocket' in globalThis) globalThis.WebSocket = class { constructor() { blockedNetwork(); } };
syncBuiltinESMExports();

const timestamp = '2026-10-23T00:00:00.000Z';
const entry = (type, id, parentId, fields = {}) => ({ type, id, parentId, timestamp, ...fields });
const user = (id, parentId, content = 'Exact literal input 工作 😀 e\u0301') => entry('message', id, parentId, { message: { role: 'user', content, timestamp: 1792713600000 } });
const assistant = (id, parentId) => entry('message', id, parentId, { message: { role: 'assistant', provider: 'synthetic-provider', model: 'synthetic-model', content: [{ type: 'text', text: 'Synthetic native answer' }], timestamp: 1792713600000 } });
const compact = (id, parent, kept, summary) => entry('compaction', id, parent, { firstKeptEntryId: kept, summary, tokensBefore: 123 });
const branched = [user('inherited-user', null), assistant('inherited-answer', 'inherited-user'), user('local-user', 'inherited-answer'), assistant('local-answer', 'local-user'), user('abandoned-user', 'inherited-answer'), assistant('abandoned-answer', 'abandoned-user')];
const compactions = [user('u1', null), assistant('a1', 'u1'), user('u2', 'a1'), assistant('a2', 'u2'), compact('c1', 'a2', 'u2', 'Older summary'),
  entry('custom', 'state', 'c1', { customType: 'opaque-state', data: { privateValue: 'synthetic-only' } }),
  entry('custom_message', 'custom-note', 'state', { customType: 'context-note', content: 'Hidden context', display: false }),
  entry('branch_summary', 'branch-summary', 'custom-note', { fromId: 'a1', summary: 'Inherited branch summary' }),
  entry('label', 'label', 'branch-summary', { targetId: 'u2', label: 'Keep this marker' }),
  entry('session_info', 'info', 'label', { name: 'Synthetic native name' }), user('u3', 'info'), compact('c2', 'u3', 'branch-summary', 'Latest summary'), assistant('a3', 'c2'), compact('abandoned-compaction', 'a1', 'u1', 'Wrong branch summary')];
const custom = [entry('thinking_level_change', 'thinking', null, { thinkingLevel: 'high' }), entry('model_change', 'model', 'thinking', { provider: 'synthetic-provider', modelId: 'chosen-model' }),
  user('original-user', 'model'), entry('custom', 'custom-state', 'original-user', { customType: 'state', data: { count: 3 } }),
  entry('custom_message', 'hidden', 'custom-state', { customType: 'hidden', content: 'Included despite display=false', display: false }),
  entry('custom_message', 'visible', 'hidden', { customType: 'visible', content: [{ type: 'text', text: 'Visible note' }], display: true }),
  entry('branch_summary', 'empty-summary', 'visible', { fromId: 'root', summary: '' }),
  entry('branch_summary', 'nonempty-summary', 'empty-summary', { fromId: 'original-user', summary: 'Nonempty summary' }),
  entry('session_info', 'title', 'nonempty-summary', { name: 'Synthetic title' })];
const labels = [user('user', null), entry('label', 'label-first', 'user', { targetId: 'user', label: 'First label' }), assistant('reply', 'label-first'),
  entry('label', 'label-replace', 'reply', { targetId: 'user', label: 'Replacement' }), user('second-user', 'label-replace'),
  entry('label', 'label-clear', 'second-user', { targetId: 'user' }), assistant('last-reply', 'label-clear')];
const missingContent = { role: 'assistant', provider: 'synthetic-provider', model: 'synthetic-model', timestamp: 1792713600000 };
const payloads = [user('unicode-input', null, 'עברית 工作 😀 e\u0301 literal $NAME /skill: note'),
  entry('message', 'null-assistant', 'unicode-input', { message: { ...missingContent, content: null } }),
  entry('message', 'missing-assistant', 'null-assistant', { message: missingContent }),
  user('image-input', 'missing-assistant', [{ type: 'image', data: 'c3ludGhldGlj', mimeType: 'image/png' }, { type: 'text', text: 'Synthetic image only' }]),
  entry('message', 'tool-null', 'image-input', { message: { role: 'toolResult', toolCallId: 'synthetic-tool', toolName: 'read', content: null, isError: false, timestamp: 1792713600000 } })];
const cases = [
  { name: 'runtime-active-branch-is-not-last-append', rows: branched, leaf: 'local-answer', cuts: ['inherited-user', 'local-user'], labelIDs: [] },
  { name: 'runtime-reset-leaf-is-not-file-reload', rows: branched, leaf: null, cuts: [], labelIDs: [] },
  { name: 'runtime-branch-back-to-inherited-context', rows: branched, leaf: 'inherited-answer', cuts: ['inherited-user'], labelIDs: [] },
  { name: 'first-active-compaction-with-kept-prefix-and-custom-context', rows: compactions, leaf: 'u3', cuts: ['u2', 'u3'], labelIDs: ['u2'] },
  { name: 'latest-active-compaction-ignores-abandoned-later-summary', rows: compactions, leaf: 'a3', cuts: ['u3'], labelIDs: ['u2'] },
  { name: 'missing-first-kept-does-not-resurrect-prefix', rows: [user('u', null), assistant('a', 'u'), compact('c', 'a', 'not-present', 'Summary only'), user('after', 'c')], leaf: 'after', cuts: ['after'], labelIDs: [] },
  { name: 'off-branch-first-kept-does-not-resurrect-abandoned-entries', rows: [user('u', null), assistant('a', 'u'), user('other', 'u'), compact('c', 'a', 'other', 'No kept path')], leaf: 'c', cuts: ['u'], labelIDs: [] },
  { name: 'custom-state-versus-context-and-empty-branch-summary', rows: custom, leaf: 'title', cuts: ['original-user'], labelIDs: [] },
  { name: 'labels-are-parents-and-last-clear-survives-reload', rows: labels, leaf: 'last-reply', cuts: ['user', 'second-user'], labelIDs: ['user'] },
  { name: 'unicode-images-and-null-or-missing-content', rows: payloads, leaf: 'tool-null', cuts: ['unicode-input', 'image-input'], labelIDs: [] },
  { name: 'empty-v3-header-has-null-reload-leaf', rows: [], leaf: null, cuts: [], labelIDs: [] },
];
assert(cases.length <= 32);
const allowedPaths = new Set([workspace, sessionDirectory]);
const permittedFiles = new Set();
const openDescriptors = new Map();
const originals = new Map();
for (let index = 0; index < cases.length; index++) {
  const item = cases[index];
  item.header = { type: 'session', version: 3, id: `synthetic-native-${index + 1}`, timestamp, cwd: workspace };
  const seen = new Set();
  for (const row of item.rows) {
    assert(!seen.has(row.id) && (row.parentId === null || seen.has(row.parentId)), 'Synthetic oracle input must be acyclic by construction.');
    seen.add(row.id);
  }
  const bytes = Buffer.from([item.header, ...item.rows].map(row => JSON.stringify(row)).join('\n') + '\n');
  assert(bytes.length <= MAX_BYTES && item.rows.length <= 20_000);
  item.file = path.join(sessionDirectory, `case-${index + 1}.jsonl`);
  fs.writeFileSync(item.file, bytes, { flag: 'wx', mode: 0o600 });
  permittedFiles.add(item.file); allowedPaths.add(item.file); originals.set(item.file, bytes);
}
const checkPath = value => {
  if (typeof value !== 'string' || !allowedPaths.has(value) || path.resolve(value) !== value) return refuse('filesystem')();
  return value;
};
const checkFile = value => {
  checkPath(value);
  if (!permittedFiles.has(value)) return refuse('filesystem')();
  const info = fs.lstatSync(value);
  if (!info.isFile() || info.nlink !== 1 || info.uid !== process.getuid() || info.size > MAX_BYTES) return refuse('filesystem')();
  return value;
};
const bindings = {
  uuidv7: refuse('identityCreation'), randomUUID: refuse('identityCreation'),
  getDefaultAgentDir: refuse('configuration'), getSessionsDir: refuse('configuration'),
  normalizePath: value => { const checked = checkPath(value); allowed.pathIdentity++; return checked; },
  resolvePath: value => { const checked = checkPath(value); allowed.pathIdentity++; return checked; },
  join: path.join, resolve: path.resolve, StringDecoder,
  existsSync: value => { allowed.existenceChecks++; checkPath(value); return fs.existsSync(value); },
  statSync: value => { allowed.stats++; return fs.statSync(checkFile(value)); },
  openSync: (value, flags) => {
    if (flags !== 'r') return refuse('filesystem')();
    const file = checkFile(value), descriptor = fs.openSync(file, 'r');
    openDescriptors.set(descriptor, { file, readBytes: 0 }); allowed.opens++; return descriptor;
  },
  readSync: (descriptor, buffer, offset, length, position) => {
    const owned = openDescriptors.get(descriptor);
    if (!owned || !Buffer.isBuffer(buffer) || length > 1024 * 1024 || offset < 0 || length < 0 || offset + length > buffer.length) return refuse('filesystem')();
    const count = fs.readSync(descriptor, buffer, offset, length, position);
    owned.readBytes += count; allowed.reads++; allowed.readBytes += count;
    if (owned.readBytes > MAX_BYTES) return refuse('filesystem')();
    return count;
  },
  closeSync: descriptor => {
    if (!openDescriptors.has(descriptor)) return refuse('filesystem')();
    fs.closeSync(descriptor); openDescriptors.delete(descriptor); allowed.closes++;
  },
  appendFileSync: refuse('filesystem'), writeFileSync: refuse('filesystem'), mkdirSync: refuse('filesystem'),
  readdirSync: refuse('filesystem'), createReadStream: refuse('filesystem'), createInterface: refuse('filesystem'),
  readdir: refuse('filesystem'), stat: refuse('filesystem'),
};
// Exercise denied entry points without performing the denied operation. Keep
// these counters separate; never reset or hide an original-code guard violation.
checkingGuards = true;
const deniedProbes = [
  () => cp.spawn('/nonexistent/oracle-denied'), () => cp.exec('oracle-denied'), () => cp.fork('/nonexistent/oracle-denied'),
  () => net.connect({ host: 'oracle.invalid', port: 1 }), () => tls.connect({ host: 'oracle.invalid', port: 1 }),
  () => http.get('http://oracle.invalid/'), () => https.request('https://oracle.invalid/'),
  () => http2.connect('https://oracle.invalid'), () => dgram.createSocket('udp4'), () => dns.lookup('oracle.invalid'),
  () => dns.promises.resolve4('oracle.invalid'), () => globalThis.fetch('https://oracle.invalid/'),
  () => bindings.openSync('/not-an-allowed-oracle-file', 'r'), () => bindings.openSync(cases[0].file, 'w'),
  () => bindings.readSync(-12345, Buffer.alloc(1), 0, 1, null), () => bindings.closeSync(-12345),
  () => bindings.writeFileSync(cases[0].file, ''), () => bindings.readdirSync(sessionDirectory),
  () => bindings.normalizePath('/not-an-allowed-oracle-directory'),
  () => bindings.getDefaultAgentDir(), () => bindings.getSessionsDir(), () => bindings.uuidv7(), () => bindings.randomUUID(),
];
if ('WebSocket' in globalThis) deniedProbes.push(() => new globalThis.WebSocket('wss://oracle.invalid/'));
for (const probe of deniedProbes) assert.throws(probe, error => error instanceof Error && error.message === refusalMessage);
checkingGuards = false;
assert(Object.values(guardSelfTests).every(count => count > 0));
assert(Object.values(guards).every(count => count === 0));
const slot = Symbol.for('coincide.pi.originalSourceOracle.bindings');
Object.defineProperty(globalThis, slot, { value: bindings, configurable: true });
const dataURL = source => 'data:text/javascript;base64,' + Buffer.from(source).toString('base64');
let stage = 'original-messages-import';
try {
  const messagesJS = stripTypeScriptTypes(sources[1].body, { mode: 'strip', sourceUrl: 'original-pi-v0.80.5-messages.ts' });
  const messages = await import(dataURL(messagesJS));
  Object.assign(bindings, {
    createBranchSummaryMessage: messages.createBranchSummaryMessage,
    createCompactionSummaryMessage: messages.createCompactionSummaryMessage,
    createCustomMessage: messages.createCustomMessage,
  });
  Object.freeze(bindings);
  stage = 'original-manager-import';
  const managerJS = stripTypeScriptTypes(sources[0].body, { mode: 'strip', sourceUrl: 'original-pi-v0.80.5-session-manager.ts' });
  const prefix = `const {${Object.keys(bindings).join(',')}}=globalThis[Symbol.for('coincide.pi.originalSourceOracle.bindings')];\n`;
  const native = await import(dataURL(prefix + managerJS));
  stage = 'synthetic-case-evaluation';
  const outputs = [];
  for (const item of cases) {
    assert.deepEqual(native.parseSessionEntries(originals.get(item.file).toString('utf8')), [item.header, ...item.rows]);
    const manager = native.SessionManager.open(item.file, sessionDirectory, workspace);
    const snapshot = model => {
      const entries = model.getEntries(), context = model.buildContextEntries(), projection = model.buildSessionContext();
      assert.deepEqual(context, native.buildContextEntries(entries, model.getLeafId()));
      return {
        sessionID: model.getSessionId(), sessionFile: model.getSessionFile(),
        leafID: model.getLeafId(), inventoryEntryIDs: entries.map(row => row.id), branchEntryIDs: model.getBranch().map(row => row.id),
        contextEntryIDs: context.map(row => row.id), contextMessageEntryIDs: context.filter(row => native.sessionEntryToContextMessages(row).length > 0).map(row => row.id),
        projectedMessages: projection.messages, thinkingLevel: projection.thinkingLevel, model: projection.model,
        labels: Object.fromEntries(item.labelIDs.map(id => [id, model.getLabel(id) ?? null])),
      };
    };
    const initialReload = snapshot(manager), branchResetTransitions = [];
    const move = leaf => {
      if (leaf === null) manager.resetLeaf(); else manager.branch(leaf);
      const observed = snapshot(manager);
      branchResetTransitions.push({ action: leaf === null ? 'resetLeaf' : 'branch', entryID: leaf,
        leafID: observed.leafID, branchEntryIDs: observed.branchEntryIDs,
        contextEntryIDs: observed.contextEntryIDs, contextMessageEntryIDs: observed.contextMessageEntryIDs });
      return observed;
    };
    const runtime = move(item.leaf);
    assert.equal(runtime.leafID, item.leaf);
    assert.deepEqual(manager.getEntries(), item.rows);
    assert.deepEqual(manager.getHeader(), item.header);
    if (item.rows.length > 0) {
      move(null); move(item.rows[0].id);
      assert.deepEqual(move(item.leaf), runtime);
    }
    const cuts = [];
    for (const id of item.cuts) {
      const selected = manager.getEntry(id);
      assert(selected?.type === 'message' && selected.message?.role === 'user');
      if (selected.parentId === null) manager.resetLeaf(); else manager.branch(selected.parentId);
      cuts.push({ beforeUserEntryID: id, retainedEntryIDs: manager.getBranch().map(row => row.id) });
    }
    const reopened = snapshot(native.SessionManager.open(item.file, sessionDirectory, workspace));
    assert.deepEqual(initialReload, reopened, 'In-memory branch movement must not alter file-reload observations.');
    assert.deepEqual(fs.readFileSync(item.file), originals.get(item.file), 'Original code changed a synthetic source file.');
    outputs.push({ name: item.name, header: manager.getHeader(), entries: manager.getEntries(), runtimeLeafID: item.leaf, expectedRuntime: runtime, expectedReload: reopened, branchResetTransitions, cuts });
  }
  stage = 'guard-and-source-verification';
  assert.equal(openDescriptors.size, 0, 'Original reader did not close all owned file descriptors.');
  assert.equal(allowed.opens, allowed.closes);
  assert(Object.values(guards).every(count => count === 0), 'Original code attempted a prohibited operation.');
  for (const [file, before] of originals) assert.deepEqual(fs.readFileSync(file), before);
  // Recheck both exact original inputs, including physical file identity. Paths
  // and stat values remain private to this process and never enter the fixture.
  for (const source of sources) readPinnedSource(source.inputPath, source.hash, source.identity);
  const stable = value => {
    if (typeof value === 'string') {
      if (value === workspace) return '/synthetic-pi-oracle-workspace';
      if (value.startsWith(sessionDirectory + '/')) return '/synthetic-pi-oracle-sessions/' + path.basename(value);
      return value;
    }
    if (Array.isArray(value)) return value.map(stable);
    if (value && typeof value === 'object') return Object.fromEntries(Object.entries(value).map(([key, child]) => [key, stable(child)]));
    return value;
  };
  // Runtime workspace path length changes the actual byte count. Preserve that
  // measurement in stdout, while keeping the synthetic golden fixture portable.
  const { readBytes: _actualReadBytes, ...stableAllowedOperations } = allowed;
  const fixture = stable({
    schema: 1, providerVersion: '0.80.5', origin: 'hash-pinned original source bodies with restricted import facades',
    modules: sources.map(({ name, hash, bodyHash, origin }) => ({ name, sha256: hash, bodySha256: bodyHash, origin })),
    scope: { fullPackageImported: false, installedProviderInvoked: false, nativeMutationTested: false, originalAlgorithmsRewritten: false, stableWorkspaceSubstitution: true },
    guards, guardSelfTests, allowedOperations: stableAllowedOperations, cases: outputs,
  });
  const bytes = Buffer.from(JSON.stringify(fixture, null, 2) + '\n');
  assert(bytes.length <= MAX_BYTES);
  const pending = path.join(outputDirectory, '.candidate-' + crypto.randomUUID() + '.json');
  const descriptor = fs.openSync(pending, 'wx', 0o600);
  try { fs.writeFileSync(descriptor, bytes); fs.fsyncSync(descriptor); } finally { fs.closeSync(descriptor); }
  // link is an exclusive publication: an unexpected existing output is kept.
  fs.linkSync(pending, outputPath); fs.unlinkSync(pending);
  const parentDescriptor = fs.openSync(outputDirectory, 'r');
  try { fs.fsyncSync(parentDescriptor); } finally { fs.closeSync(parentDescriptor); }
  console.log(JSON.stringify({ candidatePath: outputPath, cases: outputs.length, fixtureBytes: bytes.length, fixtureSHA256: hash(bytes), guards, guardSelfTests, allowedOperations: allowed, fullPackageImported: false }));
} catch (error) {
  // No original error description/stack, source data, environment, or local path
  // enters the report; a fixed stage identifies a harness/projection boundary.
  console.error(JSON.stringify({ oracleFailed: true, stage, errorClass: error instanceof Error ? error.constructor.name : 'Unknown', guards }));
  process.exitCode = 1;
} finally {
  for (const descriptor of openDescriptors.keys()) { try { fs.closeSync(descriptor); } catch {} }
  delete globalThis[slot];
  fs.rmSync(scratch, { recursive: true, force: true });
}

}
main().catch(error => {
  console.error(JSON.stringify({ oracleFailed: true, stage: 'preflight-or-guard-setup', errorClass: error instanceof Error ? error.constructor.name : 'Unknown' }));
  process.exitCode = 1;
});
