import { fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap, fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('react-intl', () => {
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

jest.mock('../../../../initial_state', () => ({
  isAdministrator: false,
  showComposerPostingStyleSelector: true,
}));

import { USER_POSTING_STYLES_FETCH_FAIL, USER_POSTING_STYLES_FETCH_SUCCESS } from '../../../../actions/user_posting_styles';
import { applyComposerSurface, createComposer } from '../../../../actions/composer';
import composers from '../../../../reducers/composers';
import userPostingStyles from '../../../../reducers/user_posting_styles';
import { ComposerProvider } from '../../composer_id_context';
import UserPostingStylePicker from '../user_posting_style_picker_container';

const reduce = (state, action) => {
  if (!state || !action || action.type === '@@INIT') {
    return state;
  }

  return state
    .set('composers', composers(state.get('composers'), action))
    .set('userPostingStyles', userPostingStyles(state.get('userPostingStyles'), action));
};

const renderPicker = (composerId, status) => {
  const store = createStore(reduce, ImmutableMap({
    composers: composers(undefined, createComposer(composerId)),
    userPostingStyles: userPostingStyles(undefined, {
      type: status === 'failed' ? USER_POSTING_STYLES_FETCH_FAIL : USER_POSTING_STYLES_FETCH_SUCCESS,
      styles: status === 'ready' ? ImmutableList([fromJS({
        id: 'books',
        name: 'Books',
        revision: 1,
        target: { kind: 'hashtag', label: '#books' },
        defaults: { visibility: 'public' },
        managed: { hashtags: [] },
      })]) : ImmutableList(),
    }),
    relationships: ImmutableMap(),
  }));

  if (status === 'loading') {
    store.dispatch({ type: 'USER_POSTING_STYLES_FETCH_REQUEST' });
  }

  store.dispatch(applyComposerSurface(composerId, { kind: 'hashtag', key: 'books' }, null, null));

  render(
    <Provider store={store}>
      <ComposerProvider composerId={composerId}>
        <UserPostingStylePicker
          header
          contextDetails={(
            <div>
              <span>Required mention</span>
              <button type='button'>Searchability</button>
            </div>
          )}
        />
      </ComposerProvider>
    </Provider>,
  );
};

describe('posting style permission', () => {
  ['primary', 'portable:hashtag-column:books'].forEach((composerId) => {
    ['loading', 'failed', 'ready'].forEach((status) => {
      it(`hides style controls for a regular account on ${composerId} while the catalog is ${status}`, () => {
        renderPicker(composerId, status);

        expect(document.querySelector('[data-posting-style-picker]')).toBeNull();
        expect(screen.queryByRole('menuitemradio')).toBeNull();
        expect(screen.queryByRole('link', { name: 'Posting style settings' })).toBeNull();
        expect(screen.queryByRole('button', { name: 'Reload posting styles' })).toBeNull();
        expect(screen.queryByRole('button', { name: 'Always use this style here' })).toBeNull();
        expect(screen.getByTestId('composer-destination')).toBeTruthy();
        expect(screen.queryByRole('button', { name: 'Searchability' })).toBeNull();

        fireEvent.click(screen.getByRole('button', { name: 'Destination details' }));

        expect(screen.getByText('Required mention')).toBeTruthy();
        expect(screen.getByRole('button', { name: 'Searchability' })).toBeTruthy();
        expect(document.querySelector('.compose-form__style-menu')).toBeNull();
      });
    });
  });
});
