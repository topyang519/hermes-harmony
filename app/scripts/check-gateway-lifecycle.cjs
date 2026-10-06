#!/usr/bin/env node
// Run the actual ArkTS client/store with mocked platform APIs and a virtual clock.
// The HAP build separately checks ArkTS types and SDK compatibility.
const assert = require('node:assert/strict');
const { test } = require('node:test');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');

const compilerPaths = [
  process.env.HARMES_TYPESCRIPT_PATH,
  path.join(os.homedir(), 'Library/Huawei/command-line-tools/codelinter/node_modules/typescript/lib/typescript.js')
].filter(Boolean);
const compilerPath = compilerPaths.find((candidate) => fs.existsSync(candidate));
if (!compilerPath) {
  throw new Error('Set HARMES_TYPESCRIPT_PATH to the TypeScript compiler bundled with Huawei CLT.');
}
const ts = require(compilerPath);
const sourceRoot = path.resolve(__dirname, '../entry/src/main/ets');

async function flush() {
  for (let i = 0; i < 8; i++) { await Promise.resolve(); }
}

function fixture({ hungStop = false } = {}) {
  let now = 100000;
  let nextTimer = 0;
  const timers = new Map();
  const storage = new Map();
  const sockets = [];
  const background = { starts: 0, stops: 0 };
  const preferences = {
    syncAllSessions: false, autoVoiceReply: false, agentSessions: {}, phoneSessionIds: [],
    load: async () => {}, save: async () => {}, publish: () => {}, isPhoneOwned: () => true
  };
  const schedule = (callback, delay, interval = false) => {
    const id = ++nextTimer;
    timers.set(id, { callback, at: now + delay, interval: interval ? delay : 0 });
    return id;
  };
  class Socket {
    constructor() { this.listeners = new Map(); this.sent = []; this.closes = 0; }
    on(event, callback) { this.listeners.set(event, callback); }
    connect(...args) { args.at(-1)(null, true); }
    send(raw, callback) { this.sent.push(JSON.parse(raw)); callback(null, true); }
    close(_options, callback) { this.closes++; callback(null, true); }
    emit(event, value = {}) {
      if (event === 'error') { this.listeners.get(event)?.(value); }
      else { this.listeners.get(event)?.(null, value); }
    }
    receive(frame) { this.emit('message', JSON.stringify(frame)); }
    ready(epoch = 'epoch-1', hermes = true) {
      this.receive({ t: 'ready', epoch, hermes, features: ['a2a_task_correlation_v1', 'a2a_control_handoff_v1', 'voice_readiness_v1'] });
    }
  }
  const mocks = {
    '@kit.NetworkKit': { webSocket: { createWebSocket: () => { const socket = new Socket(); sockets.push(socket); return socket; } } },
    './Secrets': { Secrets: { load: async () => ({ gatewayUrl: 'wss://example.invalid/v2/app', password: 'fixture-only' }) }, DEFAULT_GATEWAY_URL: '' },
    './AppPrefs': { AppPrefs: preferences },
    './BackgroundConnectionTask': { BackgroundConnectionTask: {
      start: async () => { background.starts++; return true; },
      stop: () => { background.stops++; return hungStop ? new Promise(() => {}) : Promise.resolve(); }
    } },
    './TaskReplyNotifications': { TaskReplyNotifications: { requestPermission: async () => true, publishReply: async () => {} } }
  };
  const context = vm.createContext({
    console, ArrayBuffer,
    Date: class extends Date { static now() { return now; } },
    ObservedV2: (constructor) => constructor, Trace: () => {},
    AppStorage: { setOrCreate: (key, value) => storage.set(key, value), get: (key) => storage.get(key) },
    setTimeout: (callback, delay) => schedule(callback, delay), clearTimeout: (id) => timers.delete(id),
    setInterval: (callback, delay) => schedule(callback, delay, true), clearInterval: (id) => timers.delete(id)
  });
  const modules = new Map();
  function load(filename) {
    if (modules.has(filename)) { return modules.get(filename).exports; }
    const module = { exports: {} };
    modules.set(filename, module);
    const source = fs.readFileSync(filename, 'utf8');
    const compiled = ts.transpileModule(source, {
      fileName: `${filename}.ts`, reportDiagnostics: true,
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS, experimentalDecorators: true }
    });
    const errors = (compiled.diagnostics ?? []).filter((diagnostic) => diagnostic.category === ts.DiagnosticCategory.Error);
    assert.equal(errors.length, 0, ts.formatDiagnosticsWithColorAndContext(errors, {
      getCurrentDirectory: () => sourceRoot, getCanonicalFileName: (file) => file, getNewLine: () => '\n'
    }));
    const wrapper = vm.runInContext(`(function(require, module, exports) { ${compiled.outputText}\n})`, context, { filename });
    wrapper((request) => {
      if (mocks[request]) { return mocks[request]; }
      assert.ok(request.startsWith('.'), `Unexpected platform import: ${request}`);
      return load(path.resolve(path.dirname(filename), `${request}.ets`));
    }, module, module.exports);
    return module.exports;
  }
  const { GatewayClient } = load(path.join(sourceRoot, 'service/GatewayClient.ets'));
  const client = new GatewayClient();
  client.uiAbilityContext = {};
  return {
    client, storage, sockets, background, preferences,
    async online() {
      await client.onForeground();
      const socket = sockets.at(-1);
      socket.emit('open');
      socket.ready();
      client.setActiveSession('conversation');
      const timeline = client.store.timeline('conversation');
      timeline.fromPhone = true;
      timeline.lastSeen = 17;
      socket.sent = [];
      return socket;
    },
    async advance(ms) {
      const until = now + ms;
      let iterations = 0;
      while (true) {
        const next = [...timers].filter(([, timer]) => timer.at <= until).sort((a, b) => a[1].at - b[1].at)[0];
        if (!next) { break; }
        assert.ok(++iterations < 1000, 'Virtual timers did not settle');
        const [id, timer] = next;
        now = timer.at;
        if (!timer.interval) { timers.delete(id); }
        timer.callback();
        if (timer.interval && timers.has(id)) { timer.at += timer.interval; }
        await flush();
      }
      now = until;
      await flush();
    }
  };
}


