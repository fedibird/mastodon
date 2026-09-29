/* eslint-disable react/prop-types */

import { act, fireEvent, render, screen, within } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: jest.fn(),
}));

jest.mock('mastodon/initial_state', () => ({
  me: '1',
  autoPlayEmoji: false,
  disableReactions: false,
  translationPrivateContentAllowed: false,
  showTranslationBar: true,
  languages: [
    ['en', 'English', 'English'],
    ['ja', 'Japanese', '日本語'],
    ['fr', 'French', 'Français'],
    ['de', 'German', 'Deutsch'],
  ],
}));

jest.mock('react-overlays/Overlay', () => {
  return ({ show, children }) => (show ? children({ props: { style: {} }, placement: 'bottom' }) : null);
});

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    locale: 'ja-JP',
    formatMessage: ({ defaultMessage }, values) => {
      let message = defaultMessage;

      if (values) {
        Object.keys(values).forEach(key => {
          message = message.replace(`{${key}}`, values[key]);
        });
      }

      return message;
    },
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage, values }) => intl.formatMessage({ defaultMessage }, values),
  };
});

jest.mock('mastodon/containers/poll_container', () => () => null);
jest.mock('../permalink', () => ({ children }) => <span>{children}</span>);
jest.mock('mastodon/components/icon', () => () => null);

import api from 'mastodon/api';
import statusesReducer from '../../reducers/statuses';
import settingsReducer from '../../reducers/settings';
import translationAssumptions from '../../reducers/translation_assumptions';
import StatusContent from '../status_content';

const LANGUAGES = {
  en: ['ja', 'de'],
  fr: ['ja', 'de'],
  und: ['ja'],
};

const thunk = ({ dispatch, getState }) => next => action => (
  typeof action === 'function' ? action(dispatch, getState) : next(action)
);

const reducer = (state, action) => state
  .set('statuses', statusesReducer(state.get('statuses'), action))
  .set('translation_assumptions', translationAssumptions(state.get('translation_assumptions'), action))
  .set('settings', settingsReducer(state.get('settings'), action));

const buildStatus = (id, language, overrides = {}) => fromJS({
  id,
  contentHtml: `<p>${id}</p>`,
  spoilerHtml: '',
  spoiler_text: '',
  search_index: id,
  language,
  visibility: 'public',
  mentions: [],
  account: { id: 'a1' },
  ...overrides,
});

const createInteractiveStore = (statuses, { languages = LANGUAGES, target } = {}) => {
  let settings = settingsReducer(undefined, { type: '@@INIT' });

  if (target) {
    settings = settings.setIn(['translation', 'targetLanguage'], target);
  }

  const state = Object.entries(statuses).reduce((next, [id, status]) => (
    next.setIn(['statuses', id], status)
  ), fromJS({
    server: {
      translationLanguages: languages ? { items: languages } : {},
    },
    statuses: {},
    translation_assumptions: {},
  }).set('settings', settings));

  return createStore(reducer, state, applyMiddleware(thunk));
};

const renderStatuses = (store, statuses, props = {}) => render(
  <Provider store={store}>
    {Object.entries(statuses).map(([id, status]) => (
      <div key={id} data-testid={`status-${id}`}>
        <StatusContent status={status} onTranslate={props.onTranslate || jest.fn()} onClick={jest.fn()} />
      </div>
    ))}
  </Provider>,
);

