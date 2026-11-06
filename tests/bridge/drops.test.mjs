import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../../src/OsbManager/Browser/drops.js', import.meta.url), 'utf8');
const load = name => vm.runInNewContext(source + '\n' + name);
const plain = value => JSON.parse(JSON.stringify(value));

test('chat drops: the first read only sets the starting point, later Star and Moon lines on channel 7 are kept', () => {
  const reader = load('createDropReader')();
  reader.gameplay({ chat: { lines: [{ sequence: 1, channel: 7, text: 'old has dropped Item (Seal Of Star) from Mob' }] } });
  assert.deepEqual(plain(reader.take()), [], 'history before the window opened is not a new drop');
  reader.gameplay({ chat: { lines: [
    { sequence: 1, channel: 7, text: 'old has dropped Item (Seal Of Star) from Mob' },
    { sequence: 2, channel: 7, text: 'a has dropped Blaze Diadem (Seal Of Moon) from Wing Tribe Chaser' },
    { sequence: 3, channel: 1, text: 'b has dropped Thing (Seal Of Star) from Mob' },
    { sequence: 4, channel: 7, text: 'c has dropped Plain Sword from Mob' },
  ] } });
  assert.deepEqual(plain(reader.take()), ['a has dropped Blaze Diadem (Seal Of Moon) from Wing Tribe Chaser']);
});

test('Sun drops: the game announces them as a banner notice, which is read too', () => {
  const reader = load('createDropReader')();
  reader.gameplay({ notices: [{ sequence: 10, text: 'SEAL OF SUN: old has dropped Item from Mob', sunDrop: true }] });
  reader.gameplay({ notices: [
    { sequence: 11, text: 'SEAL OF SUN: sorcerer has dropped Lynx Valor Phantom from Tiger Woman', sunDrop: true },
    { sequence: 12, text: 'bard has dropped Sun Blade (Seal Of Sun) from Tiger Woman', bannerOnly: true },
    { sequence: 13, key: 'UIIT_MSG_STATE_GAIN_GOLD', text: '' },
    { sequence: 14, text: 'x has dropped +7 Item', dropPlus: true },
  ] });
  assert.deepEqual(plain(reader.take()), [
    'SEAL OF SUN: sorcerer has dropped Lynx Valor Phantom from Tiger Woman',
    'bard has dropped Sun Blade (Seal Of Sun) from Tiger Woman',
  ]);
});

test('scroll counts: return scrolls of any kind and reverse return scrolls in the bag', () => {
  const scrollCounts = load('scrollCounts');
  assert.deepEqual(plain(scrollCounts([
    { typeFlags: 0x09ec, quantity: 5 }, { typeFlags: 0x09ed, quantity: 2 }, { typeFlags: 0x19ec, quantity: 3 },
    { typeFlags: 0x19ec }, { typeFlags: 4332, quantity: 50 }, null,
  ])), { ret: 7, reverse: 4 });
  assert.equal(scrollCounts(undefined), null);
});

test('item notices: party and own pickups are kept with the member only when the member is in the party', () => {
  const reader = load('createDropReader')();
  reader.gameplay({ social: { members: [{ name: 'Alpha' }, { name: 'Beta' }] }, notices: [{ sequence: 1, key: 'UIIT_MSG_PARTYGET_ITEM_EXPENDABLE', arguments: ['Old Item', 1, 'Beta'] }] });
  assert.deepEqual(plain(reader.takeReceived()), [], 'history before the window opened is not a new pickup');
  reader.gameplay({ notices: [
    { sequence: 2, key: 'UIIT_MSG_PARTYGET_ITEM_EXPENDABLE', arguments: ['Star Blade', 1, 'beta'], value: 1 },
    { sequence: 3, key: 'UIIT_MSG_PARTYGET_ITEM', arguments: ['Moon Shield', null, 'Stranger'] },
    { sequence: 4, key: 'UIIT_MSG_STATE_GET_ITEM_EXPENDABLE', arguments: ['HP Potion', '5'] },
    { sequence: 5, key: 'UIIT_MSG_PARTYGET_GOLD', arguments: [100, 'Beta'], value: 100 },
    { sequence: 6, key: 'UIIT_MSG_STATE_GAIN_GOLD', value: 50, text: '' },
    { sequence: 7, key: 'UIIT_MSG_PARTYGET_ITEM_EXPENDABLE', arguments: ['', 1, 'Beta'] },
  ] });
  assert.deepEqual(plain(reader.takeReceived()), [
    { key: 'UIIT_MSG_PARTYGET_ITEM_EXPENDABLE', item: 'Star Blade', count: 1, member: 'beta', inParty: true },
    { key: 'UIIT_MSG_PARTYGET_ITEM', item: 'Moon Shield', count: null, member: 'Stranger', inParty: false },
    { key: 'UIIT_MSG_STATE_GET_ITEM_EXPENDABLE', item: 'HP Potion', count: 5, member: '', inParty: false },
  ]);
  assert.deepEqual(plain(reader.take()), [], 'item notices are not drop announcements');
});

test('item notices: the party list is kept between states that leave it out, and a Sun banner is still a drop', () => {
  const reader = load('createDropReader')();
  reader.gameplay({ social: { members: [{ name: 'Gamma' }] }, notices: [] });
  reader.gameplay({ notices: [
    { sequence: 1, text: 'SEAL OF SUN: Gamma has dropped Sun Bow from Mob', sunDrop: true },
    { sequence: 2, key: 'UIIT_MSG_PARTYGET_ITEM_EQUIP', arguments: ['Sun Bow', 1, 'Gamma'] },
  ] });
  assert.deepEqual(plain(reader.take()), ['SEAL OF SUN: Gamma has dropped Sun Bow from Mob']);
  assert.deepEqual(plain(reader.takeReceived()), [{ key: 'UIIT_MSG_PARTYGET_ITEM_EQUIP', item: 'Sun Bow', count: 1, member: 'Gamma', inParty: true }]);
});
