import { fireEvent, render, screen } from '@testing-library/react';
import fs from 'fs';
import path from 'path';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';
import { combineReducers } from 'redux-immutable';

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

import { changeCompose } from '../../../../actions/compose';
import { applyComposerPostingContext, createComposer, targetComposerAction } from '../../../../actions/composer';
import { POSTING_CONTEXT_FETCH_REQUEST, POSTING_CONTEXT_FETCH_SUCCESS, POSTING_CONTEXT_FETCH_FAIL } from '../../../../actions/posting_contexts';
import { groupPostingContext } from '../../../../posting_context/fixtures/group_context_fixture';
import { mitraGroupPostingContext } from '../../../../posting_context/fixtures/mitra_group_context_fixture';
import { buildHashtagTimelinePostingContext } from '../../../../posting_context/hashtag';
import compose from '../../../../reducers/compose';
import composers from '../../../../reducers/composers';
import postingContexts from '../../../../reducers/posting_contexts';
import relationships from '../../../../reducers/relationships';
import { ComposerProvider } from '../../composer_id_context';
import PostingContextBarContainer from '../../containers/posting_context_bar_container';

const composerId = 'composer-a';

const renderBar = (store) => render(
  <Provider store={store}>
    <ComposerProvider composerId={composerId}>
      <PostingContextBarContainer />
    </ComposerProvider>
  </Provider>,
);

