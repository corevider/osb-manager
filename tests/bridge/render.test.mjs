import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const load = (file, name) => vm.runInNewContext(readFileSync(new URL('../../src/OsbManager/Browser/' + file, import.meta.url), 'utf8') + '\n' + name);
const createLightControl = load('light.js', 'createLightControl');
const installDeviceRetry = load('gpu.js', 'installDeviceRetry');
const createGpuSlots = load('gpu.js', 'createGpuSlots');
const gpuVendor = load('gpu.js', 'gpuVendor');

const lightSetup = ({ bot = true } = {}) => {
  const page = { allowed: false, own: [], bot: [] };
  const render = { set: enabled => page.bot.push(enabled) };
  const light = createLightControl({ allowed: () => page.allowed, botRender: () => bot ? render : null, setOwnRender: on => page.own.push(on) });
  return { page, light };
};

test('light mode waits until the world is ready', () => {
  const { page, light } = lightSetup();
  light.set(true);
  assert.equal(light.active(), false);
  assert.equal(light.waiting(), true);
  assert.deepEqual(page.bot, [], 'no render switch while loading');
  page.allowed = true; light.tick();
  assert.deepEqual(page.bot, [false], 'rendering stops once the world is ready');
  assert.equal(light.active(), true);
  assert.equal(light.waiting(), false);
});

test('a new loading screen turns drawing back on, then light mode returns', () => {
  const { page, light } = lightSetup();
  page.allowed = true; light.set(true);
  page.allowed = false; light.tick();
  page.allowed = true; light.tick();
  assert.deepEqual(page.bot, [false, true, false]);
});

test('light mode acts only when its own decision changes', () => {
  const { page, light } = lightSetup();
  page.allowed = true;
  light.tick(); light.tick();
  assert.deepEqual(page.bot, [], 'not wanted: the bot render switch is left alone');
  light.set(true); light.tick(); light.tick();
  assert.deepEqual(page.bot, [false]);
  light.set(false);
  assert.deepEqual(page.bot, [false, true]);
});

test('without the bot light mode uses its own render switch', () => {
  const { page, light } = lightSetup({ bot: false });
  page.allowed = true; light.set(true); light.set(false);
  assert.deepEqual(page.own, [true, false]);
});

const fullCard = () => {
  const error = new Error('ID3D12Device::CreateDescriptorHeap at CheckOutOfMemoryHRESULTImpl');
  error.name = 'OperationError';
  return error;
};

const gpuSetup = (failures, options = {}) => {
  const calls = [], waits = [];
  let adapters = 0;
  class Adapter {
    constructor() { this.id = ++adapters; }
    async requestDevice(descriptor) {
      calls.push([this.id, descriptor]);
      if (calls.length <= failures) throw fullCard();
      return { device: this.id };
    }
  }
  const gpu = { requestAdapter: async () => new Adapter() };
  const report = installDeviceRetry({ gpu, Adapter, wait: async ms => { waits.push(ms); }, ...options });
  return { Adapter, calls, waits, report };
};

test('a full graphics card is tried again with a fresh adapter', async () => {
  const { Adapter, calls, waits, report } = gpuSetup(2);
  const device = await new Adapter().requestDevice({ requiredFeatures: ['texture-compression-bc'] });
  assert.deepEqual(waits, [4000, 8000]);
  assert.deepEqual(calls.map(c => c[0]), [1, 2, 3], 'each try uses a new adapter');
  assert.deepEqual(calls[2][1], { requiredFeatures: ['texture-compression-bc'] }, 'with the same request');
  assert.equal(device.device, 3);
  assert.equal(report.retries, 2);
  assert.equal(report.failed, '');
});

test('the retries back off over about four minutes before giving up', async () => {
  const { Adapter, calls, waits, report } = gpuSetup(100);
  await assert.rejects(new Adapter().requestDevice({}), { name: 'OperationError' });
  assert.equal(calls.length, 7);
  assert.deepEqual(waits, [4000, 8000, 15000, 30000, 60000, 120000]);
  assert.equal(report.retries, 6);
  assert.equal(report.limit, 6);
  assert.match(report.failed, /CheckOutOfMemory/);
  assert.equal(report.retryIn(), 0);
});

test('the report says how long until the next try', async () => {
  let clock = 1000;
  let wake;
  const { Adapter, report } = gpuSetup(1, { now: () => clock, wait: () => new Promise(resolve => { wake = resolve; }) });
  const pending = new Adapter().requestDevice({});
  await new Promise(resolve => setImmediate(resolve));
  assert.equal(report.retries, 1);
  assert.equal(report.retryIn(), 4);
  clock += 2500;
  assert.equal(report.retryIn(), 2);
  wake();
  await pending;
  assert.equal(report.retryIn(), 0);
});

test('a new device request starts its own count', async () => {
  const { Adapter, report } = gpuSetup(2);
  await new Adapter().requestDevice({});
  assert.equal(report.retries, 2);
  await new Adapter().requestDevice({});
  assert.equal(report.retries, 0);
});

const slotSetup = (waitMs = 120000) => {
  const posts = [], timers = new Map();
  let ids = 0, timerIds = 0;
  const slots = createGpuSlots({
    post: message => posts.push({ ...message }),
    setTimer: (callback, ms) => { const id = ++timerIds; timers.set(id, { callback, ms }); return id; },
    clearTimer: id => timers.delete(id),
    makeId: () => 'r' + ++ids,
    waitMs,
  });
  const fire = () => { for (const [id, timer] of [...timers]) { timers.delete(id); timer.callback(); } };
  return { slots, posts, timers, fire };
};

