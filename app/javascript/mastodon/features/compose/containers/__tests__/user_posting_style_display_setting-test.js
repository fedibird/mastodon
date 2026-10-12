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
  isAdministrator: true,
  showComposerPostingStyleSelector: false,
}));

import { USER_POSTING_STYLES_FETCH_SUCCESS } from '../../../../actions/user_posting_styles';
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

describe('posting style display setting', () => {
  it('hides style choices for an administrator who turned the selector off', () => {
    const composerId = 'portable:hashtag-column:books';
    const store = createStore(reduce, ImmutableMap({
      composers: composers(undefined, createComposer(composerId)),
      userPostingStyles: userPostingStyles(undefined, {
        type: USER_POSTING_STYLES_FETCH_SUCCESS,
        styles: ImmutableList([fromJS({
          id: 'books',
          name: 'Books',
          revision: 1,
          target: { kind: 'hashtag', label: '#books' },
          defaults: { visibility: 'public' },
          managed: { hashtags: [] },
        })]),
      }),
      relationships: ImmutableMap(),
    }));

    store.dispatch(applyComposerSurface(composerId, { kind: 'hashtag', key: 'books' }, null, null));

    render(
      <Provider store={store}>
        <ComposerProvider composerId={composerId}>
          <UserPostingStylePicker header contextDetails={<div>Required mention</div>} />
        </ComposerProvider>
      </Provider>,
    );

    expect(screen.queryByRole('menuitemradio')).toBeNull();
    expect(document.querySelector('.compose-form__style-menu')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: /books|Posting destination|This place only/ }));

    expect(screen.getByText('Required mention')).toBeTruthy();
    expect(screen.queryByRole('menuitemradio')).toBeNull();
    expect(screen.queryByRole('link', { name: 'Posting style settings' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Always use this style here' })).toBeNull();
  });
});