describe('viewer-wide translation target', () => {
  let put;

  beforeEach(() => {
    jest.useFakeTimers();
    put = jest.fn(() => Promise.resolve({}));
    api.mockReset();
    api.mockReturnValue({ put, post: jest.fn(() => Promise.resolve({ data: {} })) });
  });

  afterEach(() => {
    act(() => {
      jest.runOnlyPendingTimers();
    });
    jest.useRealTimers();
  });

  it('uses the normalized UI locale until a target is saved', () => {
    const status = buildStatus('s1', 'en', { contentHtml: '<p>Hello</p>', search_index: 'Hello' });
    const store = createInteractiveStore({ s1: status });

    renderStatuses(store, { s1: status });

    expect(screen.getByRole('button', { name: 'Target language, 日本語' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Translate' })).toBeEnabled();
    expect(store.getState().getIn(['settings', 'translation', 'targetLanguage'])).toBeUndefined();
    expect(put).not.toHaveBeenCalled();
  });

  it('keeps a saved target instead of the UI locale, including when that target is unsupported', () => {
    const status = buildStatus('s1', 'en', { contentHtml: '<p>Hello</p>', search_index: 'Hello' });
    const store = createInteractiveStore({ s1: status }, {
      languages: { en: ['ja'], und: ['ja'] },
      target: 'de',
    });

    renderStatuses(store, { s1: status });

    expect(screen.getByRole('button', { name: 'Target language, Deutsch' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Target language, 日本語' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Translate' })).toBeDisabled();
    expect(screen.getByText('This language pair is not supported.')).toBeTruthy();
    expect(store.getState().getIn(['settings', 'translation', 'targetLanguage'])).toBe('de');

    fireEvent.click(screen.getByRole('button', { name: 'Target language, Deutsch' }));

    expect(screen.getByRole('option', { name: /Deutsch/ })).toHaveAttribute('aria-selected', 'true');
    expect(screen.getByRole('option', { name: /日本語/ })).toHaveAttribute('aria-selected', 'false');
    expect(store.getState().getIn(['settings', 'translation', 'targetLanguage'])).toBe('de');
    expect(put).not.toHaveBeenCalled();
  });

  it('updates every visible bar from one target change and saves it as a web setting', () => {
    const statusA = buildStatus('a', 'en', { contentHtml: '<p>Hello</p>', search_index: 'Hello' });
    const statusB = buildStatus('b', 'ja', { contentHtml: '<p>こんにちは</p>', search_index: 'こんにちは' });
    const store = createInteractiveStore({ a: statusA, b: statusB });
    const { rerender } = renderStatuses(store, { a: statusA, b: statusB });
    const bar = id => within(screen.getByTestId(`status-${id}`));

    expect(bar('a').getByRole('button', { name: 'Source language, English' })).toBeTruthy();
    expect(bar('b').getByRole('button', { name: 'Source language, 日本語' })).toBeTruthy();

    fireEvent.click(bar('a').getByRole('button', { name: 'Target language, 日本語' }));
    fireEvent.click(bar('a').getByRole('option', { name: /Deutsch/ }));

    expect(bar('a').getByRole('button', { name: 'Target language, Deutsch' })).toBeTruthy();
    expect(bar('b').getByRole('button', { name: 'Target language, Deutsch' })).toBeTruthy();
    expect(bar('a').getByRole('button', { name: 'Source language, English' })).toBeTruthy();
    expect(bar('b').getByRole('button', { name: 'Source language, 日本語' })).toBeTruthy();
    expect(store.getState().getIn(['settings', 'translation', 'targetLanguage'])).toBe('de');
    expect(store.getState().get('translation_assumptions').isEmpty()).toBe(true);
    expect(store.getState().getIn(['statuses', 'a', 'language'])).toBe('en');
    expect(store.getState().getIn(['statuses', 'b', 'language'])).toBe('ja');
    expect(put).toHaveBeenCalledWith('/api/web/settings', {
      data: expect.objectContaining({
        translation: { targetLanguage: 'de' },
      }),
    });

    fireEvent.click(bar('a').getByRole('button', { name: 'Source language, English' }));
    fireEvent.click(bar('a').getByRole('option', { name: /Français/ }));
    rerender(
      <Provider store={store}>
        <div data-testid='status-a'>
          <StatusContent status={store.getState().getIn(['statuses', 'a'])} onTranslate={jest.fn()} onClick={jest.fn()} />
        </div>
        <div data-testid='status-b'>
          <StatusContent status={statusB} onTranslate={jest.fn()} onClick={jest.fn()} />
        </div>
      </Provider>,
    );

    expect(bar('a').getByRole('button', { name: 'Source language, Français' })).toBeTruthy();
    expect(bar('b').getByRole('button', { name: 'Source language, 日本語' })).toBeTruthy();
    expect(store.getState().getIn(['translation_assumptions', 'a'])).toBe('fr');
    expect(store.getState().hasIn(['translation_assumptions', 'b'])).toBe(false);
    expect(store.getState().getIn(['translation_assumptions', 'a', 'target'])).toBeUndefined();
    expect(store.getState().getIn(['settings', 'translation', 'targetLanguage'])).toBe('de');
    expect(store.getState().getIn(['statuses', 'a', 'language'])).toBe('en');
  });

  it('recomputes provider support for every status when the global target changes', () => {
    const statusA = buildStatus('a', 'en', { contentHtml: '<p>Hello</p>', search_index: 'Hello' });
    const statusB = buildStatus('b', 'fr', { contentHtml: '<p>Bonjour</p>', search_index: 'Bonjour' });
    const store = createInteractiveStore({ a: statusA, b: statusB }, {
      languages: { en: ['ja', 'de'], fr: ['ja'], und: ['ja'] },
    });

    renderStatuses(store, { a: statusA, b: statusB });
    const bar = id => within(screen.getByTestId(`status-${id}`));

    expect(bar('a').getByRole('button', { name: 'Translate' })).toBeEnabled();
    expect(bar('b').getByRole('button', { name: 'Translate' })).toBeEnabled();

    fireEvent.click(bar('a').getByRole('button', { name: 'Target language, 日本語' }));
    fireEvent.click(bar('a').getByRole('option', { name: /Deutsch/ }));

    expect(bar('a').getByRole('button', { name: 'Translate' })).toBeEnabled();
    expect(bar('b').getByRole('button', { name: 'Translate' })).toBeDisabled();
    expect(bar('b').getByRole('button', { name: 'Bilingual' })).toBeDisabled();
    expect(bar('b').getByText('This language pair is not supported.')).toBeTruthy();
    expect(bar('a').queryByText('This language pair is not supported.')).toBeNull();
    expect(bar('b').getByRole('button', { name: 'Target language, Deutsch' })).toBeTruthy();
    expect(store.getState().getIn(['settings', 'translation', 'targetLanguage'])).toBe('de');
    expect(store.getState().getIn(['statuses', 'b', 'language'])).toBe('fr');

    fireEvent.click(bar('b').getByRole('button', { name: 'Target language, Deutsch' }));
    fireEvent.click(bar('b').getByRole('option', { name: /日本語/ }));

    expect(bar('a').getByRole('button', { name: 'Target language, 日本語' })).toBeTruthy();
    expect(bar('b').getByRole('button', { name: 'Translate' })).toBeEnabled();
    expect(screen.queryByText('This language pair is not supported.')).toBeNull();
    expect(store.getState().getIn(['settings', 'translation', 'targetLanguage'])).toBe('ja');
  });

  it('returns a loaded translation to Original and offers the saved translation again when the target returns', () => {
    const onTranslate = jest.fn();
    const status = buildStatus('s1', 'en', {
      contentHtml: '<p>Hello</p>',
      search_index: 'Hello',
      translationMode: 'translated',
      translation: {
        contentHtml: '<p>こんにちは</p>',
        spoilerHtml: '',
        language: 'ja',
        detected_source_language: 'en',
        requested_source_language: 'en',
        requested_target_language: 'ja',
        provider: 'DeepL',
      },
    });
    const store = createInteractiveStore({ s1: status });
    const { container, rerender } = render(
      <Provider store={store}>
        <StatusContent status={status} onTranslate={onTranslate} onClick={jest.fn()} />
      </Provider>,
    );

    expect(container.querySelector('.status__content__text').innerHTML).toContain('こんにちは');
    expect(container.querySelector('.status__content__text').getAttribute('lang')).toBe('ja');
    expect(screen.getByText('· DeepL')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Target language, 日本語' }));
    fireEvent.click(screen.getByRole('option', { name: /Deutsch/ }));
    rerender(
      <Provider store={store}>
        <StatusContent status={store.getState().getIn(['statuses', 's1'])} onTranslate={onTranslate} onClick={jest.fn()} />
      </Provider>,
    );

    expect(container.querySelector('.status__content__text').innerHTML).toContain('Hello');
    expect(container.querySelector('.status__content__text').getAttribute('lang')).toBe('en');
    expect(screen.queryByText('· DeepL')).toBeNull();
    expect(screen.getByRole('button', { name: 'Translate' })).toBeEnabled();
    expect(store.getState().getIn(['statuses', 's1', 'translationMode'])).toBe('original');
    expect(store.getState().getIn(['statuses', 's1', 'translation', 'requested_target_language'])).toBe('ja');
    expect(store.getState().getIn(['statuses', 's1', 'translation', 'contentHtml'])).toContain('こんにちは');
    expect(store.getState().getIn(['statuses', 's1', 'language'])).toBe('en');
    expect(store.getState().getIn(['statuses', 's1', 'translationPending'])).toBe(false);
    expect(store.getState().getIn(['statuses', 's1', 'translationRequestId'])).toBeUndefined();
    expect(onTranslate).not.toHaveBeenCalled();

    fireEvent.click(screen.getByRole('button', { name: 'Target language, Deutsch' }));
    fireEvent.click(screen.getByRole('option', { name: /日本語/ }));

    expect(screen.getByRole('button', { name: 'Original', pressed: true })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Translated', pressed: false })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();
    expect(container.querySelector('.status__content__text').innerHTML).toContain('Hello');

    fireEvent.click(screen.getByRole('button', { name: 'Translated', pressed: false }));

    expect(onTranslate).toHaveBeenCalledWith('translated');
    expect(store.getState().getIn(['statuses', 's1', 'translation', 'requested_source_language'])).toBe('en');
    expect(store.getState().getIn(['statuses', 's1', 'translation', 'requested_target_language'])).toBe('ja');
  });

  it('does not treat a missing provider map as an unsupported saved target', () => {
    const status = buildStatus('s1', 'en', { contentHtml: '<p>Hello</p>', search_index: 'Hello' });
    const store = createInteractiveStore({ s1: status }, { languages: null, target: 'de' });

    renderStatuses(store, { s1: status });

    expect(screen.getByRole('button', { name: 'Target language, Deutsch' })).toBeTruthy();
    expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();
    expect(screen.queryByText('This language pair is not supported.')).toBeNull();
    expect(store.getState().getIn(['settings', 'translation', 'targetLanguage'])).toBe('de');
  });
});
