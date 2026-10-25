// Progressive enhancement for the Rails-rendered unsubscribe progress card
// (settings/external_services/rss/_deletion). The card is complete without
// this script: it shows the state the server rendered. With it, the card asks
// the owner-only progress endpoint every few seconds and rewrites the same
// elements, so the role="status" region stays in place and a screen reader
// hears each change. Polling stops when the job finishes or fails, when the
// page is hidden, or when the server no longer answers for this user.

const CARD = '[data-deletion-progress]';
const BASE_INTERVAL = 3000;
const MAX_INTERVAL = 15000;
const STOP_STATUSES = [401, 403, 404];

const setText = (element, text) => {
  if (element && element.textContent !== (text || '')) {
    element.textContent = text || '';
  }
};

const setHidden = (element, hidden) => {
  if (element) element.hidden = !!hidden;
};

export const applyProgress = (card, data, root = document) => {
  if (!data || typeof data !== 'object') return;

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

  if (!data.polling) card.removeAttribute('data-poll-url');

  if (data.state === 'completed' && data.subscription_id) {
    const feed = root.querySelector(`[data-deleting-subscription-id="${data.subscription_id}"]`);
    if (feed) feed.remove();
  }
};

export const pollCard = (card, options = {}) => {
  const fetchImpl = options.fetch || (typeof window !== 'undefined' ? window.fetch.bind(window) : null);
  const schedule = options.setTimeout || setTimeout;
  const cancel = options.clearTimeout || clearTimeout;
  const root = options.root || document;
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
      interval = BASE_INTERVAL;
      if (!data.polling) {
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

export const initializeDeletionProgress = (root = document, options = {}) => (
  Array.from(root.querySelectorAll(CARD))
    .filter((card) => card.getAttribute('data-poll-url'))
    .map((card) => pollCard(card, { ...options, root }))
);
