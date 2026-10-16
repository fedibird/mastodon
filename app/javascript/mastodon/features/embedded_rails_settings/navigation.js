import { FILTER_SETTINGS_ROUTE } from './registry';

const originScroll = new Map();

export const settingsReturnScroll = (previous, location) => {
  const source = originScroll.get(location.key);
  return previous?.pathname === FILTER_SETTINGS_ROUTE && source?.path === safeReactReturnTo(location) ? source.position : undefined;
};

export const safeReactReturnTo = location => {
  const path = location?.pathname;
  if (typeof path !== 'string' || !path.startsWith('/') || path.startsWith('//') || /[\\?#\u0000-\u0020]/.test(path) || path.startsWith(FILTER_SETTINGS_ROUTE)) return null;
  const search = location.search || '';
  const hash = location.hash || '';
  if ((search && !search.startsWith('?')) || (hash && !hash.startsWith('#')) || /[\\\u0000-\u0020]/.test(search + hash)) return null;
  return path + search + hash;
};

// Track only observed React PUSH transitions, never an external referrer or a
// query/state-supplied return URL. Retain the origin for Back/Forward's same key.
export const trackSettingsOrigin = (state, location, action) => {
  if (state.lastLocation === location) return null;
  const origins = { ...state.origins };
  if (location.pathname === FILTER_SETTINGS_ROUTE && action === 'PUSH' && location.key && !Object.prototype.hasOwnProperty.call(origins, location.key)) {
    origins[location.key] = safeReactReturnTo(state.lastLocation);
    if (origins[location.key]) {
      // Capture before the shorter settings column clamps the document scroll
      // and races the scroll library’s asynchronous position persistence.
      const visible = Array.from(document.querySelectorAll('.status[data-id]')).find(node => {
        const rect = node.getBoundingClientRect();
        return rect.width > 0 && rect.bottom > 0 && rect.top < window.innerHeight;
      });
      const anchor = visible ? { id: visible.dataset.id, top: visible.getBoundingClientRect().top } : null;
      originScroll.set(state.lastLocation.key, { path: origins[location.key], position: [window.scrollX, window.scrollY], anchor });
    }
  }
  return { lastLocation: location, origins };
};

// Settle browser anchoring/loading-row changes for at most one second. This is
// event-driven, and stops immediately on user input or another React entry.
export const settleSettingsReturnScroll = (location, position) => {
  let frame;
  let timer;
  let stopped = false;
  const inputs = ['wheel', 'touchstart', 'pointerdown', 'keydown', 'resize'];
  const current = () => window.history.state?.key === location.key && window.location.pathname === `/web${location.pathname}`;
  const stop = () => {
    stopped = true;
    cancelAnimationFrame(frame);
    clearTimeout(timer);
    window.removeEventListener('scroll', settle);
    inputs.forEach(type => window.removeEventListener(type, stop, true));
  };
  const settle = () => {
    if (!current()) {
      stop();
      return;
    }
    const anchor = originScroll.get(location.key)?.anchor;
    const node = anchor && Array.from(document.querySelectorAll('.status[data-id]')).find(status => status.dataset.id === anchor.id);
    const top = node ? window.scrollY + node.getBoundingClientRect().top - anchor.top : position[1];
    if (Math.abs(window.scrollY - top) > 0.5 || window.scrollX !== position[0]) window.scrollTo(position[0], top);
  };
  frame = requestAnimationFrame(() => {
    frame = requestAnimationFrame(() => {
      if (stopped || !current()) return;
      window.addEventListener('scroll', settle, { passive: true });
      inputs.forEach(type => window.addEventListener(type, stop, true));
      timer = setTimeout(stop, 1000);
      settle();
    });
  });
  return stop;
};
