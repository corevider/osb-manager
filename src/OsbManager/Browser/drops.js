const createDropReader = () => {
  const seen = { chat: null, notices: null };
  const drops = [];
  const received = [];
  let party = [];
  const chatDrop = (line, text) => line.channel === 7 && / has dropped /.test(text) && /\(Seal Of (Star|Moon|Sun)\)/i.test(text);
  const sunNotice = (notice, text) => notice.sunDrop === true || text.startsWith('SEAL OF SUN: ') || / has dropped /.test(text) && /\(Seal Of Sun\)/i.test(text);
  const receiveKey = /^UIIT_MSG_(PARTYGET|STATE_GET)_ITEM[A-Z_]{0,40}$/;
  const word = value => typeof value === 'string' || typeof value === 'number' ? String(value).trim().slice(0, 64) : '';
  const inParty = name => name !== '' && party.some(member => member.toLowerCase() === name.toLowerCase());
  const keepDrop = (item, text) => { if (drops.length < 50) drops.push(text.slice(0, 300)); };
  const keepReceipt = notice => {
    const key = typeof notice?.key === 'string' ? notice.key : '';
    if (!receiveKey.test(key) || received.length >= 50) return;
    const args = Array.isArray(notice.arguments) ? notice.arguments : [];
    const item = word(args[0]);
    if (!item) return;
    const partyGet = key.startsWith('UIIT_MSG_PARTYGET_');
    const member = partyGet ? word(args[2]) : '';
    const count = Number.isFinite(notice.value) ? notice.value : Number.parseInt(word(args[1]), 10);
    received.push({ key, item, count: Number.isFinite(count) ? count : null, member, inParty: partyGet && inParty(member) });
  };
  const read = (kind, items, wanted, keep) => {
    if (!Array.isArray(items)) return;
    let top = seen[kind];
    for (const item of items) {
      const seq = item?.sequence;
      if (typeof seq !== 'number' || seen[kind] !== null && seq <= seen[kind]) continue;
      top = top === null ? seq : Math.max(top, seq);
      const text = typeof item.text === 'string' ? item.text : '';
      if (seen[kind] !== null && wanted(item, text)) keep(item, text);
    }
    seen[kind] = top ?? seen[kind] ?? -1;
  };
  const sunOrReceipt = (notice, text) => {
    if (text && sunNotice(notice, text)) keepDrop(notice, text);
    else keepReceipt(notice);
  };
  return {
    gameplay(state) {
      if (Array.isArray(state?.social?.members)) party = state.social.members.map(member => word(member?.name)).filter(Boolean);
      if (state?.chat) read('chat', state.chat.lines, (line, text) => text && chatDrop(line, text), keepDrop);
      if (state?.notices) read('notices', state.notices, () => true, sunOrReceipt);
    },
    take: () => drops.splice(0, 20),
    takeReceived: () => received.splice(0, 20),
  };
};

const scrollCounts = items => {
  if (!Array.isArray(items)) return null;
  const count = type => items.filter(item => ((item?.typeFlags ?? 0) & 0xfffc) === type).reduce((total, item) => total + (Number.isFinite(item.quantity) ? item.quantity : 1), 0);
  return { ret: count(0x09ec), reverse: count(0x19ec) };
};
