import { fromJS } from 'immutable';

import { makeGetStatus } from '../index';

jest.mock('../../initial_state', () => ({
  me: 'me',
  enableLimitedTimeline: false,
  hideDirectFromTimeline: false,
  hidePersonalFromTimeline: false,
  maxFrequentlyUsedEmojis: 16,
}));

jest.mock('mastodon/features/emoji/emoji', () => ({
  buildCustomEmojis: () => [],
  categoriesFromEmojis: () => [],
}));

const getStatus = makeGetStatus();

const warnFilter = {
  id: '1',
  title: 'spoiler',
  context: ['home'],
  filter_action: 'warn',
  expires_at: null,
};

const buildState = ({ filters = {}, status, reblog, account, reblogAccount }) => fromJS({
  filters,
  statuses: {
    [status.id]: status,
    ...(reblog ? { [reblog.id]: reblog } : {}),
  },
  accounts: {
    [account.id]: account,
    ...(reblogAccount ? { [reblogAccount.id]: reblogAccount } : {}),
  },
  relationships: {},
});

const otherAccount = { id: 'other' };
const selfAccount = { id: 'me' };

const baseStatus = (overrides = {}) => ({
  id: 's1',
  account: otherAccount.id,
  reblog: null,
  quote_id: null,
  filtered: [{ filter: '1' }],
  ...overrides,
});

describe('makeGetStatus FilterResult pipeline', () => {
  it('keeps a warn-filtered status and sets matched_filters to the filter title', () => {
    const state = buildState({
      filters: { 1: warnFilter },
      status: baseStatus(),
      account: otherAccount,
    });

    const result = getStatus(state, { id: 's1', contextType: 'home' });

    expect(result).not.toBeNull();
    expect(result.get('matched_filters').toJS()).toEqual(['spoiler']);
    expect(result.getIn(['filtered', 0, 'filter'])).toEqual('1');
  });

  it('returns null for a hide filter in the current context', () => {
    const state = buildState({
      filters: { 1: { ...warnFilter, filter_action: 'hide' } },
      status: baseStatus(),
      account: otherAccount,
    });

    expect(getStatus(state, { id: 's1', contextType: 'home' })).toBeNull();
  });

  it('does not apply a filter whose context does not match', () => {
    const state = buildState({
      filters: { 1: { ...warnFilter, context: ['notifications'] } },
      status: baseStatus(),
      account: otherAccount,
    });

    const result = getStatus(state, { id: 's1', contextType: 'home' });

    expect(result).not.toBeNull();
    expect(result.get('matched_filters')).toEqual(false);
  });

  it('does not apply an expired filter', () => {
    const state = buildState({
      filters: { 1: { ...warnFilter, expires_at: Date.now() - 60_000 } },
      status: baseStatus(),
      account: otherAccount,
    });

    const result = getStatus(state, { id: 's1', contextType: 'home' });

    expect(result).not.toBeNull();
    expect(result.get('matched_filters')).toEqual(false);
  });

  it('collects titles from multiple matched filters', () => {
    const state = buildState({
      filters: {
        1: warnFilter,
        2: { id: '2', title: 'politics', context: ['home'], filter_action: 'warn', expires_at: null },
      },
      status: baseStatus({ filtered: [{ filter: '1' }, { filter: '2' }] }),
      account: otherAccount,
    });

    const result = getStatus(state, { id: 's1', contextType: 'home' });

    expect(result.get('matched_filters').toJS()).toEqual(['spoiler', 'politics']);
  });

  it('ignores unknown filter IDs without crashing', () => {
    const state = buildState({
      filters: { 1: warnFilter },
      status: baseStatus({ filtered: [{ filter: 'missing' }] }),
      account: otherAccount,
    });

    const result = getStatus(state, { id: 's1', contextType: 'home' });

    expect(result).not.toBeNull();
    expect(result.get('matched_filters')).toEqual(false);
  });

  it('uses the reblog FilterResult when the outer status is a reblog', () => {
    const reblogAccount = { id: 'author' };
    const state = buildState({
      filters: { 1: warnFilter },
      status: baseStatus({ filtered: [], reblog: 's2' }),
      reblog: {
        id: 's2',
        account: reblogAccount.id,
        reblog: null,
        quote_id: null,
        filtered: [{ filter: '1' }],
      },
      account: otherAccount,
      reblogAccount,
    });

    const result = getStatus(state, { id: 's1', contextType: 'home' });

    expect(result.get('matched_filters').toJS()).toEqual(['spoiler']);
  });

  it('does not drop the current user\'s own status', () => {
    const state = buildState({
      filters: { 1: { ...warnFilter, filter_action: 'hide' } },
      status: baseStatus({ account: selfAccount.id }),
      account: selfAccount,
    });

    const result = getStatus(state, { id: 's1', contextType: 'home' });

    expect(result).not.toBeNull();
    expect(result.get('matched_filters')).toEqual(false);
  });

  it('does not apply legacy notification_filters to timeline statuses', () => {
    const state = buildState({
      filters: {},
      status: baseStatus({ filtered: [], search_index: 'spam from a bot' }),
      account: otherAccount,
    }).set('notification_filters', fromJS([{
      id: '9',
      phrase: 'spam',
      context: ['home', 'notifications'],
      irreversible: true,
      whole_word: false,
      expires_at: null,
    }]));

    const result = getStatus(state, { id: 's1', contextType: 'home' });

    expect(result).not.toBeNull();
    expect(result.get('matched_filters')).toEqual(false);
  });
});
