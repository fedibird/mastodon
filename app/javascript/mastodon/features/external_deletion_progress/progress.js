// Progressive enhancement for the Rails-rendered unsubscribe progress card
// (settings/external_services/rss/_deletion). The card is complete without
// this script: it shows the state the server rendered, and Close is a normal
// form. With the script, an in-flight card asks the owner-only progress
// endpoint every few seconds and rewrites the same elements, so the
// role="status" region stays in place. Polling stops when the job finishes
// or fails, when the page is hidden, or when the server no longer answers.
// A finished card is not polled. The server sends how many milliseconds it
// remains visible; when that duration elapses, or when the page is shown
// again, one request asks the server whether the card is still visible.
// The client clock is not compared with finished_at. A failed check is
// retried only after that deadline has passed, with the same backoff cap
// as live polling. A successful answer does not start a new poll.

const CARD = '[data-deletion-progress]';
const BASE_INTERVAL = 3000;
const MAX_INTERVAL = 15000;
const STOP_STATUSES = [401, 403, 404];

const hideState = new WeakMap();
let visibilityListener = null;

const setText = (element, text) => {
  if (element && element.textContent !== (text || '')) {
    element.textContent = text || '';
  }
};

const setHidden = (element, hidden) => {
  if (element) element.hidden = !!hidden;
};

const stateFor = (card) => {
  let state = hideState.get(card);
  if (!state) {
    state = { timer: null, inflight: false };
    hideState.set(card, state);
  }
  return state;
};

const clearHide = (card, options = {}) => {
  const state = hideState.get(card);
  if (!state) return;
  if (state.timer !== null) (options.clearTimeout || clearTimeout)(state.timer);
  hideState.delete(card);
};

const scopeOf = (root) => (
  root && typeof root.querySelectorAll === 'function' ? root : document
);

// The progress card and the subscription row are separate. Only the
// subscription id in this payload is removed, and only once the job has
// completed. Doing it before the progress card is removed covers a first
// observation that is already past the 24 hour window.
const removeDeletingSubscription = (data, root) => {
  if (!data || data.state !== 'completed') return;
  if (data.subscription_id === undefined || data.subscription_id === null || data.subscription_id === '') return;

  const feed = scopeOf(root).querySelector(`[data-deleting-subscription-id="${data.subscription_id}"]`);
  if (feed) feed.remove();
};

const removeProgressCard = (card, root) => {
  card.remove();
  scopeOf(root).querySelectorAll('.external-service-deletions').forEach((section) => {
    if (!section.querySelector(CARD)) section.hidden = true;
  });
};

// One-shot retry after the visibility deadline. A check that fails before
// that timer fires leaves the original timer in place.
const scheduleHideRetry = (card, options) => {
  const state = hideState.get(card);
  if (!state || !state.deadlinePassed || !card.isConnected) return;

  const cancel = options.clearTimeout || clearTimeout;
  if (state.timer !== null) cancel(state.timer);
  const delay = state.retryDelay || BASE_INTERVAL;
  state.retryDelay = Math.min(delay * 2, MAX_INTERVAL);
  const schedule = options.setTimeout || setTimeout;
  state.timer = schedule(() => {
    state.timer = null;
    return recheckVisibility(card, options);
  }, delay);
};

const recheckVisibility = async (card, options) => {
  const state = stateFor(card);
  if (state.inflight || !card.isConnected) return;

  const url = card.getAttribute('data-status-url');
  if (!url) return;

  state.inflight = true;
  const fetchImpl = options.fetch || (typeof window !== 'undefined' ? window.fetch.bind(window) : null);
  try {
    const response = await fetchImpl(url, {
      credentials: 'same-origin',
      headers: { Accept: 'application/json' },
    });
    if (!card.isConnected) return;
    if (response.status === 404) {
      clearHide(card, options);
      removeProgressCard(card, options.root || document);
      return;
    }
    if (!response.ok) {
      if (response.status >= 500) scheduleHideRetry(card, options);
      return;
    }

    const data = await response.json();
    applyProgress(card, data, options.root || document);
    if (!card.isConnected) {
      clearHide(card, options);
      return;
    }
    if (typeof data.hide_after_ms === 'number') armHide(card, data.hide_after_ms, options);
  } catch (e) {
    scheduleHideRetry(card, options);
  } finally {
    const current = hideState.get(card);
    if (current) current.inflight = false;
  }
};

const armHide = (card, hideAfterMs, options) => {
  const state = stateFor(card);
  const cancel = options.clearTimeout || clearTimeout;
  if (state.timer !== null) cancel(state.timer);
  state.timer = null;
  state.deadlinePassed = false;
  state.retryDelay = BASE_INTERVAL;

  const ms = Number(hideAfterMs);
  if (!Number.isFinite(ms) || ms <= 0) return;

  const schedule = options.setTimeout || setTimeout;
  state.timer = schedule(() => {
    state.timer = null;
    state.deadlinePassed = true;
    return recheckVisibility(card, options);
  }, ms);
};