test('idle background and foreground reuse a live socket and replay only the current cursor', async () => {
  const f = fixture();
  const socket = await f.online();
  f.client.onBackground();
  assert.equal(socket.closes, 0);
  assert.equal(f.client.connected, true);
  await f.client.onForeground();
  assert.equal(f.sockets.length, 1);
  assert.equal(f.client.isReady(), false, 'Sending must wait for a fresh readiness acknowledgement');
  assert.equal(f.storage.get('hermes_recovering'), true);
  assert.equal(socket.sent[0].t, 'hello');
  socket.ready();
  assert.equal(f.client.isReady(), true);
  assert.equal(f.storage.get('hermes_recovering'), false);
  assert.deepEqual(JSON.parse(JSON.stringify(socket.sent.filter((frame) => frame.t === 'sub'))), [
    { t: 'sub', session: 'conversation', last_seen: 17 }
  ]);
  assert.equal(socket.sent.some((frame) => frame.t === 'dispatch' || frame.t === 'interrupt'), false);
  await f.advance(2000);
  assert.equal(f.sockets.length, 1);
});

test('an unanswered resume probe replaces the stale socket and accepts only the new handshake', async () => {
  const f = fixture();
  const oldSocket = await f.online();
  f.client.onBackground();
  await f.client.onForeground();
  await f.advance(1500);
  assert.equal(f.sockets.length, 2);
  assert.equal(oldSocket.closes, 1);
  assert.equal(f.client.connected, false);
  assert.equal(f.storage.get('hermes_recovering'), true);
  oldSocket.ready();
  assert.equal(f.client.connected, false, 'Stale callbacks cannot restore old readiness');
  const socket = f.sockets.at(-1);
  socket.emit('open');
  socket.ready();
  assert.equal(f.client.isReady(), true);
  assert.equal(f.storage.get('hermes_recovering'), false);
  assert.equal(socket.sent.some((frame) => frame.t === 'dispatch'), false);
});

