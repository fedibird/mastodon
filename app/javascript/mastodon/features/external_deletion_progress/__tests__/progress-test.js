import { applyProgress, initializeDeletionProgress, pollCard, recheckOpenCards } from '../progress';

const statusUrl = (id) => `/settings/external_services/rss/subscription_deletions/${id}`;

const markup = (id = 7, subscription = 41) => `
  <article class="external-service-feed" data-deleting-subscription-id="${subscription}">feed</article>
  <article id="rss-deletion-${id}" data-deletion-progress data-state="running"
           data-poll-url="${statusUrl(id)}" data-status-url="${statusUrl(id)}" data-subscription-id="${subscription}">
    <span data-deletion-badge class="external-service-card__badge external-service-card__badge--warning">Deleting</span>
    <p role="status" data-deletion-message>Deleting data.</p>
    <progress max="100" value="25" data-deletion-bar>25%</progress>
    <p data-deletion-detail>50 of 200 deleted</p>
    <p data-deletion-error hidden></p>
    <form hidden><button type="submit" data-deletion-retry>Try again</button></form>
    <form hidden><button type="submit" data-deletion-dismiss>Close</button></form>
  </article>`;

const payload = (overrides = {}) => ({
  id: '7',
  state: 'running',
  badge: 'warning',
  state_label: 'Deleting',
  message: 'Deleting data.',
  detail: '100 of 200 deleted',
  error: null,
  percent: 50,
  finished: false,
  polling: true,
  retryable: false,
  dismissable: false,
  visible: true,
  hide_after_ms: null,
  subscription_id: '41',
  ...overrides,
});

const jsonResponse = (data, status = 200) => ({ ok: status < 400, status, json: () => Promise.resolve(data) });

const harness = () => {
  const timers = [];
  return {
    timers,
    setTimeout: (fn, ms) => {
      timers.push({ fn, ms }); return timers.length;
    },
    clearTimeout: () => {},
  };
};

