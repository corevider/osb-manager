const createAutoLogin = ({ document, post, session, enterWorld, now, inputEvent }) => {
  const GRACE_MS = 8000;
  const STEP_MS = 1500;
  const RETRY_MS = 20000;
  const ANSWER_MS = 10000;
  const ENTER_MS = 20000;
  const ROSTER_MS = 10000;
  const MAX_TRIES = 2;
  const MAX_SERVER_WAITS = 5;
  const BUSY = new Set(['authenticating', 'listing-servers', 'loading-roster', 'connecting', 'entering-world', 'reconnecting']);

  const loadedAt = now();
  let config = { enabled: false, character: '', server: '' };
  let stage = 'off';
  let message = '';
  let tries = 0;
  let triedAt = -Infinity;
  let askedAt = 0;
  let nextAt = 0;
  let serverReady = false;
  let serverStep = 0;
  let serverWaits = 0;
  let selectSince = -Infinity;
  let enteredAt = -Infinity;
  let enterTries = 0;

  const set = (next, text = '') => { stage = next; message = text; };
  const visible = el => !!el && !el.disabled && !!(el.offsetWidth || el.offsetHeight);
  const controls = prefix => [...document.querySelectorAll('[data-ui-id]')].filter(el => String(el.dataset.uiId).startsWith(prefix) && visible(el));
  const control = id => controls(id).find(el => el.dataset.uiId === id) || null;
  const same = (a, b) => String(a ?? '').trim().toLowerCase() === String(b ?? '').trim().toLowerCase();
  const fill = (input, value) => {
    const setter = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(input), 'value')?.set;
    if (setter) setter.call(input, value); else input.value = value;
    input.dispatchEvent(inputEvent());
  };
  const state = () => { try { return session() || {}; } catch { return {}; } };

  const chooseServer = t => {
    if (serverStep === 0) {
      control('native:servers').click();
      serverStep = 1; serverWaits = 0; nextAt = t + STEP_MS;
      return set('server');
    }
    if (serverStep === 1) {
      const servers = controls('server:');
      if (!servers.length) {
        if (++serverWaits > MAX_SERVER_WAITS) { serverStep = 0; serverReady = true; }
        nextAt = t + STEP_MS;
        return;
      }
      const wanted = config.server
        ? servers.find(s => same(s.dataset.uiId.slice(7), config.server) || same(s.getAttribute('aria-label') || s.textContent, config.server))
        : servers.find(s => s.getAttribute('aria-pressed') === 'true') || servers[0];
      if (!wanted) {
        control('native:server-cancel')?.click();
        serverStep = 0;
        return set('failed', 'Server "' + config.server + '" is not in the server list.');
      }
      wanted.click();
      serverStep = 2; nextAt = t + STEP_MS;
      return;
    }
    control('native:server-accept')?.click();
    serverStep = 0; serverReady = true; nextAt = t + STEP_MS;
  };

  const pickCharacter = (t, roster) => {
    tries = 0;
    if (selectSince < 0) selectSince = t;
    if (!config.character) return set('choose', 'Choose a character.');
    if (t - enteredAt < ENTER_MS) return set('entering');
    if (enterTries >= MAX_TRIES) return set('failed', 'Could not enter ' + config.character + '.');
    let name = config.character;
    if (Array.isArray(roster)) {
      const match = roster.find(c => same(c?.name, config.character));
      if (!match) {
        const names = roster.map(c => c?.name).filter(n => typeof n === 'string').join(', ').slice(0, 120);
        return set('failed', 'No character named ' + config.character + ' on this account' + (names ? ' (' + names + ').' : '.'));
      }
      if (match.deletePending) return set('failed', match.name + ' is waiting to be deleted.');
      name = match.name;
    } else if (t - selectSince < ROSTER_MS) {
      return set('character');
    }
    if (!enterWorld(name)) return set('failed', 'Could not reach the game to enter ' + name + '.');
    enteredAt = t; enterTries++;
    set('entering');
  };

  const tick = () => {
    const t = now();
    if (!config.enabled) return set('off');
    if (stage === 'failed') return;
    const { phase, characters, error } = state();
    if (phase === 'world') { tries = 0; enterTries = 0; serverReady = false; selectSince = -Infinity; return set('done'); }
    if (BUSY.has(phase)) return set('waiting');
    if (t - loadedAt < GRACE_MS || t < nextAt) return;
    if (phase === 'character-select') return pickCharacter(t, characters);
    selectSince = -Infinity;
    if (askedAt) {
      if (t - askedAt < ANSWER_MS) return;
      askedAt = 0;
      return set('failed', 'The app did not send the login details.');
    }
    const reveal = control('frontend:reveal');
    if (reveal) { reveal.click(); nextAt = t + STEP_MS; return set('title'); }
    const account = control('account'), password = control('password'), connect = control('login');
    if (!serverReady && serverStep === 0 && !control('native:servers')) serverReady = true;
    if (serverStep > 0 || (account && password && connect && !serverReady)) return chooseServer(t);
    if (!account || !password || !connect) {
      if (stage === 'connecting' && t - triedAt > 30000) set('failed', 'Login did not finish. Check the game window.');
      return;
    }
    const reason = typeof error === 'string' && error ? error.slice(0, 160) : '';
    if (tries >= MAX_TRIES) return set('failed', 'Login did not work after ' + tries + ' tries' + (reason ? ': ' + reason : '. Check the login ID and password.'));
    if (t - triedAt < RETRY_MS) return set('retry', reason);
    askedAt = t;
    set('credentials');
    post({ type: 'credentials-request' });
  };

  const credentials = data => {
    if (!askedAt) return;
    askedAt = 0;
    if (!data || typeof data.id !== 'string' || typeof data.password !== 'string' || !data.id || !data.password) {
      return set('failed', typeof data?.reason === 'string' ? data.reason.slice(0, 200) : 'No login details are saved for this account.');
    }
    const account = control('account'), password = control('password'), connect = control('login');
    if (!account || !password || !connect) return set('waiting');
    fill(account, data.id);
    fill(password, data.password);
    tries++; triedAt = now(); nextAt = triedAt + STEP_MS;
    connect.click();
    set('connecting');
  };

  const configure = data => {
    config = {
      enabled: !!data?.enabled,
      character: String(data?.character ?? '').slice(0, 64),
      server: String(data?.server ?? '').slice(0, 64),
    };
    if (stage === 'failed') { set('off'); tries = 0; enterTries = 0; }
  };

  return { tick, credentials, configure, status: () => ({ stage, message }) };
};
