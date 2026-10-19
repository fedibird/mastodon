const easingOutQuint = (x, t, b, c, d) => c * ((t = t / d - 1) * t * t * t * t + 1) + b;

// A header scroll is a session, not a scrollTop setter. Native smooth scroll
// dies on any assignment, including the current offset, so corrections yield
// while the session is active and a cancel closure writes only for the
// session that created it.
const sessions = new WeakMap();
let nextSessionId = 1;

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
  session.cleanups.forEach(cleanup => cleanup());
  sessions.delete(node);
};

// An in-flight native smooth scroll keeps moving through a same-value
// scrollTop write. behavior:instant is what actually aborts it. The closure
// may do this only while its own session is still active.
const pinScroll = (node) => {
  const top = node.scrollTop;

  releaseSession(node);

  if (top <= 0 || typeof node.scrollTo !== 'function') {
    return;
  }

  try {
    node.scrollTo({ top, behavior: 'instant' });
  } catch (error) {
    node.scrollTop = top;
  }
};

const armSession = (node) => {
  releaseSession(node);

  const session = {
    id: nextSessionId,
    active: true,
    released: false,
    cleanups: [],
  };

  nextSessionId += 1;
  sessions.set(node, session);

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

  // Chrome can emit scrollend once while a smooth scroll is still moving.
  // Releasing there drops the session before the top, so a later cancel can
  // no longer pin the animation.
  const onScrollEnd = () => {
    if (node.scrollTop <= 0) {
      releaseSession(node);
    }
  };

  node.addEventListener('scrollend', onScrollEnd);
  session.cleanups.push(() => node.removeEventListener('scrollend', onScrollEnd));

  let last = node.scrollTop;
  let idle = 0;
  const watch = () => {
    if (!session.active) {
      return;
    }

    if (!node.isConnected) {
      releaseSession(node);
      return;
    }

    const top = node.scrollTop;

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

const animate = (node, key, target) => {
  const startTime = Date.now();
  const offset = node[key];
  const gap = target - offset;
  const duration = 1000;
  let stopped = false;

  const step = () => {
    if (stopped) {
      return;
    }

    if (key === 'scrollTop') {
      const session = sessions.get(node);

      if (!session || !session.active) {
        return;
      }
    }

    const elapsed = Date.now() - startTime;
    const done = elapsed >= duration;

    node[key] = done ? target : easingOutQuint(0, elapsed, offset, gap, duration);

    if (done) {
      if (key === 'scrollTop') {
        releaseSession(node);
      }

      return;
    }

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

// Explicit navigation replaces the header animation. Filter and height
// corrections must not call this; they yield until the header scroll ends.
export const releaseProgrammaticTopScroll = (node) => {
  if (node) {
    releaseSession(node);
  }
};

export const scrollRight = (node, position) => supportsSmoothScroll() ? node.scrollTo({ left: position, behavior: 'smooth' }) : animate(node, 'scrollLeft', position);

export const scrollTop = (node) => {
  if (!node) {
    return undefined;
  }

  if (prefersReducedMotion()) {
    releaseSession(node);
    node.scrollTop = 0;
    return () => {};
  }

  const session = armSession(node);
  const sessionId = session.id;
  let stopAnimation = () => {};

  if (supportsSmoothScroll()) {
    node.scrollTo({ top: 0, behavior: 'smooth' });
  } else {
    stopAnimation = animate(node, 'scrollTop', 0);
  }

  if (node.scrollTop <= 0) {
    releaseSession(node);
  }

  return () => {
    const current = sessions.get(node);

    if (!current || current.id !== sessionId) {
      return;
    }

    stopAnimation();
    pinScroll(node);
  };
};
