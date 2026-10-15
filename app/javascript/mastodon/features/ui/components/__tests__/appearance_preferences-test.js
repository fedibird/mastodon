import { render } from '@testing-library/react';
import { Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

import AppearancePreferences from '../appearance_preferences';
import { reduceMotionNow, resetAppearancePreferences } from 'mastodon/utils/appearance_preferences';

const entry = (key, publicValue, valid = true) => ({
  key,
  state: 'set',
  configured: publicValue,
  effective: publicValue,
  public_value: publicValue,
  public_valid: valid,
  validation_errors: [],
});

const documentFor = (content, info, motion) => ({
  version: 1,
  preferences: {
    'user.content_font_size': entry('user.content_font_size', content),
    'user.info_font_size': entry('user.info_font_size', info),
    'user.reduce_motion': entry('user.reduce_motion', motion),
  },
});

const reducer = (state = ImmutableMap({
  user_preferences: ImmutableMap({ document: null }),
}), action) => {
  if (action.type === 'DOCUMENT') {
    return state.setIn(['user_preferences', 'document'], action.document);
  }

  return state;
};

describe('AppearancePreferences', () => {
  beforeEach(() => {
    resetAppearancePreferences();
    document.documentElement.style.removeProperty('--content-font-size');
    document.documentElement.style.removeProperty('--info-font-size');
    document.body.className = 'theme-light';
  });

  afterEach(() => {
    resetAppearancePreferences();
  });

  it('applies the accepted document on mount and on a later accepted document', () => {
    const store = createStore(reducer, reducer(undefined, {
      type: 'DOCUMENT',
      document: documentFor(17, 13, true),
    }));

    const view = render(
      <Provider store={store}>
        <AppearancePreferences />
      </Provider>,
    );

    expect(document.documentElement.style.getPropertyValue('--content-font-size')).toBe('17px');
    expect(document.documentElement.style.getPropertyValue('--info-font-size')).toBe('13px');
    expect(document.body.classList.contains('reduce-motion')).toBe(true);
    expect(document.body.classList.contains('theme-light')).toBe(true);
    expect(reduceMotionNow(false)).toBe(true);

    store.dispatch({ type: 'DOCUMENT', document: documentFor(19, 13, false) });

    expect(document.documentElement.style.getPropertyValue('--content-font-size')).toBe('19px');
    expect(document.documentElement.style.getPropertyValue('--info-font-size')).toBe('13px');
    expect(document.body.classList.contains('no-reduce-motion')).toBe(true);
    expect(document.body.classList.contains('reduce-motion')).toBe(false);
    expect(reduceMotionNow(true)).toBe(false);

    view.unmount();
    store.dispatch({ type: 'DOCUMENT', document: documentFor(10, 20, true) });

    expect(document.documentElement.style.getPropertyValue('--content-font-size')).toBe('19px');
    expect(document.documentElement.style.getPropertyValue('--info-font-size')).toBe('13px');
    expect(document.body.classList.contains('reduce-motion')).toBe(false);
    expect(reduceMotionNow(true)).toBe(false);
  });

  it('does not replace the server presentation before a document is accepted', () => {
    const store = createStore(reducer);

    render(
      <Provider store={store}>
        <AppearancePreferences />
      </Provider>,
    );

    expect(document.documentElement.style.getPropertyValue('--content-font-size')).toBe('');
    expect(document.body.className).toBe('theme-light');
    expect(reduceMotionNow(false)).toBe(false);
  });
});
