import { applyProgress, initializeDeletionProgress, pollCard } from '../progress';

const markup = (id = 7, subscription = 41) => `
  <article class="external-service-feed" data-deleting-subscription-id="${subscription}">feed</article>
  <article id="rss-deletion-${id}" data-deletion-progress data-state="running"
           data-poll-url="/settings/external_services/rss/subscription_deletions/${id}" data-subscription-id="${subscription}">
    <span data-deletion-badge class="external-service-card__badge external-service-card__badge--warning">Deleting</span>
    <p role="status" data-deletion-message>Deleting data.</p>
    <progress max="100" value="25" data-deletion-bar>25%</progress>
    <p data-deletion-detail>50 of 200 deleted</p>
    <p data-deletion-error hidden></p>
    <form hidden><button type="submit" data-deletion-retry>Try again</button></form>
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
  it('starts one poller for each card that still has a poll url', () => {
    document.body.innerHTML = markup(7, 41) + markup(8, 42).replace('data-poll-url="/settings/external_services/rss/subscription_deletions/8"', '');
    const timers = harness();

    const pollers = initializeDeletionProgress(document, { fetch: jest.fn(), setTimeout: timers.setTimeout, clearTimeout: timers.clearTimeout });

    expect(pollers).toHaveLength(1);
    expect(timers.timers).toHaveLength(1);
  });
});
