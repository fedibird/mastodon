import { render, screen } from '@testing-library/react';
import { Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('react-intl', () => {
  const intl = {
    formatMessage: ({ defaultMessage }) => defaultMessage,
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

import { USER_POSTING_STYLES_FETCH_SUCCESS } from '../../../../actions/user_posting_styles';
import compose from '../../../../reducers/compose';
import userPostingStyles from '../../../../reducers/user_posting_styles';
import { PRIMARY_COMPOSER_ID } from '../../../../utils/composer';
import { ComposerProvider } from '../../composer_id_context';
import UserPostingStylePicker from '../user_posting_style_picker_container';

const reduce = (state, action) => {
  if (!state || !action || action.type === '@@INIT') {
    return state;
  }

  return state
    .set('compose', compose(state.get('compose'), action))
    .set('userPostingStyles', userPostingStyles(state.get('userPostingStyles'), action));
};

describe('posting style permission', () => {
  it('does not show a posting style control or destination details to a regular account', () => {
    const store = createStore(reduce, ImmutableMap({
      compose: compose(undefined, { type: '@@INIT' }),
      userPostingStyles: userPostingStyles(undefined, {
        type: USER_POSTING_STYLES_FETCH_SUCCESS,
        styles: [],
      }),
    }));

    render(
      <Provider store={store}>
        <ComposerProvider composerId={PRIMARY_COMPOSER_ID}>
          <UserPostingStylePicker header contextDetails={<div>Required mention</div>} />
        </ComposerProvider>
      </Provider>,
    );

    expect(document.querySelector('[data-posting-style-picker]')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Destination details' })).toBeNull();
    expect(screen.queryByText('Required mention')).toBeNull();
    expect(screen.queryByRole('menuitemradio')).toBeNull();
  });
});
