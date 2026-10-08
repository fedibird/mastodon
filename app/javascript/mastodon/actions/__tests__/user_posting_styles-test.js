import { Map as ImmutableMap, fromJS } from 'immutable';
import { createStore, applyMiddleware } from 'redux';
import thunk from 'redux-thunk';
import { combineReducers } from 'redux-immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
}));

jest.mock('../../api', () => () => ({
  get: jest.fn(() => Promise.reject(new Error('discovery should use the cache'))),
}));

import { commitUserPostingStyle } from '../user_posting_styles';
import { POSTING_CONTEXT_FETCH_SUCCESS } from '../posting_contexts';
import { selectComposerPostingContextCompliance } from '../../posting_context/compliance';
import { materializeComposerText } from '../../posting_context/materialize';
import compose from '../../reducers/compose';
import postingContexts from '../../reducers/posting_contexts';
import relationships from '../../reducers/relationships';
import userPostingStyles from '../../reducers/user_posting_styles';
import { PRIMARY_COMPOSER_ID } from '../../utils/composer';

const discovery = status => ({
  schema_version: 1,
  account_id: '123',
  status,
  reason: status === 'resolved' ? null : 'no_supported_adapter',
  context: status === 'resolved' ? {
    key: 'builtin:fedibird-group:123',
    source: { id: 'builtin:fedibird-group', revision: 1 },
    managed: {
      hashtags: [{ name: 'squad', normalized_name: 'squad', enforcement: 'required', rule_id: 'group-tag' }],
      mentions: [{ account_id: '123', acct: 'localsquad', enforcement: 'required', rule_id: 'group-account-mention' }],
    },
    requirements: {
      following_accounts: [{ account_id: '123', acct: 'localsquad', enforcement: 'required', rule_id: 'group-follow' }],
    },
    constraints: { allowed_visibilities: ['public', 'unlisted'] },
    protocol: { activitypub: { audience: null } },
  } : null,
  discovery: { mechanism: 'built_in', adapter: 'fedibird_group', authority: 'server' },
});

const style = fromJS({
  id: '1',
  name: 'サークル告知',
  icon: '📣',
  purpose: 'サークル向けの告知',
  revision: 2,
  target: { kind: 'group', accountId: '123', hashtag: null, label: 'localsquad' },
  defaults: { visibility: 'private' },
  managed: { hashtags: [{ name: 'fedibird', normalizedName: 'fedibird', enforcement: 'advisory' }] },
});

const storeWith = status => {
  const store = createStore(combineReducers({
    compose,
    posting_contexts: postingContexts,
    relationships,
    userPostingStyles,
  }), applyMiddleware(thunk));

  store.dispatch({
    type: 'USER_POSTING_STYLES_FETCH_SUCCESS',
    styles: [style],
  });
  store.dispatch({
    type: POSTING_CONTEXT_FETCH_SUCCESS,
    accountId: '123',
    data: discovery(status),
    receivedAt: Date.now(),
  });
  store.dispatch({
    type: 'RELATIONSHIPS_FETCH_SUCCESS',
    relationships: [{ id: '123', following: true, requested: false }],
  });

  return store;
};

describe('commitUserPostingStyle group destination', () => {
  it('keeps the style visibility when the group only allows public or unlisted', async () => {
    const store = storeWith('resolved');

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));

    const state = store.getState();
    const compliance = selectComposerPostingContextCompliance(state, PRIMARY_COMPOSER_ID);

    expect(state.getIn(['compose', 'privacy'])).toEqual('private');
    expect(state.getIn(['compose', 'text'])).toEqual('');
    expect(state.getIn(['compose', 'userPostingStyle', 'destinationStatus'])).toEqual('ready');
    expect(materializeComposerText(state.get('compose'))).toEqual('@localsquad\n\n#squad #fedibird');
    expect(compliance.valid).toBe(false);
    expect(compliance.visibility.valid).toBe(false);
    expect(compliance.visibility.allowed).toEqual(['public', 'unlisted']);
  });

  it('does not treat an unsupported group as postable', async () => {
    const store = storeWith('unsupported');

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));

    const state = store.getState();

    expect(state.getIn(['compose', 'userPostingStyle', 'destinationStatus'])).toEqual('failed');
    expect(state.getIn(['compose', 'userPostingStyle', 'status'])).toEqual('failed');
    expect(state.getIn(['compose', 'context', 'protocol', 'activityPub', 'audience'])).toBeNull();
    expect(selectComposerPostingContextCompliance(state, PRIMARY_COMPOSER_ID).valid).toBe(false);
    expect(materializeComposerText(state.get('compose'))).toEqual('#fedibird');
  });
});

describe('fetch failure stays usable', () => {
  it('records a failed catalog without a composer style', () => {
    const store = createStore(combineReducers({
      compose,
      userPostingStyles,
    }));

    store.dispatch({ type: 'USER_POSTING_STYLES_FETCH_FAIL' });

    expect(store.getState().getIn(['userPostingStyles', 'status'])).toEqual('failed');
    expect(store.getState().getIn(['compose', 'userPostingStyle', 'selectedId'])).toBeNull();
    expect(store.getState().getIn(['compose', 'text'])).toEqual('');
    expect(ImmutableMap.isMap(store.getState().get('compose'))).toBe(true);
  });
});
