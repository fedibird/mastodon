import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    formatMessage: ({ defaultMessage }, values) => {
      if (!values) {
        return defaultMessage;
      }

      return defaultMessage.replace(/\{(\w+)\}/g, (_, key) => values[key]);
    },
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
  };
});

jest.mock('mastodon/initial_state', () => ({
  isAdministrator: true,
}));

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

import api from '../../api';
import { changeCompose, changeComposeVisibility } from '../compose';
import { commitUserPostingStyle } from '../user_posting_styles';
import { POSTING_CONTEXT_FETCH_SUCCESS } from '../posting_contexts';
import { selectComposerEffectiveCreateCapability } from '../../posting_context/create_capability';
import { materializeComposerText } from '../../posting_context/materialize';
import compose from '../../reducers/compose';
import postingContextRevalidations from '../../reducers/posting_context_revalidations';
import postingContexts from '../../reducers/posting_contexts';
import relationships from '../../reducers/relationships';
import userPostingStyles from '../../reducers/user_posting_styles';
import PostingContextBarContainer from '../../features/compose/containers/posting_context_bar_container';
import { PRIMARY_COMPOSER_ID } from '../../utils/composer';

const remoteDiscovery = (accountId, acct) => ({
  schema_version: 1,
  account_id: accountId,
  status: 'resolved',
  context: {
    key: `protocol:fep-1b12-group:${accountId}`,
    source: { id: 'compat:mitra-fep-1b12', revision: 1 },
    managed: {
      hashtags: [{ name: 'circle', normalized_name: 'circle', enforcement: 'advisory', rule_id: 'group-tag' }],
      mentions: [],
    },
    requirements: { following_accounts: [] },
    constraints: { allowed_visibilities: ['public', 'unlisted'] },
    protocol: {
      activitypub: {
        audience: {
          account_id: accountId,
          acct,
          enforcement: 'required',
          rule_id: 'fep-1b12-group-audience',
        },
      },
    },
  },
  discovery: {
    mechanism: 'nodeinfo_software',
    adapter: 'mitra_group',
    authority: 'compatibility',
  },
  viewer_evidence: {
    permissions: {
      create: { status: 'unknown', source: 'fep-5219', via_relationship: null, authority: 'protocol' },
    },
  },
});

const localDiscovery = {
  schema_version: 1,
  account_id: '123',
  status: 'resolved',
  context: {
    key: 'builtin:fedibird-group:123',
    source: { id: 'builtin:fedibird-group', revision: 1 },
    managed: { hashtags: [], mentions: [] },
    requirements: { following_accounts: [] },
    constraints: { allowed_visibilities: ['public', 'unlisted'] },
    protocol: { activitypub: { audience: null } },
  },
  discovery: { mechanism: 'built_in', adapter: 'fedibird_group', authority: 'server' },
};

const groupStyle = (id, accountId, label) => fromJS({
  id,
  name: label,
  icon: '📣',
  purpose: label,
  revision: 1,
  target: { kind: 'group', accountId, hashtag: null, label },
  defaults: { visibility: 'public' },
  managed: {
    hashtags: [{ name: 'circle', normalizedName: 'circle', enforcement: 'advisory' }],
  },
});

const hashtagStyle = fromJS({
  id: 'books',
  name: 'Reading',
  icon: '📚',
  purpose: 'Reading',
  revision: 1,
  target: { kind: 'hashtag', accountId: null, hashtag: 'books', label: '#books' },
  defaults: { visibility: 'public' },
  managed: {
    hashtags: [{ name: 'books', normalizedName: 'books', enforcement: 'advisory' }],
  },
});

const makeStore = () => createStore(combineReducers({
  compose,
  relationships,
  posting_contexts: postingContexts,
  posting_context_revalidations: postingContextRevalidations,
  userPostingStyles,
}), applyMiddleware(thunk));

const renderBar = store => render(
  <Provider store={store}>
    <PostingContextBarContainer />
  </Provider>,
);

