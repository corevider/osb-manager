(() => {
  if (window.top !== window || location.origin !== 'https://opensro.online') return;
  const webview = window.chrome && window.chrome.webview;
  if (!webview) return;

  let frameLimit = initialFrameLimit;
  const nativeFrame = window.requestAnimationFrame.bind(window);
  const frames = new Map();
  let frameId = 0;
  let frameScheduled = 0;
  let frameDue = 0;
  const runFrames = time => {
    frameScheduled = 0;
    if (frameLimit > 0 && time < frameDue - 1) { frameScheduled = nativeFrame(runFrames); return; }
    const interval = frameLimit > 0 ? 1000 / frameLimit : 0;
    frameDue = frameDue + interval < time ? time + interval : frameDue + interval;
    const callbacks = [...frames.values()];
    frames.clear();
    for (const callback of callbacks) {
      try { callback(time); } catch (error) { setTimeout(() => { throw error; }); }
    }
  };
  window.requestAnimationFrame = callback => {
    const id = ++frameId;
    frames.set(id, callback);
    if (!frameScheduled) frameScheduled = nativeFrame(runFrames);
    return id;
  };
  window.cancelAnimationFrame = id => { frames.delete(id); };

  const gpuSlots = createGpuSlots({
    post: message => { try { webview.postMessage(message); } catch {} },
    setTimer: (callback, ms) => setTimeout(callback, ms),
    clearTimer: timer => clearTimeout(timer),
    makeId: () => Math.random().toString(36).slice(2, 14),
  });
  const gpuReport = installDeviceRetry({ gpu: navigator.gpu, Adapter: window.GPUAdapter, wait: ms => new Promise(resolve => setTimeout(resolve, ms)), acquire: gpuSlots.acquire });
  const LIGHT_SETTLE_MS = 15000;
  const ownRender = { suspended: false, previous: null, getter: null, mask: null };

  const safe = read => { try { return read(); } catch { return undefined; } };
  const text = value => value === undefined || value === null ? null : String(value).slice(0, 64);
  const number = value => typeof value === 'number' && Number.isFinite(value) ? value : null;
  const lean = () => safe(() => window.SROLean) || null;
  const botRender = () => { const render = lean()?.render; return render && typeof render.set === 'function' ? render : null; };

  const sim = { post: null, phase: null, characters: null, error: null, ready: false, readyAt: 0 };
  const dropReader = createDropReader();
  const NativeWorker = window.Worker;
  if (typeof NativeWorker === 'function') {
    const nativePost = NativeWorker.prototype.postMessage;
    window.Worker = class extends NativeWorker {
      constructor(url, options) {
        super(url, options);
        if (options?.name !== 'sro-simulation' || sim.post) return;
        sim.post = message => nativePost.call(this, message);
        const own = this.postMessage;
        this.postMessage = function (message) {
          if (message?.kind === 'session' && message.command?.kind === 'world-ready') { sim.ready = true; sim.readyAt = performance.now(); }
          return own.apply(this, arguments);
        };
        this.addEventListener('message', event => {
          const data = event.data;
          if (data?.kind === 'world' && Array.isArray(data.batch?.events)) {
            for (const ev of data.batch.events) if (ev?.kind === 'gameplay') safe(() => dropReader.gameplay(ev.state));
            return;
          }
          if (!data || data.kind !== 'session' || !data.state || typeof data.state !== 'object') return;
          const state = data.state;
          if (typeof state.phase === 'string') sim.phase = state.phase;
          if (sim.phase !== 'world') sim.ready = false;
          if (Array.isArray(state.characters)) sim.characters = state.characters;
          sim.error = typeof state.error === 'string' ? state.error : null;
        });
      }
    };
  }
  const enterWorld = character => {
    if (sim.post) { sim.post({ kind: 'session', command: { kind: 'enter-world', character } }); return true; }
    const reconnect = lean()?.reconnect;
    return typeof reconnect?.send === 'function' && !!reconnect.send({ kind: 'enter-world', character });
  };
  const session = () => ({
    phase: sim.phase ?? safe(() => lean()?.world?.phase) ?? null,
    characters: sim.characters,
    error: sim.error,
  });

  const autoLogin = createAutoLogin({
    document,
    post: message => webview.postMessage(message),
    session,
    enterWorld,
    now: () => performance.now(),
    inputEvent: () => new InputEvent('input', { bubbles: true }),
  });

  const setOwnRender = suspend => {
    if (suspend === ownRender.suspended) return;
    if (suspend) {
      const mask = document.createElement('div');
      mask.setAttribute('aria-hidden', 'true');
      mask.style.cssText = 'position:fixed!important;inset:0!important;background:#000!important;z-index:2147483645!important;pointer-events:auto!important;';
      document.documentElement.append(mask);
      ownRender.previous = Object.getOwnPropertyDescriptor(document, 'visibilityState');
      ownRender.getter = () => 'hidden';
      Object.defineProperty(document, 'visibilityState', { configurable: true, get: ownRender.getter });
      ownRender.mask = mask;
    } else {
      if (Object.getOwnPropertyDescriptor(document, 'visibilityState')?.get === ownRender.getter) {
        if (ownRender.previous) Object.defineProperty(document, 'visibilityState', ownRender.previous);
        else delete document.visibilityState;
      }
      ownRender.mask?.remove();
      ownRender.mask = ownRender.previous = ownRender.getter = null;
    }
    ownRender.suspended = suspend;
  };

  const lightState = () => {
    const render = botRender();
    return render ? !!render.suspended : ownRender.suspended;
  };

  const light = createLightControl({
    allowed: () => !sim.post || sim.phase === 'world' && sim.ready && (!!lean()?.hunt?.running || performance.now() - sim.readyAt >= LIGHT_SETTLE_MS),
    botRender,
    setOwnRender,
  });
  const reconcile = () => { if (document.documentElement) safe(() => light.tick()); };

  const status = () => {
    const bot = lean();
    const world = bot?.world;
    const stats = bot?.stats;
    const me = safe(() => world.me());
    const progression = world?.gp?.progression;
    return {
      type: 'status',
      bot: text(bot?.version),
      phase: text(sim.phase ?? world?.phase ?? (document.querySelector('[data-ui-id="frontend:reveal"], [data-ui-id="account"]') ? 'signed-out' : null)),
      character: text(world?.charName),
      inWorld: world ? !!safe(() => world.inWorld()) : sim.phase === 'world',
      dead: !!safe(() => world.isDead()),
      level: number(progression?.level),
      gold: text(progression?.gold),
      hp: number(me?.hpPct),
      mp: number(me?.mpPct),
      region: number(safe(() => world.pose()?.regionId)),
      hunting: !!bot?.hunt?.running,
      town: !!bot?.town?.trip,
      light: lightState(),
      lightWaiting: light.waiting(),
      linked: !!sim.post,
      gpu: { retries: gpuReport.retries, limit: gpuReport.limit, failed: gpuReport.failed || null, retryIn: gpuReport.retryIn() },
      login: autoLogin.status(),
      session: stats?.session ? {
        ms: number(stats.session.ms),
        kills: number(stats.session.kills),
        deaths: number(stats.session.deaths),
        xp: stats.xpKnown ? text(stats.session.xp) : null,
        gold: stats.goldKnown ? text(stats.session.gold) : null,
        sox: number(stats.session.sox),
      } : null,
      drops: dropReader.take(),
      received: dropReader.takeReceived(),
      scrolls: safe(() => scrollCounts(world.items())) ?? null,
    };
  };

  webview.addEventListener('message', event => {
    const data = event.data;
    if (data && data.type === 'light') {
      safe(() => light.set(data.on));
    } else if (data && data.type === 'frame-limit') {
      frameLimit = Math.max(0, Math.min(1000, Number(data.fps) || 0));
      frameDue = 0;
    } else if (data && data.type === 'auto-login') {
      autoLogin.configure(data);
    } else if (data && data.type === 'credentials') {
      safe(() => autoLogin.credentials(data));
    } else if (data && data.type === 'gpu-slot') {
      safe(() => gpuSlots.grant(data.id));
    }
  });

  setInterval(() => {
    reconcile();
    safe(() => autoLogin.tick());
    safe(() => webview.postMessage(status()));
  }, 1000);
})();
