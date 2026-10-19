const easingOutQuint = (x, t, b, c, d) => c * ((t = t / d - 1) * t * t * t * t + 1) + b;

const nativeScrollTop = (() => {
  let proto = typeof Element === 'undefined' ? null : Element.prototype;

  while (proto) {
    const descriptor = Object.getOwnPropertyDescriptor(proto, 'scrollTop');

    if (descriptor && descriptor.get && descriptor.set) {
      return descriptor;
    }

    proto = Object.getPrototypeOf(proto);
  }

  return null;
})();

// Chrome cancels a native smooth scroll when anything assigns scrollTop,
// including `scrollTop += 0`. Header scroll keeps a setter in front of the
// element so anchor, filter, and height corrections cannot abort it.
const sessions = new WeakMap();

const readTop = (node) => nativeScrollTop ? nativeScrollTop.get.call(node) : node.scrollTop;

const writeTop = (node, value) => {
  if (nativeScrollTop) {
    nativeScrollTop.set.call(node, value);
    return;
  }

  node.scrollTop = value;
};

const prefersReducedMotion = () => {
  if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') {
    return false;
  }

  return window.matchMedia('(prefers-reduced-motion: reduce)').matches === true;
};

const supportsSmoothScroll = () => 'scrollBehavior' in document.documentElement.style;

const isScrollGesture = (event) => {
  if (!event) {
    return false;
  }

  if (event.type === 'wheel' || event.type === 'touchmove') {
    return true;
  }

  if (event.type === 'pointerdown') {
    return event.pointerType === 'touch' || event.pointerType === 'pen';
  }

  if (event.type === 'pointermove') {
    return event.buttons > 0;
  }

  if (event.type !== 'keydown') {
    return false;
  }

  const target = event.target;

  if (target && (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA' || target.isContentEditable)) {
    return false;
  }

  return ['ArrowDown', 'ArrowUp', 'PageDown', 'PageUp', 'Home', 'End', ' '].indexOf(event.key) !== -1;
};

const releaseSession = (node) => {
  const session = sessions.get(node);

  if (!session || session.released) {
    return;
  }

  session.released = true;
  session.active = false;

  if (session.installed) {
    delete node.scrollTop;
  }

  session.cleanups.forEach(cleanup => cleanup());
  sessions.delete(node);
};

const pinScroll = (node) => {
  const top = readTop(node);

  releaseSession(node);

  // Assigning the current offset is what actually cancels a native smooth
  // scroll. Gesture handlers leave that to the browser; explicit cancel
  // (wheel on the column chrome, unmount) pins here.
  if (top > 0) {
    writeTop(node, top);
  }
};

const armSession = (node) => {
  releaseSession(node);

  const session = {
    active: true,
    released: false,
    allow: false,
    installed: false,
    cleanups: [],
  };

  sessions.set(node, session);

  if (nativeScrollTop) {
    Object.defineProperty(node, 'scrollTop', {
      configurable: true,
      enumerable: true,
      get () {
        return nativeScrollTop.get.call(node);
      },
      set (value) {
        if (session.active && !session.allow) {
          return;
        }

        nativeScrollTop.set.call(node, value);
      },
    });
    session.installed = true;
  }

  const onGesture = (event) => {
    if (!isScrollGesture(event)) {
      return;
    }

    releaseSession(node);
  };
  const listen = { capture: true, passive: true };

  ['wheel', 'touchmove', 'pointerdown', 'pointermove', 'keydown'].forEach(type => {
    node.addEventListener(type, onGesture, listen);
    session.cleanups.push(() => node.removeEventListener(type, onGesture, listen));
  });

  const onScrollEnd = () => releaseSession(node);

  node.addEventListener('scrollend', onScrollEnd);
  session.cleanups.push(() => node.removeEventListener('scrollend', onScrollEnd));

  let last = readTop(node);
  let idle = 0;
  const watch = () => {
    if (!session.active) {
      return;
    }

    if (!node.isConnected) {
      releaseSession(node);
      return;
    }

    const top = readTop(node);

    if (top <= 0) {
      releaseSession(node);
      return;
    }

    if (Math.abs(top - last) > 0.5) {
      idle = 0;
      last = top;
    } else if (idle > 30) {
      releaseSession(node);
      return;
    } else {
      idle += 1;
    }

    requestAnimationFrame(watch);
  };

  requestAnimationFrame(watch);

  return session;
};

const animate = (node, key, target, session) => {
  const startTime = Date.now();
  const offset = key === 'scrollTop' ? readTop(node) : node[key];
  const gap = target - offset;
  const duration = 1000;
  let stopped = false;

  const write = (value) => {
    if (key === 'scrollTop') {
      session.allow = true;
      writeTop(node, value);
      session.allow = false;
      return;
    }

    node[key] = value;
  };

  const step = () => {
    if (stopped || !session.active) {
      return;
    }

    const elapsed = Date.now() - startTime;

    if (elapsed >= duration) {
      write(target);

      if (key === 'scrollTop') {
        releaseSession(node);
      }

      return;
    }

    write(easingOutQuint(0, elapsed, offset, gap, duration));
    requestAnimationFrame(step);
  };

  step();

  return () => {
    stopped = true;
  };
};

export const isProgrammaticTopScroll = (node) => {
  const session = node && sessions.get(node);

  return !!(session && session.active);
};

export const scrollRight = (node, position) => supportsSmoothScroll() ? node.scrollTo({ left: position, behavior: 'smooth' }) : animate(node, 'scrollLeft', position, { active: true, allow: true });

export const scrollTop = (node) => {
  if (!node) {
    return undefined;
  }

  if (prefersReducedMotion()) {
    releaseSession(node);
    writeTop(node, 0);
    return () => {};
  }

  const session = armSession(node);
  let stopAnimation = () => {};

  if (supportsSmoothScroll()) {
    node.scrollTo({ top: 0, behavior: 'smooth' });
  } else {
    stopAnimation = animate(node, 'scrollTop', 0, session);
  }

  if (readTop(node) <= 0) {
    releaseSession(node);
  }

  return () => {
    stopAnimation();
    pinScroll(node);
  };
};