describe('applyProgress', () => {
  beforeEach(() => {
    document.body.innerHTML = markup();
  });

  it('rewrites the text in place and keeps the status region element', () => {
    const card = document.querySelector('#rss-deletion-7');
    const region = card.querySelector('[role="status"]');

    applyProgress(card, payload());

    expect(card.querySelector('[role="status"]')).toBe(region);
    expect(card.querySelector('[data-deletion-detail]').textContent).toBe('100 of 200 deleted');
    expect(card.querySelector('progress').value).toBe(50);
    expect(card.dataset.state).toBe('running');
  });

  it('hides the bar while the total is unknown', () => {
    const card = document.querySelector('#rss-deletion-7');

    applyProgress(card, payload({ percent: null, detail: 'Counting' }));

    expect(card.querySelector('progress').hidden).toBe(true);
    expect(card.querySelector('[data-deletion-detail]').textContent).toBe('Counting');
  });

  it('shows the error and the retry form for a failed job and stops polling', () => {
    const card = document.querySelector('#rss-deletion-7');

    applyProgress(card, payload({ state: 'failed', badge: 'unavailable', polling: false, retryable: true, error: 'Temporary error' }));

    expect(card.querySelector('[data-deletion-error]').hidden).toBe(false);
    expect(card.querySelector('[data-deletion-error]').textContent).toBe('Temporary error');
    expect(card.querySelector('form').hidden).toBe(false);
    expect(card.hasAttribute('data-poll-url')).toBe(false);
    expect(document.querySelector('[data-deleting-subscription-id]')).not.toBeNull();
  });

  it('keeps a card that retries by itself polling, and shows no retry button until the attempts are used up', async () => {
    const card = document.querySelector('#rss-deletion-7');
    const retrying = payload({ state: 'failed', retrying: true, badge: 'warning', state_label: 'Waiting to retry', polling: true, retryable: false, error: 'Temporary error', message: 'Will retry.' });
    const terminal = payload({ state: 'failed', retrying: false, badge: 'unavailable', state_label: 'Paused', polling: false, retryable: true, error: 'Temporary error', message: 'Try again.' });

    applyProgress(card, retrying);

    expect(card.getAttribute('data-poll-url')).not.toBeNull();
    expect(card.querySelector('form').hidden).toBe(true);
    expect(card.querySelector('[data-deletion-badge]').textContent).toBe('Waiting to retry');
    expect(card.querySelector('[data-deletion-message]').textContent).toBe('Will retry.');

    const fetch = jest.fn()
      .mockResolvedValueOnce(jsonResponse(retrying))
      .mockResolvedValueOnce(jsonResponse(payload({ state: 'completed', polling: false, percent: 100, message: 'Complete.' })));
    const timers = harness();
    const poller = pollCard(card, { fetch, setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout });
    await poller.tick();
    expect(timers.timers).toHaveLength(2);
    await poller.tick();
    expect(timers.timers).toHaveLength(2);
    expect(card.dataset.state).toBe('completed');

    document.body.innerHTML = markup();
    const other = document.querySelector('#rss-deletion-7');
    applyProgress(other, terminal);
    expect(other.hasAttribute('data-poll-url')).toBe(false);
    expect(other.querySelector('form').hidden).toBe(false);
  });

  it('keeps Close hidden until the job is completed', () => {
    const card = document.querySelector('#rss-deletion-7');

    applyProgress(card, payload());
    expect(card.querySelector('[data-deletion-dismiss]').closest('form').hidden).toBe(true);

    applyProgress(card, payload({ state: 'failed', polling: false, retryable: true, dismissable: false, error: 'Temporary error' }));
    expect(card.querySelector('[data-deletion-dismiss]').closest('form').hidden).toBe(true);
    expect(card.querySelector('[data-deletion-retry]').closest('form').hidden).toBe(false);
  });

  it('shows Close when a polled card completes, then removes it when the server says the window ended', async () => {
    const card = document.querySelector('#rss-deletion-7');
    const done = payload({
      state: 'completed', badge: 'connected', polling: false, finished: true, percent: 100,
      dismissable: true, visible: true, hide_after_ms: 5000, message: 'Complete.',
    });
    const fetch = jest.fn()
      .mockResolvedValueOnce(jsonResponse(done))
      .mockResolvedValueOnce(jsonResponse({ visible: false }));
    const timers = harness();
    const poller = pollCard(card, { fetch, setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout });

    await poller.tick();

    expect(card.querySelector('[data-deletion-dismiss]').closest('form').hidden).toBe(false);
    expect(card.querySelector('[data-deletion-retry]').closest('form').hidden).toBe(true);
    expect(card.getAttribute('data-hide-after-ms')).toBe('5000');
    expect(card.hasAttribute('data-poll-url')).toBe(false);
    const hideTimer = timers.timers.find((timer) => timer.ms === 5000);
    await hideTimer.fn();

    expect(fetch).toHaveBeenCalledTimes(2);
    expect(fetch).toHaveBeenLastCalledWith(statusUrl(7), {
      credentials: 'same-origin',
      headers: { Accept: 'application/json' },
    });
    expect(document.querySelector('#rss-deletion-7')).toBeNull();
    expect(document.querySelector('[data-deleting-subscription-id]')).toBeNull();
  });

  it('keeps the card and reschedules when the server says it is still visible', async () => {
    const card = document.querySelector('#rss-deletion-7');
    const done = payload({
      state: 'completed', polling: false, finished: true, dismissable: true, visible: true, hide_after_ms: 5000,
    });
    const fetch = jest.fn()
      .mockResolvedValueOnce(jsonResponse(done))
      .mockResolvedValueOnce(jsonResponse({ ...done, hide_after_ms: 8000 }));
    const timers = harness();
    const poller = pollCard(card, { fetch, setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout });

    await poller.tick();
    await timers.timers.find((timer) => timer.ms === 5000).fn();

    expect(card.isConnected).toBe(true);
    expect(card.querySelector('[data-deletion-dismiss]').closest('form').hidden).toBe(false);
    expect(timers.timers.some((timer) => timer.ms === 8000)).toBe(true);
  });

  it('removes a card the server has already hidden', () => {
    const card = document.querySelector('#rss-deletion-7');

    applyProgress(card, payload({ visible: false }));

    expect(document.querySelector('#rss-deletion-7')).toBeNull();
  });

  it('removes the deleting subscription card when the job completes', () => {
    const card = document.querySelector('#rss-deletion-7');

    applyProgress(card, payload({ state: 'completed', badge: 'connected', polling: false, finished: true, percent: 100, message: 'Complete.' }));

    expect(card.querySelector('[data-deletion-message]').textContent).toBe('Complete.');
    expect(document.querySelector('[data-deleting-subscription-id]')).toBeNull();
    expect(card.dataset.state).toBe('completed');
  });

  it('ignores a malformed payload', () => {
    const card = document.querySelector('#rss-deletion-7');

    applyProgress(card, null);
    applyProgress(card, 'x');

    expect(card.dataset.state).toBe('running');
  });
});

