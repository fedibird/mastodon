/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import { combineReducers } from 'redux-immutable';
import thunk from 'redux-thunk';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  injectIntl: Component => Component,
}));

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(() => ({ put: jest.fn(() => Promise.resolve({ data: {} })) })),
}));

jest.mock('../containers/compose_form_container', () => {
  const React = require('react');
  const { withComposerId } = require('../composer_id_context');

  class Form extends React.Component {

    handleSimple = () => {
      this.props.onDisplayModeChange('simple');
    }

    handleFull = () => {
      this.props.onDisplayModeChange('full');
    }

    render () {
      const { composerId, displayMode } = this.props;

      return (
        <div>
          <span data-testid={`mode-${composerId}`}>{displayMode}</span>
          <button type='button' onClick={this.handleSimple}>simple-{composerId}</button>
          <button type='button' onClick={this.handleFull}>full-{composerId}</button>
        </div>
      );
    }

  }

  return withComposerId(Form);
});

import {
  addPoll,
  changeCompose,
  changeComposeLanguage,
  changeComposeSpoilerText,
  changeComposeSpoilerness,
  changeComposeVisibility,
  uploadComposeSuccess,
} from '../../../actions/compose';
import { targetComposerAction } from '../../../actions/composer';
import { STORE_HYDRATE } from '../../../actions/store';
import compose from '../../../reducers/compose';
import composers from '../../../reducers/composers';
import settings from '../../../reducers/settings';
import PortableComposer from '../portable_composer';

const composerId = 'portable:list-column:a';

const makeStore = () => createStore(combineReducers({
  compose,
  composers,
  settings,
}), applyMiddleware(thunk));

const hydrateDefaults = (store) => {
  store.dispatch({
    type: STORE_HYDRATE,
    state: fromJS({
      compose: {
        default_privacy: 'public',
        default_language: 'en',
      },
      settings: {},
    }),
  });
};

const renderComposer = (store, id) => render(
  <Provider store={store}>
    <PortableComposer composerId={id} />
  </Provider>,
);

describe('PortableComposer display mode', () => {
  it('changes only the display preference when switching full and simple', () => {
    const store = makeStore();
    hydrateDefaults(store);
    renderComposer(store, composerId);

    store.dispatch(targetComposerAction(changeCompose('hello'), composerId));
    store.dispatch(targetComposerAction(changeComposeVisibility('private'), composerId));
    store.dispatch(targetComposerAction(changeComposeLanguage('ja'), composerId));
    store.dispatch(targetComposerAction(changeComposeSpoilerness(), composerId));
    store.dispatch(targetComposerAction(changeComposeSpoilerText('cw'), composerId));
    store.dispatch(targetComposerAction(addPoll(), composerId));
    store.dispatch(targetComposerAction(uploadComposeSuccess({ id: 'media-1', type: 'video', order: 0 }, null), composerId));

    const path = ['composers', 'byId', composerId];
    const before = store.getState().getIn(path);

    expect(before.get('text')).toBe('hello');
    expect(before.get('privacy')).toBe('private');
    expect(before.get('language')).toBe('ja');
    expect(before.get('spoiler')).toBe(true);
    expect(before.get('spoiler_text')).toBe('cw');
    expect(before.get('poll')).not.toBeNull();
    expect(before.get('media_attachments').size).toBe(1);

    fireEvent.click(screen.getByRole('button', { name: `simple-${composerId}` }));

    expect(screen.getByTestId(`mode-${composerId}`).textContent).toBe('simple');
    expect(store.getState().getIn(path)).toEqual(before);
    expect(store.getState().getIn(['settings', 'portableComposerDisplayMode', composerId])).toBe('simple');

    fireEvent.click(screen.getByRole('button', { name: `full-${composerId}` }));

    expect(screen.getByTestId(`mode-${composerId}`).textContent).toBe('full');
    expect(store.getState().getIn(path)).toEqual(before);
    expect(store.getState().getIn(['settings', 'portableComposerDisplayMode', composerId])).toBe('full');
  });

  it('restores each composer mode after settings hydrate', () => {
    const store = makeStore();
    hydrateDefaults(store);
    store.dispatch({
      type: STORE_HYDRATE,
      state: fromJS({
        compose: {},
        settings: {
          portableComposerDisplayMode: {
            'portable:list-column:a': 'simple',
            'portable:list-column:b': 'full',
          },
        },
      }),
    });

    render(
      <Provider store={store}>
        <PortableComposer composerId='portable:list-column:a' />
        <PortableComposer composerId='portable:list-column:b' />
      </Provider>,
    );

    expect(screen.getByTestId('mode-portable:list-column:a').textContent).toBe('simple');
    expect(screen.getByTestId('mode-portable:list-column:b').textContent).toBe('full');
  });
});
