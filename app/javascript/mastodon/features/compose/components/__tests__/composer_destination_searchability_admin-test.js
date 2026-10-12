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
  showComposerPostingStyleSelector: true,
}));

import { USER_POSTING_STYLES_FETCH_SUCCESS } from '../../../../actions/user_posting_styles';
import compose from '../../../../reducers/compose';
import composers from '../../../../reducers/composers';
import userPostingStyles from '../../../../reducers/user_posting_styles';
import { selectComposer } from '../../../../selectors/composer';
import { PRIMARY_COMPOSER_ID } from '../../../../utils/composer';
import { ComposerProvider } from '../../composer_id_context';
import SearchabilityDropdownContainer from '../../containers/searchability_dropdown_container';
import UserPostingStylePicker from '../../containers/user_posting_style_picker_container';

const reduce = (state, action) => {
  if (!state || !action || action.type === '@@INIT') {
    return state;
  }

  return state
    .set('compose', compose(state.get('compose'), action))
    .set('composers', composers(state.get('composers'), action))
    .set('userPostingStyles', userPostingStyles(state.get('userPostingStyles'), action));
};

describe('administrator posting style searchability', () => {
  it('keeps the style menu mounted while a portaled searchability choice completes', () => {
    const store = createStore(reduce, ImmutableMap({
      compose: compose(undefined, { type: '@@INIT' }),
      composers: composers(undefined, { type: '@@INIT' }),
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
    }));

    render(
      <Provider store={store}>
        <ComposerProvider composerId={PRIMARY_COMPOSER_ID}>
          <UserPostingStylePicker header contextDetails={<SearchabilityDropdownContainer />} />
        </ComposerProvider>
      </Provider>,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Usual settings' }));

    const menu = document.querySelector('.compose-form__style-menu');

    fireEvent.click(screen.getByRole('button', { name: 'Adjust status searchability' }));

    const option = screen.getByRole('option', { name: /Searchable for all/ });

    expect(menu.contains(option)).toBe(false);
    expect(option.closest('[data-searchability-popup]').getAttribute('data-searchability-popup')).toBe(PRIMARY_COMPOSER_ID);

    fireEvent.mouseDown(option);

    expect(menu.isConnected).toBe(true);

    fireEvent.click(option);

    expect(menu.isConnected).toBe(true);
    expect(selectComposer(store.getState(), PRIMARY_COMPOSER_ID).get('searchability')).toBe('public');

    fireEvent.mouseDown(document.body);

    expect(document.querySelector('.compose-form__style-menu')).toBeNull();
  });
});
