(() => {
  if (self.__osbWasm || typeof WebAssembly !== 'object') return;
  const NativeMemory = WebAssembly.Memory;
  const known = [];
  const track = value => {
    if (!(value instanceof NativeMemory) || known.some(ref => ref.deref() === value)) return;
    known.push(new WeakRef(value));
  };
  const scan = exports => { for (const value of Object.values(exports || {})) track(value); };
  WebAssembly.Memory = new Proxy(NativeMemory, {
    construct(target, args, newTarget) { const memory = Reflect.construct(target, args, newTarget); track(memory); return memory; },
  });
  WebAssembly.Instance = new Proxy(WebAssembly.Instance, {
    construct(target, args, newTarget) { const instance = Reflect.construct(target, args, newTarget); scan(instance.exports); return instance; },
  });
  for (const name of ['instantiate', 'instantiateStreaming']) {
    const original = WebAssembly[name];
    if (typeof original !== 'function') continue;
    WebAssembly[name] = async function () {
      const result = await original.apply(this, arguments);
      scan((result.instance || result).exports);
      return result;
    };
  }
  self.__osbWasm = () => {
    const sizes = [];
    for (const ref of known) {
      const memory = ref.deref();
      if (memory) sizes.push(memory.buffer.byteLength);
    }
    return { count: sizes.length, bytes: sizes.reduce((sum, size) => sum + size, 0) };
  };
})();