describe('pollCard', () => {
  beforeEach(() => {
    document.body.innerHTML = markup();
  });

  it('asks the owner endpoint with same-origin credentials and schedules the next poll', async () => {
    const card = document.querySelector('#rss-deletion-7');
    const fetch = jest.fn(() => Promise.resolve(jsonResponse(payload())));
    const timers = harness();

    const poller = pollCard(card, { fetch, setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout });
    expect(timers.timers).toHaveLength(1);
    expect(timers.timers[0].ms).toBe(3000);

    await poller.tick();

    expect(fetch).toHaveBeenCalledWith('/settings/external_services/rss/subscription_deletions/7', {
      credentials: 'same-origin',
      headers: { Accept: 'application/json' },
    });
    expect(card.querySelector('[data-deletion-detail]').textContent).toBe('100 of 200 deleted');
    expect(timers.timers).toHaveLength(2);
  });

  it('stops after the job finishes', async () => {
    const card = document.querySelector('#rss-deletion-7');
    const fetch = jest.fn(() => Promise.resolve(jsonResponse(payload({ state: 'completed', polling: false, percent: 100 }))));
    const timers = harness();

    const poller = pollCard(card, { fetch, setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout });
    await poller.tick();

    expect(timers.timers).toHaveLength(1);
    expect(card.dataset.state).toBe('completed');
  });

  it.each([401, 403, 404])('stops for a user the server no longer answers for (%i)', async (status) => {
    const card = document.querySelector('#rss-deletion-7');
    const timers = harness();

    const poller = pollCard(card, { fetch: () => Promise.resolve(jsonResponse({}, status)), setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout });
    expect(timers.timers).toHaveLength(1);
    await poller.tick();

    expect(timers.timers).toHaveLength(1);
    expect(card.querySelector('[data-deletion-detail]').textContent).toBe('50 of 200 deleted');
  });

  it('backs off on a network error without rewriting the card, up to 15 seconds', async () => {
    const card = document.querySelector('#rss-deletion-7');
    const fetch = jest.fn(() => Promise.reject(new Error('offline')));
    const timers = harness();

    const poller = pollCard(card, { fetch, setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout });
    for (let i = 0; i < 5; i += 1) {
      // eslint-disable-next-line no-await-in-loop
      await poller.tick();
    }

    expect(timers.timers.map((timer) => timer.ms)).toEqual([3000, 6000, 12000, 15000, 15000, 15000]);
    expect(card.querySelector('[data-deletion-detail]').textContent).toBe('50 of 200 deleted');
  });

  it('does not poll while the page is hidden and does not overlap requests', async () => {
    const card = document.querySelector('#rss-deletion-7');
    const fetch = jest.fn(() => Promise.resolve(jsonResponse(payload())));
    const timers = harness();
    const root = { hidden: true, querySelector: () => null };

    const poller = pollCard(card, { fetch, setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout, root });
    await poller.tick();

    expect(fetch).not.toHaveBeenCalled();
    expect(timers.timers).toHaveLength(2);
  });

  it('schedules nothing for a card without a poll url', () => {
    const card = document.querySelector('#rss-deletion-7');
    card.removeAttribute('data-poll-url');
    const timers = harness();

    pollCard(card, { fetch: jest.fn(), setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout });

    expect(timers.timers).toHaveLength(0);
  });
});

describe('initializeDeletionProgress', () => {
  it('schedules one server check from the rendered hide delay and does not use a resident poll', async () => {
    document.body.innerHTML = markup().replace(
      `data-poll-url="${statusUrl(7)}"`,
      'data-hide-after-ms="1500"',
    );
    const fetch = jest.fn(() => Promise.resolve(jsonResponse({ visible: false })));
    const timers = harness();

    const pollers = initializeDeletionProgress(document, { fetch, setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout });
    expect(pollers).toHaveLength(0);
    expect(timers.timers.map((timer) => timer.ms)).toEqual([1500]);

    await timers.timers[0].fn();

    expect(fetch).toHaveBeenCalledTimes(1);
    expect(document.querySelector('#rss-deletion-7')).toBeNull();
  });

  it('asks again when the page becomes visible, and skips the ask while it is hidden', async () => {
    document.body.innerHTML = markup().replace(
      `data-poll-url="${statusUrl(7)}"`,
      'data-hide-after-ms="60000"',
    );
    const fetch = jest.fn(() => Promise.resolve(jsonResponse({ visible: false, state: 'completed' })));
    const timers = harness();
    initializeDeletionProgress(document, { fetch, setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout });

    let hidden = true;
    Object.defineProperty(document, 'hidden', { configurable: true, get: () => hidden });
    document.dispatchEvent(new Event('visibilitychange'));
    await Promise.resolve();
    expect(fetch).not.toHaveBeenCalled();

    hidden = false;
    document.dispatchEvent(new Event('visibilitychange'));
    await Promise.resolve();
    await Promise.resolve();

    expect(fetch).toHaveBeenCalledTimes(1);
    expect(document.querySelector('#rss-deletion-7')).toBeNull();
    delete document.hidden;
  });

  it('rechecks an open completed card through the same server endpoint', async () => {
    document.body.innerHTML = markup().replace('data-state="running"', 'data-state="completed" data-hide-after-ms="10"');
    const fetch = jest.fn(() => Promise.resolve(jsonResponse(payload({ visible: true, dismissable: true, hide_after_ms: 20, state: 'completed', polling: false }))));
    const timers = harness();

    await recheckOpenCards(document, { fetch, setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout });
    await Promise.resolve();

    expect(fetch).toHaveBeenCalledWith(statusUrl(7), {
      credentials: 'same-origin',
      headers: { Accept: 'application/json' },
    });
    expect(document.querySelector('#rss-deletion-7')).not.toBeNull();
    expect(timers.timers.some((timer) => timer.ms === 20)).toBe(true);
  });

  it('starts one poller for each card that still has a poll url', () => {
    document.body.innerHTML = markup(7, 41) + markup(8, 42).replace('data-poll-url="/settings/external_services/rss/subscription_deletions/8"', '');
    const timers = harness();

    const pollers = initializeDeletionProgress(document, { fetch: jest.fn(), setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout });

    expect(pollers).toHaveLength(1);
    expect(timers.timers).toHaveLength(1);
  });
});
