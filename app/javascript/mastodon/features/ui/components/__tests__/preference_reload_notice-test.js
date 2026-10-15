const fs = require('fs');
const path = require('path');

import { fireEvent, render, screen } from '@testing-library/react';
import { Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    locale: 'en',
    formatMessage: descriptor => descriptor.defaultMessage,
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

import PreferenceReloadNotice from '../preference_reload_notice';

const en = JSON.parse(fs.readFileSync(path.join(__dirname, '../../../../locales/en.json'), 'utf8'));
const ja = JSON.parse(fs.readFileSync(path.join(__dirname, '../../../../locales/ja.json'), 'utf8'));

const document = {
  version: 1,
  preferences: {
    'user.content_font_size': {
      key: 'user.content_font_size',
      state: 'set',
      configured: 18,
      effective: 18,
      public_value: 18,
      public_valid: true,
      validation_errors: [],
    },
    'user.info_font_size': {
      key: 'user.info_font_size',
      state: 'set',
      configured: 15,
      effective: 15,
      public_value: 15,
      public_valid: true,
      validation_errors: [],
    },
    'user.reduce_motion': {
      key: 'user.reduce_motion',
      state: 'set',
      configured: false,
      effective: false,
      public_value: false,
      public_valid: true,
      validation_errors: [],
    },
  },
};

const reducer = (state = ImmutableMap({
  meta: ImmutableMap({ content_font_size: 15, info_font_size: 15, reduce_motion: false }),
  user_preferences: ImmutableMap({ document: null }),
  compose: ImmutableMap({ text: '', media_attachments: ImmutableMap() }),
  composers: ImmutableMap({ byId: ImmutableMap() }),
}), action) => {
  if (action.type === 'DOCUMENT') {
    return state.setIn(['user_preferences', 'document'], action.document);
  }

  if (action.type === 'DRAFT') {
    return state.setIn(['compose', 'text'], action.text);
  }

  return state;
};

describe('PreferenceReloadNotice', () => {
  it('defines one reload notice in English and Japanese', () => {
    expect(en['preferences.reload']).toBe('Reload');
    expect(en['preferences.reload_required']).toMatch(/Reload to apply them/);
    expect(en['preferences.reload_confirm']).toMatch(/discard unsent posts/);
    expect(ja['preferences.reload']).toBe('再読み込み');
    expect(ja['preferences.reload_required']).toMatch(/再読み込み/);
    expect(ja['preferences.reload_confirm']).toMatch(/送信前の投稿/);
  });

  it('stays hidden until a reload key differs and never reloads by itself', () => {
    const reload = jest.fn();
    const confirm = jest.fn(() => true);
    const store = createStore(reducer);

    render(
      <Provider store={store}>
        <PreferenceReloadNotice confirm={confirm} reload={reload} />
      </Provider>,
    );

    expect(screen.queryByRole('status')).toBeNull();
    expect(reload).not.toHaveBeenCalled();

    store.dispatch({ type: 'DOCUMENT', document });

    expect(screen.getByRole('status').textContent).toMatch(/Unsent posts stay until you reload/);
    expect(reload).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole('button', { name: 'Reload' }));

    expect(confirm).not.toHaveBeenCalled();
    expect(reload).toHaveBeenCalledTimes(1);
  });

  it('asks before a reload that would discard a draft and keeps the draft when declined', () => {
    const reload = jest.fn();
    const confirm = jest.fn(() => false);
    const store = createStore(reducer, reducer(undefined, { type: '@@INIT' }).setIn(['compose', 'text'], '下書きです'));

    store.dispatch({ type: 'DOCUMENT', document });

    render(
      <Provider store={store}>
        <PreferenceReloadNotice confirm={confirm} reload={reload} />
      </Provider>,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Reload' }));

    expect(confirm).toHaveBeenCalledWith('Reloading will discard unsent posts. Reload anyway?');
    expect(reload).not.toHaveBeenCalled();
    expect(store.getState().getIn(['compose', 'text'])).toBe('下書きです');

    confirm.mockReturnValue(true);
    fireEvent.click(screen.getByRole('button', { name: 'Reload' }));
    expect(reload).toHaveBeenCalledTimes(1);
    expect(store.getState().getIn(['compose', 'text'])).toBe('下書きです');
  });

  it('asks before reloading a dirty empty composer and leaves it unchanged when declined', () => {
    const reload = jest.fn();
    const confirm = jest.fn(() => false);
    const compose = ImmutableMap({
      text: '',
      privacy: 'unlisted',
      language: 'ja',
      sensitive: true,
      dirty: true,
      media_attachments: ImmutableMap(),
    });
    const store = createStore(reducer, reducer(undefined, { type: '@@INIT' }).set('compose', compose));

    store.dispatch({ type: 'DOCUMENT', document });

    render(
      <Provider store={store}>
        <PreferenceReloadNotice confirm={confirm} reload={reload} />
      </Provider>,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Reload' }));

    expect(confirm).toHaveBeenCalledTimes(1);
    expect(reload).not.toHaveBeenCalled();
    expect(store.getState().get('compose')).toBe(compose);

    confirm.mockReturnValue(true);
    fireEvent.click(screen.getByRole('button', { name: 'Reload' }));
    expect(reload).toHaveBeenCalledTimes(1);
    expect(store.getState().get('compose')).toBe(compose);
  });

  it('asks before discarding an explicit style choice and keeps it when declined', () => {
    const reload = jest.fn();
    const confirm = jest.fn(() => false);
    const compose = ImmutableMap({
      text: '',
      dirty: false,
      media_attachments: ImmutableMap(),
      userPostingStyle: ImmutableMap({ selectionOrigin: 'manual', selectedId: 'style-1' }),
      senderIdentity: ImmutableMap({ id: 'local:1', selectionOrigin: 'default' }),
    });
    const store = createStore(reducer, reducer(undefined, { type: '@@INIT' }).set('compose', compose));

    store.dispatch({ type: 'DOCUMENT', document });

    render(
      <Provider store={store}>
        <PreferenceReloadNotice confirm={confirm} reload={reload} />
      </Provider>,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Reload' }));

    expect(confirm).toHaveBeenCalledTimes(1);
    expect(reload).not.toHaveBeenCalled();
    expect(store.getState().get('compose')).toBe(compose);

    confirm.mockReturnValue(true);
    fireEvent.click(screen.getByRole('button', { name: 'Reload' }));
    expect(reload).toHaveBeenCalledTimes(1);
    expect(store.getState().getIn(['compose', 'userPostingStyle', 'selectionOrigin'])).toBe('manual');
  });
});
