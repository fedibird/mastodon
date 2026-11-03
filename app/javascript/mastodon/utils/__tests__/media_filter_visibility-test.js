import { fromJS } from 'immutable';

jest.mock('mastodon/initial_state', () => ({ me: 'viewer' }));

import { mediaStatusFiltered } from '../media_filter_visibility';

const filters = fromJS({
  hide: { context: ['home', 'account'], filter_action: 'hide', expires_at: null },
  warn: { context: ['home', 'public'], filter_action: 'warn', expires_at: null },
  expired: { context: ['account'], filter_action: 'hide', expires_at: 1 },
});

describe('image navigation filter parity with status rows', () => {
  const status = fromJS({
    id: 's1', account: 'author', filtered: [{ filter: 'hide' }],
  });

  it('skips active hide filters in the same context but not another context', () => {
    expect(mediaStatusFiltered(status, null, 's1', 'account', { filters })).toBe(true);
    expect(mediaStatusFiltered(status, null, 's1', 'public', { filters })).toBe(false);
  });

  it('also skips warning-masked posts, whose normal status row replaces media with a notice', () => {
    const warning = status.set('filtered', fromJS([{ filter: 'warn' }]));
    expect(mediaStatusFiltered(warning, null, 's1', 'public', { filters })).toBe(true);
  });

  it('ignores expired filters and does not filter own posts', () => {
    const old = status.set('filtered', fromJS([{ filter: 'expired' }]));
    expect(mediaStatusFiltered(old, null, 's1', 'account', { filters })).toBe(false);
    expect(mediaStatusFiltered(status.set('account', 'viewer'), null, 's1', 'account', { filters })).toBe(false);
  });

  it('uses reconciled match IDs in preference to outdated server annotations', () => {
    const clear = fromJS({ entries: { s1: { resultGeneration: 7, filterIds: [] } } });
    const hidden = fromJS({ entries: { s1: { resultGeneration: 7, filterIds: ['hide'] } } });

    expect(mediaStatusFiltered(status, null, 's1', 'account', { filters, matches: clear, generation: 7 })).toBe(false);
    expect(mediaStatusFiltered(status.set('filtered', fromJS([])), null, 's1', 'account', { filters, matches: hidden, generation: 7 })).toBe(true);
  });

  it('uses reblogged status annotations and account identity', () => {
    const reblog = fromJS({ id: 'original', account: 'author', filtered: [{ filter: 'hide' }] });
    const boost = fromJS({ id: 'boost', account: 'viewer', filtered: [] });

    expect(mediaStatusFiltered(boost, reblog, 'boost', 'home', { filters })).toBe(true);
  });

  it('accepts a manually unmasked warning, but never bypasses a hide action', () => {
    const manual = { filters, revealedFilterStatusIds: new Set(['s1']) };
    const warning = status.set('filtered', fromJS([{ filter: 'warn' }]));
    expect(mediaStatusFiltered(warning, null, 's1', 'public', manual)).toBe(false);
    expect(mediaStatusFiltered(warning, null, 's1', 'public', { filters })).toBe(true);
    expect(mediaStatusFiltered(status, null, 's1', 'account', manual)).toBe(true);

    const twoFilters = warning.set('filtered', fromJS([{ filter: 'warn' }, { filter: 'hide' }]));
    const mixedFilters = filters.setIn(['hide', 'context'], fromJS(['public']));
    expect(mediaStatusFiltered(twoFilters, null, 's1', 'public', {
      filters: mixedFilters,
      revealedFilterStatusIds: new Set(['s1']),
    })).toBe(true);
  });
});
