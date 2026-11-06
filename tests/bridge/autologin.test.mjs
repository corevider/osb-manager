import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../../src/OsbManager/Browser/autologin.js', import.meta.url), 'utf8');
const createAutoLogin = vm.runInNewContext(source + '\ncreateAutoLogin');
const plain = value => JSON.parse(JSON.stringify(value));

const element = (id, page, extra = {}) => ({
  dataset: { uiId: id },
  offsetWidth: 10,
  disabled: false,
  value: '',
  attributes: {},
  events: [],
  getAttribute(name) { return this.attributes[name] ?? null; },
  dispatchEvent(event) { this.events.push(event.type); },
  click() { page.clicks.push(id); page.onClick?.(id); },
  ...extra,
});

const setup = ({ screen = [], session = {}, config = { enabled: true, character: '', server: '' } } = {}) => {
  const page = { clicks: [], posts: [], entered: [], canEnter: true, time: 0, elements: [], onClick: null, session };
  page.show = ids => { page.elements = ids.map(id => typeof id === 'string' ? element(id, page) : id); };
  page.get = id => page.elements.find(e => e.dataset.uiId === id);
  page.show(screen);
  const login = createAutoLogin({
    document: { querySelectorAll: () => page.elements },
    post: message => page.posts.push(message),
    session: () => page.session,
    enterWorld: name => { page.entered.push(name); return page.canEnter; },
    now: () => page.time,
    inputEvent: () => ({ type: 'input' }),
  });
  login.configure(config);
  page.tick = (ms = 2000) => { page.time += ms; login.tick(); return login.status(); };
  return { page, login };
};

const loginForm = ['account', 'password', 'native:servers', 'login', 'logout'];
const roster = [{ name: 'Hunter' }, { name: 'Healer' }, { name: 'Old', deletePending: true }];

test('does nothing when automatic login is off', () => {
  const { page, login } = setup({ screen: ['frontend:reveal'], config: { enabled: false } });
  page.tick(20000);
  assert.equal(login.status().stage, 'off');
  assert.deepEqual(page.clicks, []);
});

test('waits for the game to restore its own login first', () => {
  const { page } = setup({ screen: ['frontend:reveal'] });
  page.tick(4000);
  assert.deepEqual(page.clicks, []);
  page.tick(5000);
  assert.deepEqual(page.clicks, ['frontend:reveal']);
});

test('waits while the game is busy', () => {
  const { page } = setup({ screen: ['frontend:reveal'], session: { phase: 'authenticating' } });
  assert.equal(page.tick(10000).stage, 'waiting');
  assert.deepEqual(page.clicks, []);
});

test('picks the default server, then types the saved login and connects', () => {
  const { page, login } = setup({ screen: loginForm });
  page.onClick = id => {
    if (id === 'native:servers') page.show([element('server:global-official', page, { attributes: { 'aria-pressed': 'true' } }), element('server:test', page, { disabled: true }), 'native:server-accept', 'native:server-cancel']);
    if (id === 'native:server-accept') page.show(loginForm);
  };
  page.tick(9000);
  page.tick();
  page.tick();
  assert.deepEqual(page.clicks, ['native:servers', 'server:global-official', 'native:server-accept']);

  assert.equal(page.tick().stage, 'credentials');
  assert.deepEqual(plain(page.posts), [{ type: 'credentials-request' }]);

  login.credentials({ type: 'credentials', id: 'demo_account', password: 'pw' });
  assert.equal(page.get('account').value, 'demo_account');
  assert.equal(page.get('password').value, 'pw');
  assert.deepEqual(page.get('password').events, ['input']);
  assert.equal(page.clicks.at(-1), 'login');
  assert.equal(login.status().stage, 'connecting');
});

test('picks a named server and fails clearly when it is missing', () => {
  const { page, login } = setup({ screen: loginForm, config: { enabled: true, server: 'Atlantis' } });
  page.onClick = id => { if (id === 'native:servers') page.show(['server:global-official', 'native:server-accept', 'native:server-cancel']); };
  page.tick(9000);
  page.tick();
  assert.equal(login.status().stage, 'failed');
  assert.match(login.status().message, /Atlantis/);
  assert.equal(page.clicks.at(-1), 'native:server-cancel');
});

