/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';
import { combineReducers } from 'redux-immutable';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  injectIntl: Component => Component,
}));

jest.mock('../containers/compose_form_container', () => {
  const React = require('react');
  const { withComposerId } = require('../composer_id_context');

  const Form = ({ composerId, autoFocus }) => (
    <textarea aria-label='compose' data-composer-id={composerId} data-autofocus={String(autoFocus)} />
  );

  return withComposerId(Form);
});

import { changeCompose, changeComposeVisibility } from '../../../actions/compose';
import { targetComposerAction, toggleComposerManagedHashtag } from '../../../actions/composer';
import { buildHashtagTimelinePostingContext } from '../../../posting_context/hashtag';
import { STORE_HYDRATE } from '../../../actions/store';
import compose from '../../../reducers/compose';
import composers from '../../../reducers/composers';
import PortableComposer from '../portable_composer';

const composerId = 'portable:list-route:9';

const makeStore = () => createStore(combineReducers({
  compose,
  composers,
}));

const hydrateDefaults = (store) => {
  store.dispatch({
    type: STORE_HYDRATE,
    state: fromJS({
      compose: {
        default_privacy: 'private',
        default_language: 'ja',
        default_searchability: 'private',
      },
    }),
  });
  store.dispatch(changeCompose('PRIMARY DRAFT'));
  store.dispatch(changeComposeVisibility('direct'));
};

const renderHost = (store, id = composerId) => render(
  <Provider store={store}>
    <PortableComposer composerId={id} />
  </Provider>,
);

describe('PortableComposer', () => {
  it('creates and mounts a composer, then keeps the draft after unmount', () => {
    const store = makeStore();
    hydrateDefaults(store);

    const view = renderHost(store);

    expect(screen.getByLabelText('compose').getAttribute('data-composer-id')).toBe(composerId);
    expect(screen.getByLabelText('compose').getAttribute('data-autofocus')).toBe('false');
    expect(store.getState().getIn(['composers', 'byId', composerId, 'mounted'])).toBe(1);
    expect(store.getState().getIn(['composers', 'byId', composerId, 'text'])).toEqual('');
    expect(store.getState().getIn(['composers', 'byId', composerId, 'privacy'])).toEqual('private');
    expect(store.getState().getIn(['composers', 'byId', composerId, 'context', 'managed', 'hashtags']).isEmpty()).toBe(true);
    expect(store.getState().getIn(['compose', 'text'])).toEqual('PRIMARY DRAFT');
    expect(store.getState().getIn(['compose', 'privacy'])).toEqual('direct');

    store.dispatch(targetComposerAction(changeCompose('hello'), composerId));
    view.unmount();

    expect(store.getState().hasIn(['composers', 'byId', composerId])).toBe(true);
    expect(store.getState().getIn(['composers', 'byId', composerId, 'mounted'])).toBe(0);
    expect(store.getState().getIn(['composers', 'byId', composerId, 'text'])).toEqual('hello');

    renderHost(store);

    expect(store.getState().getIn(['composers', 'byId', composerId, 'mounted'])).toBe(1);
    expect(store.getState().getIn(['composers', 'byId', composerId, 'text'])).toEqual('hello');
    expect(screen.getByLabelText('compose').getAttribute('data-composer-id')).toBe(composerId);
    expect(screen.getByLabelText('compose').getAttribute('data-autofocus')).toBe('false');
  });

  it('tracks composing only when focus leaves the host', () => {
    const store = makeStore();
    hydrateDefaults(store);
    renderHost(store);

    const host = document.querySelector('.portable-composer');
    const field = screen.getByLabelText('compose');
    const inside = document.createElement('button');
    host.appendChild(inside);

    fireEvent.focus(field);
    expect(store.getState().getIn(['composers', 'byId', composerId, 'is_composing'])).toBe(true);

    fireEvent.blur(field, { relatedTarget: inside });
    expect(store.getState().getIn(['composers', 'byId', composerId, 'is_composing'])).toBe(true);

    fireEvent.blur(host, { relatedTarget: document.body });
    expect(store.getState().getIn(['composers', 'byId', composerId, 'is_composing'])).toBe(false);
  });

  it('applies a posting context and keeps suppression across remount', () => {
    const store = makeStore();
    hydrateDefaults(store);
    const postingContext = buildHashtagTimelinePostingContext('Fedibird');
    const view = render(
      <Provider store={store}>
        <PortableComposer composerId={composerId} postingContext={postingContext} />
      </Provider>,
    );
    const composerPath = ['composers', 'byId', composerId];

    expect(store.getState().getIn([...composerPath, 'text'])).toEqual('');
    expect(store.getState().getIn([...composerPath, 'context', 'managed', 'hashtags', 0, 'normalizedName'])).toEqual('fedibird');
    expect(store.getState().getIn([...composerPath, 'context', 'key'])).toEqual('builtin:hashtag:fedibird');

    store.dispatch(toggleComposerManagedHashtag(composerId, 'fedibird'));
    store.dispatch(targetComposerAction(changeCompose('hello'), composerId));
    view.unmount();
    render(
      <Provider store={store}>
        <PortableComposer composerId={composerId} postingContext={{ ...postingContext }} />
      </Provider>,
    );

    expect(store.getState().getIn([...composerPath, 'text'])).toEqual('hello');
    expect(store.getState().getIn([...composerPath, 'context', 'suppressions', 'hashtags']).includes('fedibird')).toBe(true);
    expect(store.getState().getIn([...composerPath, 'mounted'])).toBe(1);
  });

  it('reapplies when the posting context key changes', () => {
    const store = makeStore();
    hydrateDefaults(store);
    const view = render(
      <Provider store={store}>
        <PortableComposer composerId={composerId} postingContext={buildHashtagTimelinePostingContext('foo')} />
      </Provider>,
    );

    store.dispatch(toggleComposerManagedHashtag(composerId, 'foo'));
    view.rerender(
      <Provider store={store}>
        <PortableComposer composerId={composerId} postingContext={buildHashtagTimelinePostingContext('bar')} />
      </Provider>,
    );

    expect(store.getState().getIn(['composers', 'byId', composerId, 'context', 'managed', 'hashtags', 0, 'normalizedName'])).toEqual('bar');
    expect(store.getState().getIn(['composers', 'byId', composerId, 'context', 'suppressions', 'hashtags']).isEmpty()).toBe(true);
  });
});
