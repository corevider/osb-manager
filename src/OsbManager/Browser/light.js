const createLightControl = ({ allowed, botRender, setOwnRender }) => {
  let want = false;
  let on = false;
  const apply = next => {
    const render = botRender();
    if (render) { setOwnRender(false); render.set(!next); } else setOwnRender(next);
    on = next;
  };
  const tick = () => {
    const next = want && allowed();
    if (next !== on) apply(next);
  };
  const set = value => { want = !!value; tick(); };
  return { tick, set, active: () => on, waiting: () => want && !on };
};
