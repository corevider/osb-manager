const GPU_RETRY_DELAYS = [4000, 8000, 15000, 30000, 60000, 120000];
const GPU_SLOT_WAIT_MS = 120000;

const createGpuSlots = ({ post, setTimer, clearTimer, makeId, waitMs = GPU_SLOT_WAIT_MS }) => {
  const pending = new Map();
  const acquire = () => new Promise(resolve => {
    const id = String(makeId()).slice(0, 32);
    let released = false;
    const release = () => {
      if (released) return;
      released = true;
      post({ type: 'gpu-slot-done', id });
    };
    const go = () => {
      const entry = pending.get(id);
      if (!entry) return;
      pending.delete(id);
      clearTimer(entry.timer);
      resolve(release);
    };
    pending.set(id, { go, timer: setTimer(go, waitMs) });
    post({ type: 'gpu-slot', id });
  });
  const grant = id => {
    const entry = pending.get(String(id));
    if (!entry) return false;
    entry.go();
    return true;
  };
  return { acquire, grant, waiting: () => pending.size > 0 };
};

const installDeviceRetry = ({ gpu, Adapter, wait, acquire = async () => () => {}, now = () => Date.now() }) => {
  const report = { retries: 0, limit: GPU_RETRY_DELAYS.length, failed: '', nextAt: 0 };
  report.retryIn = () => report.nextAt > 0 ? Math.max(0, Math.ceil((report.nextAt - now()) / 1000)) : 0;
  if (!gpu || typeof Adapter?.prototype?.requestDevice !== 'function') return report;
  const requestDevice = Adapter.prototype.requestDevice;
  Adapter.prototype.requestDevice = async function (descriptor) {
    let adapter = this;
    report.retries = 0;
    report.failed = '';
    for (let attempt = 1; ; attempt++) {
      const release = await acquire();
      let delay;
      try {
        const device = await requestDevice.call(adapter, descriptor);
        report.failed = '';
        return device;
      } catch (error) {
        if (error?.name !== 'OperationError' || attempt > GPU_RETRY_DELAYS.length) {
          report.failed = String(error?.message || error).slice(0, 200);
          throw error;
        }
        delay = GPU_RETRY_DELAYS[attempt - 1];
        report.retries = attempt;
        report.nextAt = now() + delay;
      } finally {
        release();
      }
      await wait(delay);
      report.nextAt = 0;
      adapter = (await gpu.requestAdapter().catch(() => null)) || adapter;
    }
  };
  return report;
};