test('idle background disables stale liveness timers without closing the socket', async () => {
  const f = fixture();
  const socket = await f.online();
  f.client.onBackground();
  await f.advance(90000);
  assert.equal(socket.closes, 0);
  await f.client.onForeground();
  socket.ready();
  assert.equal(f.client.isReady(), true);
  assert.equal(f.sockets.length, 1);
});

test('a background idle socket loss waits until foreground to reconnect', async () => {
  const f = fixture();
  const socket = await f.online();
  f.client.onBackground();
  socket.emit('close');
  await f.advance(10000);
  assert.equal(f.sockets.length, 1);
  await f.client.onForeground();
  assert.equal(f.sockets.length, 2);
  assert.equal(f.storage.get('hermes_recovering'), true);
  f.sockets.at(-1).ready();
  assert.equal(f.client.lastError, '');
  assert.equal(f.client.isReady(), true);
});

test('a failed socket during a resume probe reconnects without an extra backoff delay', async () => {
  const f = fixture();
  const socket = await f.online();
  f.client.onBackground();
  await f.client.onForeground();
  socket.emit('error', { code: 2300001 });
  await f.advance(0);
  assert.equal(f.sockets.length, 2);
  assert.equal(f.storage.get('hermes_recovering'), true);
});

test('unresolved recovery is exposed after the bounded grace period', async () => {
  const f = fixture();
  await f.online();
  f.client.onBackground();
  await f.client.onForeground();
  await f.advance(4000);
  assert.equal(f.storage.get('hermes_recovering'), false);
  assert.equal(f.client.connected, false);
  assert.equal(f.client.isReady(), false);
});

test('active turns retain background execution and finishing only releases the platform task', async () => {
  const f = fixture();
  const socket = await f.online();
  f.client.awaitingReply = true;
  f.client.onBackground();
  assert.equal(f.background.starts, 1);
  assert.equal(f.client.awaitingReply, true);
  assert.equal(socket.closes, 0);
  const stops = f.background.stops;
  f.client.awaitingReply = false;
  f.client.reconcileBackgroundTask();
  assert.equal(f.background.stops, stops + 1);
  assert.equal(socket.closes, 0);
});

test('foreground startup never waits for an unresolved platform task stop', async () => {
  const f = fixture({ hungStop: true });
  await f.client.onForeground();
  assert.equal(f.sockets.length, 1);
  f.sockets[0].ready();
  assert.equal(f.client.isReady(), true);
});

test('manual disconnect cancels recovery and is respected on subsequent foreground callbacks', async () => {
  const f = fixture();
  const socket = await f.online();
  f.client.onBackground();
  await f.client.onForeground();
  f.client.disconnect();
  await f.advance(20000);
  await f.client.onForeground();
  assert.equal(socket.closes, 1);
  assert.equal(f.sockets.length, 1);
  assert.equal(f.client.connected, false);
  assert.equal(f.storage.get('hermes_recovering'), false);
});

test('an interrupted initial handshake is replaced on foreground return', async () => {
  const f = fixture();
  await f.client.onForeground();
  const oldSocket = f.sockets[0];
  f.client.onBackground();
  await f.client.onForeground();
  assert.equal(f.sockets.length, 2);
  oldSocket.ready();
  assert.equal(f.client.connected, false);
  f.sockets[1].ready();
  assert.equal(f.client.isReady(), true);
});

test('a second background transition cancels the first resume probe', async () => {
  const f = fixture();
  const socket = await f.online();
  f.client.onBackground();
  await f.client.onForeground();
  f.client.onBackground();
  await f.advance(2000);
  assert.equal(f.sockets.length, 1);
  await f.client.onForeground();
  socket.ready();
  assert.equal(f.client.isReady(), true);
});

test('a Hermes epoch change on a retained socket replays from a reset cursor', async () => {
  const f = fixture();
  const socket = await f.online();
  f.client.onBackground();
  await f.client.onForeground();
  socket.ready('epoch-2');
  const subscriptions = socket.sent.filter((frame) => frame.t === 'sub');
  assert.equal(subscriptions.length, 1);
  assert.equal(subscriptions[0].last_seen, 0);
});
