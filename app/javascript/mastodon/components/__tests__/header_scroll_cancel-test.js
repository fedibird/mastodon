// Load scroll.js only after the setter is counting. The header module captures
// its writer at import time, so a wrapper installed later cannot see the old
// same-value pin.
const sets = [];
const scrollTopOwner = () => {
  let proto = Element.prototype;

  while (proto) {
    if (Object.getOwnPropertyDescriptor(proto, 'scrollTop')) {
      return proto;
    }

    proto = Object.getPrototypeOf(proto);
  }

  return null;
};
const owner = scrollTopOwner();
const nativeScrollTop = Object.getOwnPropertyDescriptor(owner, 'scrollTop');

Object.defineProperty(owner, 'scrollTop', {
  configurable: true,
  enumerable: nativeScrollTop.enumerable,
  get: nativeScrollTop.get,
  set (value) {
    sets.push(value);
    return nativeScrollTop.set.call(this, value);
  },
});

const { isProgrammaticTopScroll, scrollTop } = require('../../scroll');

const restoreScrollTop = () => {
  Object.defineProperty(owner, 'scrollTop', nativeScrollTop);
};

describe('header scroll cancel', () => {
  let frames;

  const flushFrames = () => {
    for (let i = 0; i < 8; i += 1) {
      const batch = frames.splice(0, frames.length);

      if (batch.length === 0) {
        break;
      }

      batch.forEach(callback => callback && callback(0));
    }
  };

  beforeEach(() => {
    frames = [];
    sets.length = 0;
    jest.spyOn(window, 'requestAnimationFrame').mockImplementation((callback) => {
      frames.push(callback);
      return frames.length;
    });
  });

  afterEach(() => {
    document.body.innerHTML = '';
    jest.restoreAllMocks();
  });

  afterAll(() => {
    restoreScrollTop();
  });

  const installSmoothScroll = (element) => {
    element.scrollTo = (options = {}) => {
      if (!options || options.behavior !== 'smooth') {
        element.scrollTop = options.top || 0;
        return;
      }

      const start = element.scrollTop;
      let ticks = 0;
      const step = () => {
        if (!isProgrammaticTopScroll(element)) {
          return;
        }

        ticks += 1;
        const next = ticks >= 4 ? (options.top || 0) : start + (((options.top || 0) - start) * ticks / 4);

        nativeScrollTop.set.call(element, next);

        if (next !== (options.top || 0)) {
          requestAnimationFrame(step);
        }
      };

      requestAnimationFrame(step);
    };
  };

  it('does not assign scrollTop after its session ends or after a newer session starts', () => {
    const node = document.createElement('div');

    document.body.appendChild(node);
    nativeScrollTop.set.call(node, 1800);
    installSmoothScroll(node);
    sets.length = 0;
    const first = scrollTop(node);

    flushFrames();
    expect(node.scrollTop).toBe(0);
    expect(isProgrammaticTopScroll(node)).toBe(false);
    node.scrollTop = 640;
    const moved = sets.slice();

    sets.length = 0;
    first();
    first();
    node.dispatchEvent(new WheelEvent('wheel', { bubbles: true }));
    expect(sets).toEqual([]);
    expect(node.scrollTop).toBe(640);
    expect(moved).toEqual([640]);

    nativeScrollTop.set.call(node, 900);
    installSmoothScroll(node);
    const older = scrollTop(node);
    const newer = scrollTop(node);
    const top = node.scrollTop;

    sets.length = 0;
    older();
    expect(isProgrammaticTopScroll(node)).toBe(true);
    expect(sets).toEqual([]);
    expect(node.scrollTop).toBe(top);
    newer();
    expect(isProgrammaticTopScroll(node)).toBe(false);
    newer();
    expect(sets).toEqual([top]);
  });

  it('does not treat an early scrollend as the end of the header scroll', () => {
    const node = document.createElement('div');

    document.body.appendChild(node);
    nativeScrollTop.set.call(node, 1600);
    installSmoothScroll(node);
    sets.length = 0;
    const cancel = scrollTop(node);

    node.dispatchEvent(new Event('scrollend'));
    expect(isProgrammaticTopScroll(node)).toBe(true);
    expect(node.scrollTop).toBe(1600);
    cancel();
    expect(isProgrammaticTopScroll(node)).toBe(false);
    expect(sets).toEqual([1600]);
    cancel();
    expect(sets).toEqual([1600]);
  });

  it('does not let an older fallback animation finish the newer header session', () => {
    const proto = Object.getPrototypeOf(document.documentElement.style);
    const behavior = Object.getOwnPropertyDescriptor(proto, 'scrollBehavior');

    delete proto.scrollBehavior;

    const node = document.createElement('div');
    let now = 10000;
    const clock = jest.spyOn(Date, 'now').mockImplementation(() => now);

    document.body.appendChild(node);
    nativeScrollTop.set.call(node, 900);

    try {
      sets.length = 0;
      scrollTop(node);
      now = 10500;
      scrollTop(node);
      const during = node.scrollTop;

      now = 11000;
      flushFrames();
      expect(isProgrammaticTopScroll(node)).toBe(true);
      expect(node.scrollTop).toBeGreaterThan(10);
      expect(node.scrollTop).not.toBe(0);
      expect(during).toBe(900);
    } finally {
      clock.mockRestore();
      if (behavior) {
        Object.defineProperty(proto, 'scrollBehavior', behavior);
      }
    }
  });
});