const seedDiscovery = (store, accountId, data) => {
  store.dispatch({
    type: POSTING_CONTEXT_FETCH_SUCCESS,
    accountId,
    receivedAt: Date.now(),
    data,
  });
};

const flush = async () => {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
};

describe('posting style and revalidation together', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    api.mockReset();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('rechecks the remote group selected by a posting style without clearing the draft', async () => {
    const post = jest.fn(() => Promise.resolve({
      data: { state: 'running', request_id: 'job-a', account_id: '456' },
    }));
    const get = jest.fn(() => Promise.resolve({
      data: { state: 'running', request_id: 'job-a', account_id: '456' },
    }));
    api.mockImplementation(() => ({ post, get }));

    const store = makeStore();
    store.dispatch({
      type: 'USER_POSTING_STYLES_FETCH_SUCCESS',
      styles: [groupStyle('1', '456', 'group@mitra.example')],
    });
    seedDiscovery(store, '456', remoteDiscovery('456', 'group@mitra.example'));
    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));
    store.dispatch(changeCompose('Kept'));
    store.dispatch(changeComposeVisibility('unlisted'));

    const view = renderBar(store);
    const capability = selectComposerEffectiveCreateCapability(store.getState(), PRIMARY_COMPOSER_ID);
    const exclude = screen.getAllByRole('button', { name: 'Do not add #circle' });

    expect(store.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('456');
    expect(capability.delivery).toEqual({
      status: 'supported',
      authority: 'compatibility',
      adapter: 'mitra_group',
    });
    expect(exclude).toHaveLength(2);
    expect(screen.getByRole('button', { name: 'Recheck' })).toBeTruthy();

    fireEvent.click(exclude[1]);
    fireEvent.click(screen.getByRole('button', { name: 'Recheck' }));
    await flush();

    const composer = store.getState().get('compose');

    expect(post).toHaveBeenCalledTimes(1);
    expect(post.mock.calls[0][0]).toEqual('/api/v1/fedibird/accounts/456/posting_context/revalidation');
    expect(composer.get('text')).toEqual('Kept');
    expect(composer.get('privacy')).toEqual('unlisted');
    expect(composer.getIn(['userPostingStyle', 'selectedId'])).toEqual('1');
    expect(composer.getIn(['userPostingStyle', 'manualFields']).includes('privacy')).toBe(true);
    expect(composer.getIn(['userPostingStyle', 'suppressions']).includes('style:circle')).toBe(true);
    expect(composer.getIn(['userPostingStyle', 'suppressions']).includes('destination:circle')).toBe(false);
    expect(composer.getIn(['context', 'suppressions', 'hashtags']).includes('circle')).toBe(false);
    expect(materializeComposerText(composer)).toContain('#circle');
    expect(store.getState().getIn(['posting_context_revalidations', '456', 'requestId'])).toEqual('job-a');
    expect(store.getState().getIn(['posting_context_revalidations', '456', 'state'])).toEqual('running');
    view.unmount();
  });

  it('does not let a late status read replace the group selected afterwards', async () => {
    let resolveOlder;
    const olderGet = new Promise(resolve => {
      resolveOlder = resolve;
    });
    let discoveryGets = 0;
    const post = jest.fn(() => Promise.resolve({
      data: { state: 'running', request_id: 'job-a', account_id: '456' },
    }));
    const get = jest.fn(url => {
      const path = String(url);

      if (path.endsWith('/revalidation')) {
        return olderGet;
      }

      discoveryGets += 1;
      return Promise.resolve({ data: remoteDiscovery('456', 'group@mitra.example') });
    });
    api.mockImplementation(() => ({ post, get }));

    const store = makeStore();
    store.dispatch({
      type: 'USER_POSTING_STYLES_FETCH_SUCCESS',
      styles: [
        groupStyle('1', '456', 'group@mitra.example'),
        groupStyle('2', '789', 'other@mitra.example'),
      ],
    });
    seedDiscovery(store, '456', remoteDiscovery('456', 'group@mitra.example'));
    seedDiscovery(store, '789', remoteDiscovery('789', 'other@mitra.example'));
    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '1'));
    store.dispatch(changeCompose('Kept'));

    const view = renderBar(store);
    fireEvent.click(screen.getByRole('button', { name: 'Recheck' }));
    await flush();
    jest.advanceTimersByTime(2000);
    await flush();

    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, '2'));
    resolveOlder({
      data: {
        state: 'completed',
        request_id: 'job-a',
        account_id: '456',
        actor: 'refreshed',
        affiliations: 'refreshed',
      },
    });
    await flush();
    await flush();

    const composer = store.getState().get('compose');

    expect(composer.get('posting_context_account_id')).toEqual('789');
    expect(composer.get('text')).toEqual('Kept');
    expect(composer.getIn(['userPostingStyle', 'selectedId'])).toEqual('2');
    expect(composer.getIn(['context', 'key'])).toEqual('protocol:fep-1b12-group:789');
    expect(selectComposerEffectiveCreateCapability(store.getState(), PRIMARY_COMPOSER_ID).delivery.adapter).toEqual('mitra_group');
    expect(store.getState().getIn(['posting_context_revalidations', '789'])).toBeUndefined();
    expect(store.getState().getIn(['posting_context_revalidations', '456', 'state'])).toEqual('running');
    expect(store.getState().getIn(['posting_context_revalidations', '456', 'requestId'])).toEqual('job-a');
    expect(discoveryGets).toBe(0);
    expect(screen.getByRole('button', { name: 'Recheck' })).toBeTruthy();
    view.unmount();
  });

  it('toggles a style hashtag separately from a destination hashtag with the same name', async () => {
    api.mockImplementation(() => ({ post: jest.fn(), get: jest.fn() }));
    const store = makeStore();

    store.dispatch({
      type: 'USER_POSTING_STYLES_FETCH_SUCCESS',
      styles: [hashtagStyle],
    });
    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, 'books'));
    store.dispatch(changeCompose('Note'));

    const view = renderBar(store);
    const buttons = screen.getAllByRole('button', { name: 'Do not add #books' });

    expect(buttons).toHaveLength(2);
    expect(screen.queryByRole('button', { name: 'Recheck' })).toBeNull();

    fireEvent.click(buttons[0]);

    const composer = store.getState().get('compose');

    expect(composer.get('posting_context_account_id')).toBeNull();
    expect(composer.getIn(['userPostingStyle', 'suppressions']).includes('style:books')).toBe(true);
    expect(composer.getIn(['userPostingStyle', 'suppressions']).includes('destination:books')).toBe(false);
    expect(materializeComposerText(composer)).toEqual('Note\n\n#books');
    expect(selectComposerEffectiveCreateCapability(store.getState(), PRIMARY_COMPOSER_ID).delivery.status).toEqual('not_applicable');
    view.unmount();
  });

  it('does not offer recheck for a local group selected from a posting style', async () => {
    api.mockImplementation(() => ({ post: jest.fn(), get: jest.fn() }));
    const store = makeStore();
    const local = groupStyle('local', '123', 'localsquad').setIn(['managed', 'hashtags'], fromJS([]));

    store.dispatch({
      type: 'USER_POSTING_STYLES_FETCH_SUCCESS',
      styles: [local],
    });
    seedDiscovery(store, '123', localDiscovery);
    await store.dispatch(commitUserPostingStyle(PRIMARY_COMPOSER_ID, 'local'));

    const view = renderBar(store);
    const capability = selectComposerEffectiveCreateCapability(store.getState(), PRIMARY_COMPOSER_ID);

    expect(store.getState().getIn(['compose', 'posting_context_account_id'])).toEqual('123');
    expect(capability.delivery).toEqual({
      status: 'supported',
      authority: 'server',
      adapter: 'fedibird_group',
    });
    expect(screen.queryByRole('button', { name: 'Recheck' })).toBeNull();
    view.unmount();
  });
});