export const recheckOpenCards = (root = document, options = {}) => {
  root.querySelectorAll(`${CARD}[data-hide-after-ms]`).forEach((card) => {
    recheckVisibility(card, { ...options, root });
  });
};

const bindVisibilityRecheck = (root, options) => {
  if (typeof document === 'undefined') return;
  if (visibilityListener) document.removeEventListener('visibilitychange', visibilityListener);
  visibilityListener = () => {
    if (document.hidden) return;
    recheckOpenCards(root, options);
  };
  document.addEventListener('visibilitychange', visibilityListener);
};

export const applyProgress = (card, data, root = document) => {
  if (!data || typeof data !== 'object') return;

  if (data.state === 'completed') removeDeletingSubscription(data, root);
  if (data.visible === false) {
    removeProgressCard(card, root);
    return;
  }

  card.setAttribute('data-state', data.state);
  setText(card.querySelector('[data-deletion-message]'), data.message);
  setText(card.querySelector('[data-deletion-detail]'), data.detail);

  const badge = card.querySelector('[data-deletion-badge]');
  if (badge) {
    setText(badge, data.state_label);
    badge.className = `external-service-card__badge external-service-card__badge--${data.badge}`;
  }

  const bar = card.querySelector('[data-deletion-bar]');
  if (bar) {
    if (typeof data.percent === 'number') {
      bar.value = data.percent;
      bar.textContent = `${data.percent}%`;
    }
    bar.hidden = typeof data.percent !== 'number';
  }

  const error = card.querySelector('[data-deletion-error]');
  setText(error, data.error);
  setHidden(error, !data.error);

  const retry = card.querySelector('[data-deletion-retry]');
  const form = retry ? retry.closest('form') : null;
  setHidden(form, !data.retryable);

  const dismiss = card.querySelector('[data-deletion-dismiss]');
  const dismissForm = dismiss ? dismiss.closest('form') : null;
  setHidden(dismissForm, !data.dismissable);

  if (typeof data.hide_after_ms === 'number') card.setAttribute('data-hide-after-ms', String(data.hide_after_ms));
  else card.removeAttribute('data-hide-after-ms');

  if (!data.polling) card.removeAttribute('data-poll-url');
};

export const pollCard = (card, options = {}) => {
  const fetchImpl = options.fetch || (typeof window !== 'undefined' ? window.fetch.bind(window) : null);
  const schedule = options.setTimeout || setTimeout;
  const cancel = options.clearTimeout || clearTimeout;
  const root = options.root || document;
  const hideOptions = { ...options, fetch: fetchImpl, root };
  const url = card.getAttribute('data-poll-url');
  let interval = BASE_INTERVAL;
  let timer = null;
  let stopped = false;
  let inflight = false;

  const stop = () => {
    stopped = true;
    if (timer !== null) cancel(timer);
    timer = null;
  };

  const next = () => {
    if (stopped) return;
    timer = schedule(tick, interval);
  };

  const tick = async () => {
    timer = null;
    if (stopped || inflight) return;
    if (root.hidden) {
      next();
      return;
    }

    inflight = true;
    try {
      const response = await fetchImpl(url, {
        credentials: 'same-origin',
        headers: { Accept: 'application/json' },
      });
      if (STOP_STATUSES.includes(response.status)) {
        stop();
        return;
      }
      if (!response.ok) throw new Error('unavailable');

      const data = await response.json();
      applyProgress(card, data, root);
      if (!card.isConnected) {
        clearHide(card, hideOptions);
        stop();
        return;
      }
      interval = BASE_INTERVAL;
      if (!data.polling) {
        if (typeof data.hide_after_ms === 'number') armHide(card, data.hide_after_ms, hideOptions);
        stop();
        return;
      }
    } catch (e) {
      interval = Math.min(interval * 2, MAX_INTERVAL);
    } finally {
      inflight = false;
    }
    next();
  };

  if (!url) return { stop };

  next();
  return { stop, tick };
};

export const initializeDeletionProgress = (root = document, options = {}) => {
  const settings = { ...options, root };
  bindVisibilityRecheck(root, settings);
  const cards = Array.from(root.querySelectorAll(CARD));
  cards.forEach((card) => {
    const ms = card.getAttribute('data-hide-after-ms');
    if (ms) armHide(card, Number(ms), settings);
  });
  return cards
    .filter((card) => card.getAttribute('data-poll-url'))
    .map((card) => pollCard(card, settings));
};
