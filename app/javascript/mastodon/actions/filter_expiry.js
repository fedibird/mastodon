export const FILTERS_EXPIRY_TICK = 'FILTERS_EXPIRY_TICK';

const MAX_DELAY = 2147483647;
const clocks = new WeakMap();

export const nextFilterExpiryAt = (filters, now) => {
  let next = null;

  (filters || []).forEach(filter => {
    if (!filter || filter.expires_at === null || filter.expires_at === undefined || filter.expires_at === '') {
      return;
    }

    const at = typeof filter.expires_at === 'number' ? filter.expires_at : Date.parse(filter.expires_at);

    if (!Number.isFinite(at) || at <= now) {
      return;
    }

    if (next === null || at < next) {
      next = at;
    }
  });

  return next;
};

const expirationsFromState = state => {
  const filters = state.get('filters');

  if (!filters || !filters.valueSeq) {
    return [];
  }

  return filters.valueSeq().toArray().map(filter => ({ expires_at: filter.get('expires_at') }));
};

export const armFilterExpiry = (dispatch, getState) => {
  let clock = clocks.get(dispatch);

  if (!clock) {
    clock = { timer: null };
    clocks.set(dispatch, clock);
  }

  clearTimeout(clock.timer);
  clock.timer = null;

  const now = Date.now();
  const next = nextFilterExpiryAt(expirationsFromState(getState()), now);

  if (next === null) {
    return;
  }

  const delay = Math.min(Math.max(0, next - now), MAX_DELAY);

  clock.timer = setTimeout(() => {
    clock.timer = null;
    dispatch({ type: FILTERS_EXPIRY_TICK, skipLoading: true });
    armFilterExpiry(dispatch, getState);
  }, delay);
};