test('stops after two failed logins and shows the game error', () => {
  const { page, login } = setup({ screen: ['account', 'password', 'login'] });
  for (let attempt = 0; attempt < 2; attempt++) {
    page.tick(25000);
    assert.equal(login.status().stage, 'credentials');
    login.credentials({ id: 'demo_account', password: 'wrong' });
    page.session = { phase: 'signed-out', error: 'Invalid account or password' };
  }
  page.tick(25000);
  assert.equal(login.status().stage, 'failed');
  assert.match(login.status().message, /Invalid account or password/);
  assert.equal(page.posts.length, 2);
  page.tick(60000);
  assert.equal(page.posts.length, 2);
});

test('shows the reason when the app sends no login', () => {
  const { page, login } = setup({ screen: ['account', 'password', 'login'] });
  page.tick(25000);
  login.credentials({ type: 'credentials', reason: 'No login details are saved for this account.' });
  assert.deepEqual(plain(login.status()), { stage: 'failed', message: 'No login details are saved for this account.' });
  assert.equal(page.get('password').value, '');
});

test('gives up when the app never answers', () => {
  const { page, login } = setup({ screen: ['account', 'password', 'login'] });
  page.tick(25000);
  page.tick(11000);
  assert.equal(login.status().stage, 'failed');
});

test('ignores login details nobody asked for', () => {
  const { page, login } = setup({ screen: ['account', 'password', 'login'] });
  login.credentials({ id: 'demo_account', password: 'pw' });
  assert.equal(page.get('account').value, '');
  assert.deepEqual(page.clicks, []);
});

test('enters the configured character by its roster name', () => {
  const { page, login } = setup({ session: { phase: 'character-select', characters: roster }, config: { enabled: true, character: 'healer' } });
  page.tick(9000);
  assert.deepEqual(page.entered, ['Healer']);
  assert.equal(login.status().stage, 'entering');
  page.tick(5000);
  assert.deepEqual(page.entered, ['Healer']);
});

test('leaves the character choice to the player when none is set', () => {
  const { page, login } = setup({ session: { phase: 'character-select', characters: roster } });
  page.tick(9000);
  assert.equal(login.status().stage, 'choose');
  assert.deepEqual(page.entered, []);
});

test('names the characters when the chosen one is not on the account', () => {
  const { page, login } = setup({ session: { phase: 'character-select', characters: roster }, config: { enabled: true, character: 'bard' } });
  page.tick(9000);
  assert.equal(login.status().stage, 'failed');
  assert.match(login.status().message, /No character named bard on this account \(Hunter, Healer, Old\)/);
  assert.deepEqual(page.entered, []);
});

test('does not enter a character waiting to be deleted', () => {
  const { page, login } = setup({ session: { phase: 'character-select', characters: roster }, config: { enabled: true, character: 'old' } });
  page.tick(9000);
  assert.equal(login.status().stage, 'failed');
  assert.deepEqual(page.entered, []);
});

test('waits briefly for the roster, then enters by the configured name', () => {
  const { page, login } = setup({ session: { phase: 'character-select' }, config: { enabled: true, character: 'Hunter' } });
  page.tick(9000);
  assert.equal(login.status().stage, 'character');
  page.tick(5000);
  assert.deepEqual(page.entered, []);
  page.tick(6000);
  assert.deepEqual(page.entered, ['Hunter']);
});

test('enters again once, then stops when the character does not load', () => {
  const { page, login } = setup({ session: { phase: 'character-select', characters: roster }, config: { enabled: true, character: 'Hunter' } });
  page.tick(9000);
  page.tick(21000);
  assert.deepEqual(page.entered, ['Hunter', 'Hunter']);
  page.tick(21000);
  assert.equal(login.status().stage, 'failed');
  assert.equal(page.entered.length, 2);
});

test('stops when the game cannot be reached', () => {
  const { page, login } = setup({ session: { phase: 'character-select', characters: roster }, config: { enabled: true, character: 'Hunter' } });
  page.canEnter = false;
  page.tick(9000);
  assert.equal(login.status().stage, 'failed');
  assert.match(login.status().message, /Could not reach the game/);
});

test('reports done in the world and starts again after a later logout', () => {
  const { page, login } = setup({ screen: ['frontend:reveal'], session: { phase: 'world' } });
  assert.equal(page.tick(9000).stage, 'done');
  page.session = { phase: 'signed-out' };
  page.tick();
  assert.equal(login.status().stage, 'title');
});

test('a new configuration clears a stop', () => {
  const { page, login } = setup({ screen: ['account', 'password', 'login'] });
  page.tick(25000);
  login.credentials({ reason: 'missing' });
  assert.equal(login.status().stage, 'failed');
  login.configure({ enabled: true });
  page.tick(25000);
  assert.equal(login.status().stage, 'credentials');
});
