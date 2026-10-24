import { createStore, applyMiddleware } from 'redux';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({ defineMessages: messages => messages }));
jest.mock('intl-messageformat', () => function IntlMessageFormat() {
  return { format: () => 'title' };
});
jest.mock('../../locales', () => ({ getLocale: () => ({ messages: {} }) }));
jest.mock('../../stream', () => ({ connectStream: jest.fn((channel, params, factory) => factory) }));
jest.mock('../../api', () => ({ __esModule: true, default: jest.fn(), getLinks: jest.fn() }));
jest.mock('../../initial_state', () => ({ me: 'owner', maxFrequentlyUsedEmojis: 16 }));
jest.mock('mastodon/features/emoji/emoji', () => ({
  __esModule: true, default: text => text || '', buildCustomEmojis: () => [], categoriesFromEmojis: () => [],
}));

import rootReducer from '../../reducers';
import { importFetchedStatus, importFetchedStatuses } from '../importer';
import { makeGetStatus } from '../../selectors';
import { externalIdentityOf } from '../../external_presentation';

const owner = { id: 'owner', acct: 'owner', username: 'owner', display_name: 'Owner Face', note: '', url: 'https://fedibird.test/@owner', emojis: [] };

const projection = (presentation, extra = {}) => ({
  id: '9007199254740993',
  account: owner,
  content: '<p>article</p>',
  spoiler_text: '',
  media_attachments: [],
  emojis: [],
  mentions: [],
  tags: [],
  filtered: [],
  reblog: null,
  quote: null,
  poll: null,
  visibility: 'direct',
  visibility_ex: 'external',
  updated_at: '2026-10-24T00:00:00.000Z',
  fedibird_external: {
    protocol: 'rss',
    canonical_url: 'https://blog.example/posts/1',
    link_boost_revision: '1',
    presentation: { kind: 'external_source', name: 'Blog name', subtitle: 'RSS', source_url: 'https://blog.example/', icon_url: null, thumbnail_url: null, byline_name: 'Ada', ...presentation },
  },
  ...extra,
});

const setup = () => {
  const store = createStore(rootReducer, applyMiddleware(thunk));
  return store;
};

describe('external presentation in the store', () => {
  it('keeps the real Account in Redux and never writes the source identity into accounts', () => {
    const store = setup();

    store.dispatch(importFetchedStatus(projection()));
    const state = store.getState();

    expect(state.getIn(['statuses', '9007199254740993', 'account'])).toBe('owner');
    expect(state.getIn(['accounts', 'owner', 'display_name'])).toBe('Owner Face');
    expect(state.get('accounts').keySeq().toArray()).toEqual(['owner']);
    expect(JSON.stringify(state.get('accounts').toJS())).not.toContain('Blog name');

    const status = makeGetStatus()(state, { id: '9007199254740993' });

    expect(status.getIn(['account', 'id'])).toBe('owner');
    expect(status.get('visibility')).toBe('external');
    expect(status.getIn(['fedibird_external', 'presentation', 'name'])).toBe('Blog name');
    expect(externalIdentityOf(status).name).toBe('Blog name');
  });

  it('replaces the presentation on a streamed update without changing the id or the timeline membership', () => {
    const store = setup();
    const id = '9007199254740993';

    store.dispatch(importFetchedStatus(projection()));
    store.dispatch({ type: 'TIMELINE_UPDATE', timeline: 'home', status: { id }, usePendingItems: false });
    const before = store.getState().getIn(['timelines', 'home', 'items']);

    expect(before.toJS()).toContain(id);

    store.dispatch(importFetchedStatus(projection({ name: 'Renamed blog', byline_name: null, source_url: null })));
    const state = store.getState();

    expect(state.getIn(['statuses', id, 'fedibird_external', 'presentation', 'name'])).toBe('Renamed blog');
    expect(state.getIn(['statuses', id, 'fedibird_external', 'presentation', 'source_url'])).toBeNull();
    expect(state.getIn(['statuses', id, 'fedibird_external', 'link_boost_revision'])).toBe('1');
    expect(state.getIn(['timelines', 'home', 'items'])).toBe(before);
    expect(state.get('statuses').keySeq().toArray()).toEqual([id]);
    expect(externalIdentityOf(makeGetStatus()(state, { id })).sourceUrl).toBeNull();
  });

  it('shows the same identity from a compact page import', () => {
    const store = setup();
    const id = '9007199254740993';

    store.dispatch(importFetchedStatuses([projection()]));

    expect(externalIdentityOf(makeGetStatus()(store.getState(), { id })).name).toBe('Blog name');
  });

  it('adds no external identity to an ordinary status', () => {
    const store = setup();

    store.dispatch(importFetchedStatus({ ...projection(), id: '5', visibility: 'public', visibility_ex: undefined, fedibird_external: undefined }));

    expect(externalIdentityOf(makeGetStatus()(store.getState(), { id: '5' }))).toBeNull();
  });
});
