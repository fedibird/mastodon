import { fromJS } from 'immutable';

jest.mock('../../initial_state', () => ({
  expandSpoilers: false,
  autoPlayEmoji: false,
  enableLimitedTimeline: true,
  hideDirectFromTimeline: false,
  hidePersonalFromTimeline: false,
}));

jest.mock('../../actions/statuses', () => ({
  fetchStatus: jest.fn(),
}));

import { importFetchedStatuses } from '../../actions/importer';
import filtersReducer from '../../reducers/filters';
import statusesReducer from '../../reducers/statuses';
import { statusesForSharedImport } from '../adapter';
import { buildMixView } from '../merge';

const account = {
  id: '2',
  username: 'ada',
  acct: 'ada',
  display_name: 'Ada',
  note: '',
  followed_message: '',
  emojis: [],
  fields: [],
  url: 'https://example.com/@ada',
  uri: 'https://example.com/users/ada',
};

const runImport = (state, statuses) => {
  const actions = [];
  const getState = () => state;
  const dispatch = (action) => {
    if (typeof action === 'function') {
      return action(dispatch, getState);
    }

    actions.push(action);
    return action;
  };

  importFetchedStatuses(statuses)(dispatch, getState);
  actions.forEach(action => {
    if (action.type === 'FILTERS_IMPORT') {
      state = state.set('filters', filtersReducer(state.get('filters'), action));
    }

    if (action.type === 'STATUSES_IMPORT') {
      state = state.set('statuses', statusesReducer(state.get('statuses'), action));
    }
  });

  return state;
};

describe('mix imports leave an existing home filter in place', () => {
  it('keeps a home hide result after a hashtag response is imported for the mix', () => {
    let state = fromJS({ statuses: {}, accounts: {}, polls: {}, filters: {} });

    state = runImport(state, [{
      id: '500',
      content: '<p>hidden at home</p>',
      spoiler_text: '',
      emojis: [],
      media_attachments: [],
      mentions: [],
      account,
      filtered: [{
        filter: { id: '2', title: 'spam', context: ['home'], filter_action: 'hide' },
        keyword_matches: ['bar'],
      }],
    }]);

    const previous = {};

    state.get('statuses').forEach(status => {
      previous[status.get('id')] = status.toJS();
    });

    const mixBodies = statusesForSharedImport([{
      id: '500',
      content: '<p>hidden at home</p>',
      spoiler_text: '',
      emojis: [],
      media_attachments: [],
      mentions: [],
      account,
      filtered: [],
    }], previous);

    state = runImport(state, mixBodies);

    expect(state.getIn(['statuses', '500', 'filtered', 0, 'filter'])).toBe('2');

    const hiddenAtHome = buildMixView([
      {
        key: 'home',
        ids: ['500'],
        hasMore: false,
        loaded: true,
        error: null,
        source: { type: 'home', params: { shows: { reblog: true, reply: true } } },
        filterResults: { '500': [{ filter: '2' }] },
      },
    ], { '500': state.get('statuses').get('500').toJS() }, {
      filters: [{ id: '2', title: 'spam', filter_action: 'hide', context: ['home'] }],
      contexts: { home: 'home' },
    });
    const shownOnTag = buildMixView([
      {
        key: 'home',
        ids: ['500'],
        hasMore: false,
        loaded: true,
        error: null,
        source: { type: 'home', params: { shows: { reblog: true, reply: true } } },
        filterResults: { '500': [{ filter: '2' }] },
      },
      {
        key: 'tag',
        ids: ['500'],
        hasMore: false,
        loaded: true,
        error: null,
        source: { type: 'hashtag', id: 'ruby', params: {} },
        filterResults: { '500': [] },
      },
    ], { '500': state.get('statuses').get('500').toJS() }, {
      filters: [{ id: '2', title: 'spam', filter_action: 'hide', context: ['home'] }],
      contexts: { home: 'home', tag: 'public' },
    });

    expect(hiddenAtHome.ids).toEqual([]);
    expect(shownOnTag.ids).toEqual(['500']);
    expect(shownOnTag.contextById['500']).toBe('public');
  });
});
