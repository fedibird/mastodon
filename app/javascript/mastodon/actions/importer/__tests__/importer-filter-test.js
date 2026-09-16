import { fromJS } from 'immutable';

import { importFetchedStatuses, STATUSES_IMPORT, FILTERS_IMPORT } from '../index';
import statusesReducer from '../../../reducers/statuses';
import filtersReducer from '../../../reducers/filters';

jest.mock('../../../initial_state', () => ({
  expandSpoilers: false,
  autoPlayEmoji: false,
}));

const warnResult = {
  filter: {
    id: '1',
    title: 'spoiler',
    context: ['public'],
    expires_at: null,
    filter_action: 'warn',
  },
  keyword_matches: ['foo'],
};

const hideResult = {
  filter: {
    id: '2',
    title: 'spam',
    context: ['home'],
    expires_at: null,
    filter_action: 'hide',
  },
  keyword_matches: ['bar'],
};

const account = (id, username = `user${id}`) => ({
  id,
  username,
  acct: username,
  display_name: username,
  note: '',
  followed_message: '',
  emojis: [],
  fields: [],
  url: `https://example.com/@${username}`,
  uri: `https://example.com/users/${username}`,
});

const statusFixture = (overrides = {}) => ({
  id: 's1',
  content: '<p>hello</p>',
  spoiler_text: '',
  emojis: [],
  media_attachments: [],
  mentions: [],
  account: account('a1'),
  ...overrides,
});

const dispatchImport = (statuses) => {
  const actions = [];
  const getState = () => fromJS({
    statuses: {},
    accounts: {},
  });
  const dispatch = (action) => {
    if (typeof action === 'function') {
      action(dispatch, getState);
    } else {
      actions.push(action);
    }
  };

  importFetchedStatuses(statuses)(dispatch, getState);

  return actions;
};

const importedStatuses = (actions) => {
  const action = actions.find(item => item.type === STATUSES_IMPORT);
  return action ? action.statuses : [];
};

const importedFilters = (actions) => {
  const action = actions.find(item => item.type === FILTERS_IMPORT);
  return action ? action.filters : [];
};

const reduceImported = (actions) => {
  let statuses = statusesReducer(undefined, { type: '@@INIT' });
  let filters = filtersReducer(undefined, { type: '@@INIT' });

  actions.forEach(action => {
    statuses = statusesReducer(statuses, action);
    filters = filtersReducer(filters, action);
  });

  return { statuses, filters };
};

describe('importFetchedStatuses FilterResult canonicalization', () => {
  it('imports canonical filtered results and the Filter entity', () => {
    const actions = dispatchImport([statusFixture({ filtered: [warnResult] })]);
    const { statuses, filters } = reduceImported(actions);
    const status = importedStatuses(actions)[0];

    expect(status.filtered).toEqual([{
      filter: '1',
      keyword_matches: ['foo'],
    }]);
    expect(status.filter_results).toBeUndefined();
    expect(importedFilters(actions)).toEqual([
      { ...warnResult.filter, id: '1' },
    ]);
    expect(statuses.getIn(['s1', 'filtered', 0, 'filter'])).toEqual('1');
    expect(statuses.getIn(['s1', 'filter_results'])).toBeUndefined();
    expect(filters.getIn(['1', 'title'])).toEqual('spoiler');
    expect(filters.getIn(['1', 'context']).toJS()).toEqual(['public']);
    expect(filters.getIn(['1', 'filter_action'])).toEqual('warn');
  });

  it('canonicalizes legacy filter_results and does not keep them in Redux', () => {
    const original = statusFixture({ filter_results: [warnResult] });
    const actions = dispatchImport([original]);
    const { statuses } = reduceImported(actions);
    const status = importedStatuses(actions)[0];

    expect(original.filter_results).toEqual([warnResult]);
    expect(status.filtered).toEqual([{
      filter: '1',
      keyword_matches: ['foo'],
    }]);
    expect(status.filter_results).toBeUndefined();
    expect(importedFilters(actions)[0].id).toEqual('1');
    expect(statuses.getIn(['s1', 'filtered', 0, 'filter'])).toEqual('1');
    expect(statuses.getIn(['s1', 'filter_results'])).toBeUndefined();
  });

  it('prefers canonical filtered when both fields are present', () => {
    const actions = dispatchImport([statusFixture({
      filtered: [warnResult],
      filter_results: [hideResult],
    })]);
    const status = importedStatuses(actions)[0];
    const filters = importedFilters(actions);

    expect(status.filtered).toEqual([{
      filter: '1',
      keyword_matches: ['foo'],
    }]);
    expect(status.filter_results).toBeUndefined();
    expect(filters.map(filter => filter.id)).toEqual(['1']);
    expect(filters.map(filter => filter.title)).not.toContain('spam');
  });

  it('imports FilterResult on nested reblog and quote statuses', () => {
    const quote = statusFixture({
      id: 'quote',
      account: account('a3', 'quoted'),
      filtered: [hideResult],
      content: '<p>quoted</p>',
    });
    const reblog = statusFixture({
      id: 'reblog',
      account: account('a2', 'boosted'),
      quote,
      filtered: [warnResult],
      content: '<p>boosted</p>',
    });
    const outer = statusFixture({
      id: 'outer',
      reblog,
    });

    const actions = dispatchImport([outer]);
    const { statuses, filters } = reduceImported(actions);
    const ids = importedStatuses(actions).map(status => status.id);

    expect(ids).toEqual(expect.arrayContaining(['outer', 'reblog', 'quote']));
    expect(statuses.getIn(['reblog', 'filtered', 0, 'filter'])).toEqual('1');
    expect(statuses.getIn(['quote', 'filtered', 0, 'filter'])).toEqual('2');
    expect(statuses.getIn(['outer', 'filter_results'])).toBeUndefined();
    expect(statuses.getIn(['reblog', 'filter_results'])).toBeUndefined();
    expect(statuses.getIn(['quote', 'filter_results'])).toBeUndefined();
    expect(filters.getIn(['1', 'title'])).toEqual('spoiler');
    expect(filters.getIn(['2', 'title'])).toEqual('spam');
    expect(filters.getIn(['2', 'filter_action'])).toEqual('hide');
  });
});
