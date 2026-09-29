/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';

jest.mock('mastodon/api', () => ({
  __esModule: true,
  default: () => ({
    put: () => Promise.resolve({ data: {} }),
  }),
}));

jest.mock('lodash', () => {
  const actual = jest.requireActual('lodash');
  const debounce = (fn) => {
    const wrapped = (...args) => fn(...args);
    wrapped.cancel = () => {};
    wrapped.flush = () => {};
    return wrapped;
  };

  return new Proxy(actual, {
    get(target, prop, receiver) {
      if (prop === 'debounce') {
        return debounce;
      }

      const value = Reflect.get(target, prop, receiver);
      return typeof value === 'function' ? value.bind(target) : value;
    },
    apply(target, thisArg, args) {
      return Reflect.apply(target, thisArg, args);
    },
  });
});

jest.mock('mastodon/initial_state', () => ({
  me: '1',
  autoPlayEmoji: false,
  disableReactions: false,
  translationPrivateContentAllowed: false,
  translationBarVisibility: 'always',
  translationPreferredMode: 'both',
  languages: [
    ['en', 'English', 'English'],
    ['ja', 'Japanese', '日本語'],
    ['fr', 'French', 'Français'],
    ['de', 'German', 'Deutsch'],
  ],
}));

// Render the menu through a portal, the same place react-overlays puts it.
// React 16 still bubbles the synthetic event through the component tree, which
// is what lets a portaled option reach StatusContent.
jest.mock('react-overlays/Overlay', () => {
  const ReactDOM = require('react-dom');

  return ({ show, children }) => (show ? ReactDOM.createPortal(
    children({ props: { style: {} }, placement: 'bottom' }),
    global.document.body,
  ) : null);
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

import settingsReducer from '../../reducers/settings';
import statusesReducer from '../../reducers/statuses';
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

const buildStatus = (overrides = {}) => fromJS({
  id: 's1',
  contentHtml: '<p>Hello</p>',
  spoilerHtml: '',
  spoiler_text: '',
  search_index: 'Hello',
  language: 'en',
  visibility: 'public',
  mentions: [],
  account: { id: 'a1' },
  ...overrides,
});

const translatedStatus = () => buildStatus({
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

const createInteractiveStore = (status) => {
  const settings = settingsReducer(undefined, { type: '@@INIT' });

  return createStore(reducer, fromJS({
    server: {
      translationLanguages: { items: LANGUAGES },
    },
    statuses: {},
    translation_assumptions: {},
  }).set('settings', settings).setIn(['statuses', status.get('id')], status), applyMiddleware(thunk));
};

const pointerActivate = (element, point = { clientX: 20, clientY: 24 }) => {
  fireEvent.mouseDown(element, { button: 0, ...point });
  fireEvent.mouseUp(element, { button: 0, clientX: point.clientX + 1, clientY: point.clientY + 1 });
  fireEvent.click(element, { button: 0, clientX: point.clientX + 1, clientY: point.clientY + 1 });
};

const renderTimeline = (status, { clickToOpen = true } = {}) => {
  const store = createInteractiveStore(status);
  const statusClick = jest.fn();
  const onTranslate = jest.fn();
  const outer = {
    mouseDown: jest.fn(),
    mouseUp: jest.fn(),
    click: jest.fn(),
    keyDown: jest.fn(),
    touchStart: jest.fn(),
    touchEnd: jest.fn(),
  };

  const view = render(
    <Provider store={store}>
      {/* Records React bubbling. This is a test probe, not a control. */}
      {/* eslint-disable-next-line jsx-a11y/no-static-element-interactions */}
      <div
        onMouseDown={outer.mouseDown}
        onMouseUp={outer.mouseUp}
        onClick={outer.click}
        onKeyDown={outer.keyDown}
        onTouchStart={outer.touchStart}
        onTouchEnd={outer.touchEnd}
      >
        <StatusContent
          status={status}
          onTranslate={onTranslate}
          {...(clickToOpen ? { onClick: statusClick } : {})}
        />
      </div>
    </Provider>,
  );

  return { ...view, store, statusClick, onTranslate, outer };
};

const expectIsolated = ({ statusClick, outer }) => {
  expect(statusClick).not.toHaveBeenCalled();
  expect(outer.mouseDown).not.toHaveBeenCalled();
  expect(outer.mouseUp).not.toHaveBeenCalled();
  expect(outer.click).not.toHaveBeenCalled();
  expect(outer.keyDown).not.toHaveBeenCalled();
  expect(outer.touchStart).not.toHaveBeenCalled();
  expect(outer.touchEnd).not.toHaveBeenCalled();
};

describe('StatusContent translation bar click isolation', () => {
  let hotkey;

  beforeEach(() => {
    hotkey = jest.fn();
    window.addEventListener('keydown', hotkey);
  });

  afterEach(() => {
    window.removeEventListener('keydown', hotkey);
  });

  const openSource = () => {
    pointerActivate(screen.getByRole('button', { name: 'Source language, English' }));
  };

  const openTarget = () => {
    pointerActivate(screen.getByRole('button', { name: 'Target language, 日本語' }));
  };

  it('changes the source language from a portaled option without opening the status', () => {
    const view = renderTimeline(buildStatus());

    openSource();

    const option = screen.getByRole('option', { name: /French/ });
    expect(option.closest('.status__translation-bar')).toBeNull();
    expect(option.closest('.status__content')).toBeNull();

    pointerActivate(option);
    fireEvent.touchStart(option);
    fireEvent.touchEnd(option);

    expect(view.store.getState().getIn(['translation_assumptions', 's1'])).toBe('fr');
    expect(screen.getByRole('button', { name: 'Source language, Français' })).toBeTruthy();
    expect(screen.queryByRole('listbox')).toBeNull();
    expectIsolated(view);
    expect(hotkey).not.toHaveBeenCalled();
  });

  it('changes the global target from a portaled option without opening the status', () => {
    const view = renderTimeline(buildStatus());

    openTarget();
    pointerActivate(screen.getByRole('option', { name: /German/ }));

    expect(view.store.getState().getIn(['settings', 'translation', 'targetLanguage'])).toBe('de');
    expect(screen.getByRole('button', { name: 'Target language, Deutsch' })).toBeTruthy();
    expect(screen.queryByRole('listbox')).toBeNull();
    expectIsolated(view);
  });

  it('keeps search, clear, and typing inside the menu', () => {
    const view = renderTimeline(buildStatus());

    openSource();

    const search = screen.getByPlaceholderText('Search languages...');
    pointerActivate(search);
    fireEvent.change(search, { target: { value: 'fren' } });

    expect(search).toHaveValue('fren');
    expect(screen.getByRole('option', { name: /French/ })).toBeTruthy();
    expect(screen.queryByRole('option', { name: /German/ })).toBeNull();

    pointerActivate(screen.getByRole('button', { name: 'Clear' }));

    expect(search).toHaveValue('');
    expect(screen.getByRole('listbox')).toBeTruthy();
    expectIsolated(view);
    expect(hotkey).not.toHaveBeenCalled();
  });

  it('selects a language with Enter and keeps arrows and Escape inside the menu', () => {
    const view = renderTimeline(buildStatus());

    openSource();

    const search = screen.getByPlaceholderText('Search languages...');
    fireEvent.keyDown(search, { key: 'ArrowDown' });

    const first = document.activeElement;
    expect(first).toHaveAttribute('role', 'option');

    fireEvent.keyDown(first, { key: 'ArrowDown' });

    const second = document.activeElement;
    expect(second).toHaveAttribute('role', 'option');
    expect(second).not.toBe(first);

    fireEvent.keyDown(second, { key: 'Escape' });

    expect(screen.queryByRole('listbox')).toBeNull();
    expect(view.store.getState().getIn(['translation_assumptions', 's1'])).toBeUndefined();
    expectIsolated(view);
    expect(hotkey).not.toHaveBeenCalled();

    openSource();
    fireEvent.keyDown(screen.getByRole('option', { name: /French/ }), { key: 'Enter' });

    expect(view.store.getState().getIn(['translation_assumptions', 's1'])).toBe('fr');
    expect(screen.queryByRole('listbox')).toBeNull();
    expectIsolated(view);
    expect(hotkey).not.toHaveBeenCalled();
  });

  it('does not treat translation actions or display modes as a status click', () => {
    const actions = renderTimeline(buildStatus());

    pointerActivate(screen.getByRole('button', { name: 'Translate' }));
    pointerActivate(screen.getByRole('button', { name: 'Bilingual' }));
    pointerActivate(document.querySelector('.status__translation-bar__arrow'));

    expect(actions.onTranslate).toHaveBeenCalledTimes(2);
    expect(actions.onTranslate).toHaveBeenNthCalledWith(1, 'translated');
    expect(actions.onTranslate).toHaveBeenNthCalledWith(2, 'bilingual');
    expectIsolated(actions);

    const modes = renderTimeline(translatedStatus());

    pointerActivate(screen.getByRole('button', { name: 'Original' }));
    pointerActivate(screen.getByRole('button', { name: 'Translated' }));
    pointerActivate(screen.getAllByRole('button', { name: 'Bilingual' }).pop());

    expect(modes.onTranslate).toHaveBeenNthCalledWith(1, 'original');
    expect(modes.onTranslate).toHaveBeenNthCalledWith(2, 'translated');
    expect(modes.onTranslate).toHaveBeenNthCalledWith(3, 'bilingual');
    expectIsolated(modes);
  });

  it('still opens the status from a press on the post text', () => {
    const view = renderTimeline(buildStatus());

    pointerActivate(screen.getByText('Hello'));

    expect(view.statusClick).toHaveBeenCalledTimes(1);
    expect(view.outer.mouseDown).toHaveBeenCalledTimes(1);
    expect(view.outer.mouseUp).toHaveBeenCalledTimes(1);
    expect(view.outer.click).toHaveBeenCalledTimes(1);
  });

  it('does not leave a stale press that opens the status when the pointer is released outside the menu', () => {
    const view = renderTimeline(buildStatus());

    openSource();
    view.statusClick.mockClear();
    view.outer.mouseDown.mockClear();
    view.outer.mouseUp.mockClear();
    view.outer.click.mockClear();

    const option = screen.getByRole('option', { name: /French/ });
    fireEvent.mouseDown(option, { button: 0, clientX: 8, clientY: 8 });
    fireEvent.mouseUp(screen.getByText('Hello'), { button: 0, clientX: 10, clientY: 9 });

    expect(view.statusClick).not.toHaveBeenCalled();
    expect(screen.getByRole('listbox')).toBeTruthy();

    pointerActivate(screen.getByText('Hello'), { clientX: 40, clientY: 48 });

    expect(view.statusClick).toHaveBeenCalledTimes(1);
  });

  it('closes the menu when a click lands outside it', () => {
    const view = renderTimeline(buildStatus());

    openSource();
    expect(screen.getByRole('listbox')).toBeTruthy();

    fireEvent.click(screen.getByText('Hello'));

    expect(screen.queryByRole('listbox')).toBeNull();
    expect(view.store.getState().getIn(['translation_assumptions', 's1'])).toBeUndefined();
  });

  it('keeps the same controls working on the detail view, which has no click-to-open wrapper', () => {
    const view = renderTimeline(buildStatus(), { clickToOpen: false });

    openSource();
    pointerActivate(screen.getByRole('option', { name: /French/ }));

    expect(view.store.getState().getIn(['translation_assumptions', 's1'])).toBe('fr');
    expect(screen.getByRole('button', { name: 'Source language, Français' })).toBeTruthy();

    openTarget();
    fireEvent.keyDown(screen.getByRole('option', { name: /German/ }), { key: 'Enter' });

    expect(view.store.getState().getIn(['settings', 'translation', 'targetLanguage'])).toBe('de');
    expect(screen.queryByRole('listbox')).toBeNull();
    expect(view.outer.mouseUp).not.toHaveBeenCalled();
    expect(view.outer.keyDown).not.toHaveBeenCalled();
    expect(hotkey).not.toHaveBeenCalled();

    pointerActivate(screen.getByRole('button', { name: 'Translate' }));
    expect(view.onTranslate).toHaveBeenCalledWith('translated');
  });
});