test('every device request waits for the app to grant a slot and hands it back after the try', async () => {
  const { slots, posts } = slotSetup();
  const order = [];
  const { Adapter } = gpuSetup(1, { acquire: async () => { const release = await slots.acquire(); order.push('granted'); return () => { order.push('released'); release(); }; } });
  const pending = new Adapter().requestDevice({});
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(posts, [{ type: 'gpu-slot', id: 'r1' }]);
  assert.equal(slots.waiting(), true);
  assert.equal(slots.grant('r1'), true);
  await new Promise(resolve => setImmediate(resolve));
  assert.deepEqual(posts.slice(1, 3), [{ type: 'gpu-slot-done', id: 'r1' }, { type: 'gpu-slot', id: 'r2' }]);
  slots.grant('r2');
  await pending;
  assert.deepEqual(order, ['granted', 'released', 'granted', 'released']);
  assert.deepEqual(posts.at(-1), { type: 'gpu-slot-done', id: 'r2' });
});

test('an old app that never grants a slot only delays the start by the fallback wait', async () => {
  const { slots, posts, timers, fire } = slotSetup();
  let granted = false;
  slots.acquire().then(() => { granted = true; });
  assert.deepEqual([...timers.values()].map(t => t.ms), [120000]);
  await Promise.resolve();
  assert.equal(granted, false);
  fire();
  await Promise.resolve();
  assert.equal(granted, true);
  assert.equal(slots.waiting(), false);
  assert.deepEqual(posts, [{ type: 'gpu-slot', id: 'r1' }]);
});

test('a grant for an unknown or finished request is ignored and a slot is handed back once', async () => {
  const { slots, posts, timers } = slotSetup();
  assert.equal(slots.grant('nope'), false);
  const acquired = slots.acquire();
  assert.equal(slots.grant('r1'), true);
  assert.equal(timers.size, 0, 'the fallback timer is cleared');
  assert.equal(slots.grant('r1'), false);
  const release = await acquired;
  release(); release();
  assert.equal(posts.filter(p => p.type === 'gpu-slot-done').length, 1);
});

test('other errors are not retried', async () => {
  const calls = [];
  class Adapter { async requestDevice() { calls.push(1); throw new TypeError('bad feature'); } }
  const report = installDeviceRetry({ gpu: { requestAdapter: async () => new Adapter() }, Adapter, wait: async () => {} });
  await assert.rejects(new Adapter().requestDevice({}), TypeError);
  assert.equal(calls.length, 1);
  assert.match(report.failed, /bad feature/);
});

test('nothing changes without WebGPU', () => {
  class Adapter { requestDevice() { return 'native'; } }
  const original = Adapter.prototype.requestDevice;
  installDeviceRetry({ gpu: undefined, Adapter, wait: async () => {} });
  assert.equal(Adapter.prototype.requestDevice, original);
});

test('the adapter vendor maps to a fixed list and nothing else', () => {
  const cases = [
    ['nvidia', 'nvidia'], ['NVIDIA Corporation', 'nvidia'], ['0x10de', 'nvidia'],
    ['amd', 'amd'], ['Advanced Micro Devices, Inc.', 'amd'], ['ati', 'amd'], ['0x1002', 'amd'],
    ['intel', 'intel'], ['Intel(R) Corporation', 'intel'], ['0x8086', 'intel'],
    ['apple', 'apple'], ['qualcomm', 'qualcomm'],
    ['microsoft', 'other'], ['google', 'other'], ['arm', 'other'], ['ExampleCanaryVendor', 'other'],
    ['', 'unknown'], ['   ', 'unknown'], [undefined, 'unknown'], [42, 'unknown'],
  ];
  for (const [vendor, expected] of cases) assert.equal(gpuVendor({ info: { vendor, device: 'Canary GPU 9000', architecture: 'canary', description: 'Canary driver 1.2.3' } }), expected, String(vendor));
  assert.equal(gpuVendor({}), 'unknown');
  assert.equal(gpuVendor(null), 'unknown');
  assert.equal(gpuVendor({ get info() { throw new Error('blocked'); } }), 'unknown');
});

test('the vendor is read once from the adapter the game uses and reported as the enum only', async () => {
  let reads = 0;
  class Adapter {
    get info() { reads++; return { vendor: 'NVIDIA', device: 'Canary GPU 9000', description: 'Canary driver 1.2.3' }; }
    async requestDevice() { return { device: 1 }; }
  }
  const report = installDeviceRetry({ gpu: { requestAdapter: async () => new Adapter() }, Adapter, wait: async () => {} });
  assert.equal(report.vendor, null, 'nothing is read before the game asks for a device');
  await new Adapter().requestDevice({});
  await new Adapter().requestDevice({});
  assert.equal(report.vendor, 'nvidia');
  assert.equal(reads, 1);
  assert.doesNotMatch(JSON.stringify(report), /Canary/);
});

test('the status message carries the vendor in the existing gpu object', () => {
  const source = readFileSync(new URL('../../src/OsbManager/Browser/bridge.js', import.meta.url), 'utf8');
  assert.match(source, /gpu: \{ retries: gpuReport\.retries, limit: gpuReport\.limit, failed: gpuReport\.failed \|\| null, retryIn: gpuReport\.retryIn\(\), vendor: gpuReport\.vendor \}/);
});
