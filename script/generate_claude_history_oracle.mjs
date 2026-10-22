// Optional development oracle. No SDK or Node dependency ships in Coincide.
// Usage: node script/generate_claude_history_oracle.mjs /path/to/extracted/sdk
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import cp from 'node:child_process';
import net from 'node:net';
import { syncBuiltinESMExports } from 'node:module';
import { fileURLToPath, pathToFileURL } from 'node:url';

const sdkPath = path.resolve(process.argv[2] ?? '', 'sdk.mjs');
const expectedHash = 'b1607967e0dfb39a0db45f143d3b57c7a85f2f6eaa77d6bee7d8184a9830a9f3';
if (crypto.createHash('sha256').update(fs.readFileSync(sdkPath)).digest('hex') !== expectedHash) {
  throw new Error('Expected the exact Claude Agent SDK 0.3.276 source.');
}
const fixturePath = fileURLToPath(new URL('../Tests/CoincideCoreTests/Fixtures/claude_history_sdk_0_3_276.json', import.meta.url));
const fixture = JSON.parse(fs.readFileSync(fixturePath, 'utf8'));
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'coincide-claude-sdk-oracle-'));
fs.chmodSync(scratch, 0o700);
let blockedCalls = 0;
const refuse = () => { blockedCalls++; throw new Error('The offline history oracle prohibits subprocesses and network access.'); };
for (const name of ['spawn', 'spawnSync', 'exec', 'execSync', 'execFile', 'execFileSync', 'fork']) cp[name] = refuse;
net.Socket.prototype.connect = refuse;
globalThis.fetch = refuse;
syncBuiltinESMExports();
// The SDK never sees the developer's account, home or inherited credentials.
for (const name of Object.keys(process.env)) delete process.env[name];
Object.assign(process.env, { HOME: scratch, CLAUDE_CONFIG_DIR: path.join(scratch, 'claude'), PATH: '/usr/bin:/bin', TMPDIR: scratch });

function normalize(records) {
  const reverse = new Map(records.filter(r => r.forkedFrom).map(r => [r.uuid, r.forkedFrom.messageUuid]));
  return records.map(record => {
    const result = structuredClone(record);
    delete result.uuid; delete result.timestamp;
    if ('sessionId' in result) result.sessionId = '$target';
    for (const key of ['parentUuid', 'logicalParentUuid']) {
      if (typeof result[key] === 'string') result[key] = reverse.get(result[key]) ?? '$unmapped';
    }
    if (result.type === 'history-suppression') delete result.ts;
    const attachment = result.attachment;
    if (attachment?.type === 'queued_command' && reverse.has(attachment.source_uuid)) attachment.source_uuid = reverse.get(attachment.source_uuid);
    if (attachment?.type === 'deferred_tools_record' && Array.isArray(attachment.nameOnlyAnnouncements)) {
      attachment.nameOnlyAnnouncements = attachment.nameOnlyAnnouncements.map(id => reverse.get(id) ?? '$unmapped');
    }
    return result;
  });
}

try {
  fs.mkdirSync(path.join(scratch, 'workspace'), { mode: 0o700 });
  const workspace = fs.realpathSync(path.join(scratch, 'workspace'));
  const projectKey = workspace.replace(/[^a-zA-Z0-9]/g, '-');
  const project = path.join(process.env.CLAUDE_CONFIG_DIR, 'projects', projectKey);
  fs.mkdirSync(project, { recursive: true, mode: 0o700 });
  const { getSessionMessages, forkSession } = await import(pathToFileURL(sdkPath).href);
  for (const item of fixture.cases) {
    const sourcePath = path.join(project, item.sessionID + '.jsonl');
    const source = item.rows.map(row => JSON.stringify({ ...row, ...(row.cwd ? { cwd: workspace } : {}) }) + '\n').join('');
    fs.writeFileSync(sourcePath, source, { mode: 0o600 });
    item.expectedMessages = await getSessionMessages(item.sessionID, { dir: workspace });
    const forked = await forkSession(item.sessionID, { dir: workspace, upToMessageId: item.cutoff });
    const records = fs.readFileSync(path.join(project, forked.sessionId + '.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
    // Restore the stable synthetic cwd from the input before comparing payloads.
    const stableCwd = item.rows.find(row => row.cwd)?.cwd;
    for (const row of records) if (row.cwd) row.cwd = stableCwd;
    item.expectedForkRecords = normalize(records);
    if (fs.readFileSync(sourcePath, 'utf8') !== source) throw new Error('The SDK changed an oracle source transcript.');
  }
  if (blockedCalls !== 0) throw new Error('The SDK attempted a prohibited operation.');
  fixture.blockedCalls = blockedCalls;
  fs.writeFileSync(fixturePath, JSON.stringify(fixture, null, 2) + '\n');
  console.log(`Verified ${fixture.cases.length} synthetic SDK history cases; no model, authentication, subprocess or network calls.`);
} finally {
  fs.rmSync(scratch, { recursive: true, force: true });
}