describe('PostingContextBar', () => {
  it('toggles an advisory hashtag without rewriting the raw draft', () => {
    const store = createStore(combineReducers({ compose, composers }));

    store.dispatch(createComposer(composerId));
    store.dispatch(applyComposerPostingContext(composerId, buildHashtagTimelinePostingContext('foo')));
    store.dispatch(targetComposerAction(changeCompose('Hello #foo'), composerId));

    renderBar(store);

    expect(screen.getByText('Posting context')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Do not add #foo' }));

    expect(store.getState().getIn(['composers', 'byId', composerId, 'text'])).toEqual('Hello #foo');
    expect(store.getState().getIn(['composers', 'byId', composerId, 'context', 'suppressions', 'hashtags']).includes('foo')).toBe(true);
    expect(screen.getByRole('button', { name: 'Include #foo' })).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Include #foo' }));

    expect(store.getState().getIn(['composers', 'byId', composerId, 'context', 'suppressions', 'hashtags']).isEmpty()).toBe(true);
    expect(store.getState().getIn(['composers', 'byId', composerId, 'text'])).toEqual('Hello #foo');
  });

  it('renders nothing when the composer has no managed hashtags', () => {
    const store = createStore(combineReducers({ compose, composers }));

    renderBar(store);

    expect(screen.queryByText('Posting context')).toBeNull();
  });

  it('shows a required group mention without a removal control', () => {
    const store = createStore(combineReducers({ compose, composers, relationships }));
    store.dispatch(createComposer(composerId));
    store.dispatch(applyComposerPostingContext(composerId, groupPostingContext));
    store.dispatch({
      type: 'RELATIONSHIPS_FETCH_SUCCESS',
      relationships: [{ id: '123', following: false, requested: false }],
    });

    renderBar(store);

    expect(screen.getByText('Required mention: @group')).toBeTruthy();
    expect(screen.getByText('Visibility: Public or Unlisted')).toBeTruthy();
    expect(screen.getByText('Follow @group to post in this group')).toBeTruthy();
    expect(screen.queryByRole('button', { name: /@group/ })).toBeNull();
    expect(screen.getByText('Follow @group to post in this group').className).toContain('compose-form__posting-context-warning');

    store.dispatch({
      type: 'RELATIONSHIPS_FETCH_SUCCESS',
      relationships: [{ id: '123', following: false, requested: true }],
    });
    expect(screen.getByText('Follow request to @group is pending')).toBeTruthy();

    store.dispatch({
      type: 'RELATIONSHIPS_FETCH_SUCCESS',
      relationships: [{ id: '123', following: true, requested: false }],
    });
    expect(screen.getByText('✓ Following @group')).toBeTruthy();
    expect(screen.queryByText('Follow @group to post in this group')).toBeNull();
  });

  it('shows a required audience target without mention, follow, or a removal control', () => {
    const store = createStore(combineReducers({ compose, composers, relationships }));
    store.dispatch(createComposer(composerId));
    store.dispatch(applyComposerPostingContext(composerId, mitraGroupPostingContext));

    renderBar(store);

    expect(screen.getByText('Posting context')).toBeTruthy();
    expect(screen.getByText('Posting to group: @group@mitra.example')).toBeTruthy();
    expect(screen.getByText('Visibility: Public or Unlisted')).toBeTruthy();
    expect(screen.queryByText(/Required mention/)).toBeNull();
    expect(screen.queryByText(/Following/)).toBeNull();
    expect(screen.queryByText(/Follow request/)).toBeNull();
    expect(screen.queryByText(/Follow @/)).toBeNull();
    expect(screen.queryByRole('button', { name: /group@mitra.example/ })).toBeNull();

    const en = JSON.parse(fs.readFileSync(path.join(__dirname, '../../../../locales/en.json'), 'utf8'));
    const ja = JSON.parse(fs.readFileSync(path.join(__dirname, '../../../../locales/ja.json'), 'utf8'));

    expect(en['compose_form.posting_context.audience_group']).toEqual('Posting to group: @{acct}');
    expect(ja['compose_form.posting_context.audience_group']).toEqual('投稿先グループ: @{acct}');
    expect(en['compose_form.posting_context.create.allowed']).toEqual('Create permission confirmed');
    expect(ja['compose_form.posting_context.create.allowed']).toEqual('投稿権限を確認済み');
    expect(en['compose_form.posting_context.create.allowed_compatibility']).toEqual('Create permission confirmed · compatibility method');
    expect(ja['compose_form.posting_context.create.allowed_compatibility']).toEqual('投稿権限を確認済み・互換方式');
    expect(en['compose_form.posting_context.create.unknown_compatibility']).toEqual('Create permission not confirmed · compatibility method');
    expect(ja['compose_form.posting_context.create.unknown_compatibility']).toEqual('投稿権限は未確認・互換方式');
    expect(en['compose_form.posting_context.create.refreshing']).toEqual('Rechecking create permission');
    expect(ja['compose_form.posting_context.create.refreshing']).toEqual('投稿権限を再確認中');
    expect(en['compose_form.posting_context.create.refresh_failed']).toEqual('Latest create permission could not be confirmed');
    expect(ja['compose_form.posting_context.create.refresh_failed']).toEqual('最新の投稿権限を確認できません');
  });

  const storeWithDiscovery = () => createStore(combineReducers({
    compose,
    composers,
    relationships,
    posting_contexts: postingContexts,
  }));

  const discover = (store, accountId, data) => {
    store.dispatch({
      type: POSTING_CONTEXT_FETCH_SUCCESS,
      accountId,
      receivedAt: Date.now(),
      data,
    });
  };

  const remoteDiscovery = (accountId, create) => ({
    schema_version: 1,
    account_id: accountId,
    status: 'resolved',
    context: {
      key: `protocol:fep-1b12-group:${accountId}`,
      source: { id: 'compat:mitra-fep-1b12', revision: 1 },
      managed: { hashtags: [], mentions: [] },
      requirements: { following_accounts: [] },
      constraints: { allowed_visibilities: ['public', 'unlisted'] },
      protocol: {
        activitypub: {
          audience: {
            account_id: accountId,
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
        fetched_at: '2026-10-07T01:23:45Z',
        relationships: [],
      },
      permissions: {
        create,
      },
    },
  });

  it('keeps the local group follow display and does not invent create permission', () => {
    const store = storeWithDiscovery();

    store.dispatch(createComposer(composerId));
    store.dispatch(applyComposerPostingContext(composerId, groupPostingContext, '123'));
    discover(store, '123', {
      schema_version: 1,
      account_id: '123',
      status: 'resolved',
      context: {
        key: 'builtin:fedibird-group:123',
        managed: { hashtags: [], mentions: [] },
        requirements: { following_accounts: [] },
        constraints: { allowed_visibilities: ['public', 'unlisted'] },
      },
      discovery: {
        mechanism: 'built_in',
        adapter: 'fedibird_group',
        authority: 'server',
      },
    });
    store.dispatch({
      type: 'RELATIONSHIPS_FETCH_SUCCESS',
      relationships: [{ id: '123', following: true, requested: false }],
    });

    renderBar(store);

    expect(screen.getByText('✓ Following @group')).toBeTruthy();
    expect(screen.queryByText('Create permission confirmed')).toBeNull();
    expect(screen.queryByText(/compatibility method/)).toBeNull();
  });

  it('shows confirmed compatibility permission without calling it a guaranteed post', () => {
    const store = storeWithDiscovery();

    store.dispatch(createComposer(composerId));
    store.dispatch(applyComposerPostingContext(composerId, mitraGroupPostingContext, '456'));
    discover(store, '456', remoteDiscovery('456', {
      status: 'allowed',
      source: 'fep-5219',
      via_relationship: 'trusted-poster',
      authority: 'protocol',
    }));

    renderBar(store);

    const notice = screen.getByText('Create permission confirmed · compatibility method');

    expect(notice.getAttribute('title')).toEqual('Evidence: trusted-poster');
    expect(screen.queryByText('Create permission confirmed')).toBeNull();
    expect(screen.getByText('Posting to group: @group@mitra.example')).toBeTruthy();
  });

  it('shows unknown compatibility permission separately from a compliance warning', () => {
    const store = storeWithDiscovery();

    store.dispatch(createComposer(composerId));
    store.dispatch(applyComposerPostingContext(composerId, mitraGroupPostingContext, '456'));
    store.dispatch(targetComposerAction({ type: 'COMPOSE_VISIBILITY_CHANGE', value: 'private' }, composerId));
    discover(store, '456', remoteDiscovery('456', {
      status: 'unknown',
      source: 'fep-5219',
      via_relationship: null,
      authority: 'protocol',
    }));

    renderBar(store);

    const unknown = screen.getByText('Create permission not confirmed · compatibility method');
    const visibility = screen.getByText('Visibility: Public or Unlisted');

    expect(unknown.className).not.toContain('compose-form__posting-context-create--blocked');
    expect(visibility.className).toContain('compose-form__posting-context-warning');
    expect(screen.queryByText('Create permission confirmed · compatibility method')).toBeNull();
  });

  it('shows rechecking and a failed refresh instead of a confirmed permission', () => {
    const store = storeWithDiscovery();

    store.dispatch(createComposer(composerId));
    store.dispatch(applyComposerPostingContext(composerId, mitraGroupPostingContext, '456'));
    discover(store, '456', remoteDiscovery('456', {
      status: 'allowed',
      source: 'fep-5219',
      via_relationship: 'none',
      authority: 'protocol',
    }));
    store.dispatch({
      type: POSTING_CONTEXT_FETCH_REQUEST,
      accountId: '456',
    });

    renderBar(store);
    expect(screen.getByText('Rechecking create permission')).toBeTruthy();
    expect(screen.queryByText('Create permission confirmed · compatibility method')).toBeNull();

    store.dispatch({
      type: POSTING_CONTEXT_FETCH_FAIL,
      accountId: '456',
      error: new Error('offline'),
    });

    expect(screen.getByText('Latest create permission could not be confirmed')).toBeTruthy();
    expect(screen.queryByText('Create permission confirmed · compatibility method')).toBeNull();
    expect(screen.getByText('Posting to group: @group@mitra.example')).toBeTruthy();
  });
});
