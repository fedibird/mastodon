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
import { changeCompose, setComposeToStatus } from '../compose';
import { applyComposerPostingContext, createComposer, targetComposerAction } from '../composer';
import { fetchPostingContextRevalidationStatus, requestPostingContextRevalidation } from '../posting_context_revalidations';
import { mitraGroupPostingContext } from '../../posting_context/fixtures/mitra_group_context_fixture';
import { groupPostingContext } from '../../posting_context/fixtures/group_context_fixture';
import { buildHashtagTimelinePostingContext } from '../../posting_context/hashtag';
import { selectComposerEffectiveCreateCapability } from '../../posting_context/create_capability';
import composers from '../../reducers/composers';
import postingContextRevalidations from '../../reducers/posting_context_revalidations';
import postingContexts from '../../reducers/posting_contexts';
import relationships from '../../reducers/relationships';
import { ComposerProvider } from '../../features/compose/composer_id_context';
import PostingContextBarContainer from '../../features/compose/containers/posting_context_bar_container';

const composerId = 'composer-a';

const discovery = (accountId, createStatus = 'unknown') => ({
  schema_version: 1,
  account_id: accountId,
  status: 'resolved',
  context: {
    key: 'protocol:fep-1b12-group:456',
    source: { id: 'compat:mitra-fep-1b12', revision: 1 },
    managed: { hashtags: [], mentions: [] },
    requirements: { following_accounts: [] },
    constraints: { allowed_visibilities: ['public', 'unlisted'] },
    protocol: {
      activitypub: {
        audience: {
          account_id: '456',
          acct: 'group@mitra.example',
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
    affiliations: {
      source: 'fep-5219-affiliations',
      snapshot_status: 'fresh',
      fetched_at: '2026-10-08T00:00:00Z',
      relationships: [],
    },
    permissions: {
      create: {
        status: createStatus,
        source: 'fep-5219',
        via_relationship: createStatus === 'allowed' ? 'none' : null,
        authority: 'protocol',
      },
    },
  },
});

const makeStore = () => createStore(combineReducers({
  composers,
  relationships,
  posting_contexts: postingContexts,
  posting_context_revalidations: postingContextRevalidations,
}), applyMiddleware(thunk));

const renderBar = store => render(
  <Provider store={store}>
    <ComposerProvider composerId={composerId}>
      <PostingContextBarContainer />
    </ComposerProvider>
  </Provider>,
);

describe('posting context revalidation', () => {
  beforeEach(() => {
    jest.useFakeTimers();
    api.mockReset();
  });

  afterEach(() => {
    jest.useRealTimers();
  });

  it('posts only when recheck is requested and stops polling after unmount', async () => {
    const post = jest.fn(() => Promise.resolve({
      data: { state: 'queued', request_id: 'job-1', account_id: '456', requested_at: '2026-10-08T10:00:00Z' },
    }));
    const get = jest.fn(() => Promise.resolve({
      data: { state: 'running', request_id: 'job-1', account_id: '456' },
    }));
    api.mockImplementation(() => ({ post, get }));
    const store = makeStore();

    store.dispatch(createComposer(composerId));
    store.dispatch(targetComposerAction(changeCompose('Hello'), composerId));
    store.dispatch(applyComposerPostingContext(composerId, mitraGroupPostingContext, '456'));
    store.dispatch({
      type: 'POSTING_CONTEXT_FETCH_SUCCESS',
      accountId: '456',
      receivedAt: Date.now(),
      data: discovery('456', 'unknown'),
    });

    const view = renderBar(store);

    expect(post).not.toHaveBeenCalled();
    expect(screen.getByRole('button', { name: 'Recheck' })).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Recheck' }));
    await Promise.resolve();
    await Promise.resolve();

    expect(post).toHaveBeenCalledTimes(1);
    expect(post.mock.calls[0][0]).toEqual('/api/v1/fedibird/accounts/456/posting_context/revalidation');
    expect(screen.getByText('Rechecking create permission')).toBeTruthy();
    expect(store.getState().getIn(['composers', 'byId', composerId, 'text'])).toEqual('Hello');

    jest.advanceTimersByTime(2000);
    await Promise.resolve();
    expect(get).toHaveBeenCalledTimes(1);
    expect(post).toHaveBeenCalledTimes(1);

    view.unmount();
    jest.advanceTimersByTime(20000);
    await Promise.resolve();
    expect(get).toHaveBeenCalledTimes(1);
  });

  it('force-fetches discovery after a completed status and keeps the draft', async () => {
    const post = jest.fn(() => Promise.resolve({
      data: { state: 'queued', request_id: 'job-2', account_id: '456' },
    }));
    const get = jest.fn(url => Promise.resolve({
      data: String(url).endsWith('/revalidation')
        ? { state: 'completed', request_id: 'job-2', account_id: '456', actor: 'refreshed', affiliations: 'refreshed' }
        : discovery('456', 'allowed'),
    }));
    api.mockImplementation(() => ({ post, get }));
    const store = makeStore();

    store.dispatch(createComposer(composerId));
    store.dispatch(targetComposerAction(changeCompose('Draft'), composerId));
    store.dispatch({
      type: 'COMPOSE_UPLOAD_SUCCESS',
      meta: { composerId },
      media: { id: 'media-1', type: 'image' },
      file: null,
    });
    store.dispatch(applyComposerPostingContext(composerId, mitraGroupPostingContext, '456'));
    store.dispatch({
      type: 'POSTING_CONTEXT_FETCH_SUCCESS',
      accountId: '456',
      receivedAt: Date.now(),
      data: discovery('456', 'unknown'),
    });

    renderBar(store);
    fireEvent.click(screen.getByRole('button', { name: 'Recheck' }));
    await Promise.resolve();
    await Promise.resolve();
    jest.advanceTimersByTime(2000);
    await Promise.resolve();
    await Promise.resolve();

    expect(get.mock.calls.some(call => String(call[0]).endsWith('/posting_context'))).toBe(true);
    expect(store.getState().getIn(['posting_contexts', '456', 'viewerEvidence', 'permissions', 'create', 'status'])).toEqual('allowed');
    expect(store.getState().getIn(['composers', 'byId', composerId, 'text'])).toEqual('Draft');
    expect(store.getState().getIn(['composers', 'byId', composerId, 'media_attachments']).size).toBe(1);
    expect(selectComposerEffectiveCreateCapability(store.getState(), composerId).permission.viaRelationship).toEqual('none');
  });

  it('shows partial and failed states without posting again', async () => {
    const store = makeStore();

    store.dispatch(createComposer(composerId));
    store.dispatch(applyComposerPostingContext(composerId, mitraGroupPostingContext, '456'));
    store.dispatch({
      type: 'POSTING_CONTEXT_FETCH_SUCCESS',
      accountId: '456',
      receivedAt: Date.now(),
      data: discovery('456', 'unknown'),
    });
    renderBar(store);

    store.dispatch({
      type: 'POSTING_CONTEXT_REVALIDATION_UPDATE',
      accountId: '456',
      explicit: true,
      data: { state: 'partial', actor: 'refreshed', affiliations: 'failed', request_id: 'job-3' },
    });
    expect(screen.getByText('Some information could not be updated').getAttribute('title')).toEqual('Actor: refreshed / Affiliations: failed');

    store.dispatch({
      type: 'POSTING_CONTEXT_REVALIDATION_UPDATE',
      accountId: '456',
      explicit: true,
      data: { state: 'failed', actor: 'failed', affiliations: 'failed', request_id: 'job-3' },
    });
    expect(screen.getByText('Create permission could not be rechecked')).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Recheck' })).toBeTruthy();
  });

  it('shares revalidation state across composers and keeps their drafts separate', () => {
    const store = makeStore();

    store.dispatch(createComposer('composer-a'));
    store.dispatch(createComposer('composer-b'));
    store.dispatch(targetComposerAction(changeCompose('Alpha'), 'composer-a'));
    store.dispatch(targetComposerAction(changeCompose('Beta'), 'composer-b'));
    store.dispatch(applyComposerPostingContext('composer-a', mitraGroupPostingContext, '456'));
    store.dispatch(applyComposerPostingContext('composer-b', mitraGroupPostingContext, '456'));
    store.dispatch({
      type: 'POSTING_CONTEXT_REVALIDATION_UPDATE',
      accountId: '456',
      explicit: true,
      data: { state: 'running', request_id: 'shared' },
    });

    expect(store.getState().getIn(['posting_context_revalidations', '456', 'state'])).toEqual('running');
    expect(store.getState().getIn(['composers', 'byId', 'composer-a', 'text'])).toEqual('Alpha');
    expect(store.getState().getIn(['composers', 'byId', 'composer-b', 'text'])).toEqual('Beta');
  });

  it('does not apply an older target revalidation after the composer target changes', () => {
    const store = makeStore();

    store.dispatch(createComposer(composerId));
    store.dispatch(targetComposerAction(changeCompose('Stay'), composerId));
    store.dispatch(applyComposerPostingContext(composerId, mitraGroupPostingContext, '456'));
    store.dispatch({
      type: 'POSTING_CONTEXT_FETCH_SUCCESS',
      accountId: '456',
      receivedAt: Date.now(),
      data: discovery('456', 'unknown'),
    });
    store.dispatch({
      type: 'POSTING_CONTEXT_REVALIDATION_UPDATE',
      accountId: '456',
      explicit: true,
      data: { state: 'failed', actor: 'failed', affiliations: 'failed', request_id: 'old-target' },
    });

    renderBar(store);
    expect(screen.getByText('Create permission could not be rechecked')).toBeTruthy();

    store.dispatch(applyComposerPostingContext(composerId, buildHashtagTimelinePostingContext('news'), null));

    expect(screen.queryByText('Create permission could not be rechecked')).toBeNull();
    expect(store.getState().getIn(['composers', 'byId', composerId, 'text'])).toEqual('Stay');
    expect(store.getState().getIn(['posting_context_revalidations', '456', 'state'])).toEqual('failed');
  });

  it('does not offer recheck for a local group, a hashtag composer, or an existing edit', () => {
    const store = makeStore();
    const localDiscovery = {
      schema_version: 1,
      account_id: '123',
      status: 'resolved',
      context: {
        key: 'builtin:fedibird-group:123',
        source: { id: 'builtin:fedibird-group', revision: 1 },
        managed: {
          hashtags: [],
          mentions: [{ account_id: '123', acct: 'group', enforcement: 'required', rule_id: 'group-account-mention' }],
        },
        requirements: {
          following_accounts: [{ account_id: '123', acct: 'group', enforcement: 'required', rule_id: 'group-follow' }],
        },
        constraints: { allowed_visibilities: ['public', 'unlisted'] },
      },
      discovery: { mechanism: 'built_in', adapter: 'fedibird_group', authority: 'server' },
    };

    store.dispatch(createComposer(composerId));
    store.dispatch(applyComposerPostingContext(composerId, groupPostingContext, '123'));
    store.dispatch({
      type: 'RELATIONSHIPS_FETCH_SUCCESS',
      relationships: [{ id: '123', following: true, requested: false }],
    });
    store.dispatch({
      type: 'POSTING_CONTEXT_FETCH_SUCCESS',
      accountId: '123',
      receivedAt: Date.now(),
      data: localDiscovery,
    });
    const local = renderBar(store);
    expect(screen.queryByRole('button', { name: 'Recheck' })).toBeNull();
    local.unmount();

    store.dispatch(applyComposerPostingContext(composerId, buildHashtagTimelinePostingContext('foo'), null));
    const hashtag = renderBar(store);
    expect(screen.queryByRole('button', { name: 'Recheck' })).toBeNull();
    hashtag.unmount();

    store.dispatch(applyComposerPostingContext(composerId, mitraGroupPostingContext, '456'));
    store.dispatch({
      type: 'POSTING_CONTEXT_FETCH_SUCCESS',
      accountId: '456',
      receivedAt: Date.now(),
      data: discovery('456', 'unknown'),
    });
    store.dispatch(targetComposerAction(setComposeToStatus(fromJS({
      id: 'status-1',
      visibility: 'public',
      sensitive: false,
      language: 'en',
      media_attachments: [],
    }), 'Editing', ''), composerId));
    const editing = renderBar(store);
    expect(screen.queryByRole('button', { name: 'Recheck' })).toBeNull();
    editing.unmount();

    store.dispatch(targetComposerAction({
      type: 'REDRAFT',
      raw_text: 'Later',
      context_references: [],
      status: fromJS({
        scheduled_status_id: 'sched-1',
        visibility: 'public',
        sensitive: false,
        media_attachments: [],
      }),
    }, composerId));
    renderBar(store);
    expect(screen.queryByRole('button', { name: 'Recheck' })).toBeNull();
  });

  it('does not let a status fetch start a revalidation request', async () => {
    const post = jest.fn();
    const get = jest.fn(() => Promise.resolve({ data: { state: 'idle', account_id: '456' } }));
    api.mockImplementation(() => ({ post, get }));
    const store = makeStore();

    await store.dispatch(fetchPostingContextRevalidationStatus('456'));

    expect(get).toHaveBeenCalledTimes(1);
    expect(post).not.toHaveBeenCalled();
  });

  it('keeps the previous draft when the revalidation request fails', async () => {
    const post = jest.fn(() => Promise.reject({ response: { status: 500 } }));
    api.mockImplementation(() => ({ post, get: jest.fn() }));
    const store = makeStore();

    store.dispatch(createComposer(composerId));
    store.dispatch(targetComposerAction(changeCompose('Keep me'), composerId));
    store.dispatch(applyComposerPostingContext(composerId, mitraGroupPostingContext, '456'));
    await store.dispatch(requestPostingContextRevalidation('456'));

    expect(store.getState().getIn(['composers', 'byId', composerId, 'text'])).toEqual('Keep me');
    expect(store.getState().getIn(['posting_context_revalidations', '456', 'error'])).toEqual('failed');
  });

  it('reads the stored job after a cooldown instead of starting another fetch', async () => {
    const post = jest.fn(() => Promise.reject({ response: { status: 429 } }));
    const get = jest.fn(url => Promise.resolve({
      data: String(url).endsWith('/revalidation')
        ? { state: 'completed', request_id: 'job-9', account_id: '456', actor: 'refreshed', affiliations: 'refreshed' }
        : discovery('456', 'allowed'),
    }));
    api.mockImplementation(() => ({ post, get }));
    const store = makeStore();

    store.dispatch(createComposer(composerId));
    store.dispatch(targetComposerAction(changeCompose('Kept'), composerId));
    store.dispatch(applyComposerPostingContext(composerId, mitraGroupPostingContext, '456'));
    store.dispatch({
      type: 'POSTING_CONTEXT_FETCH_SUCCESS',
      accountId: '456',
      receivedAt: Date.now(),
      data: discovery('456', 'unknown'),
    });
    await store.dispatch(requestPostingContextRevalidation('456'));
    await Promise.resolve();

    expect(post).toHaveBeenCalledTimes(1);
    expect(get.mock.calls.filter(call => String(call[0]).endsWith('/revalidation'))).toHaveLength(1);
    expect(store.getState().getIn(['posting_contexts', '456', 'viewerEvidence', 'permissions', 'create', 'status'])).toEqual('allowed');
    expect(store.getState().getIn(['composers', 'byId', composerId, 'text'])).toEqual('Kept');
  });
});
