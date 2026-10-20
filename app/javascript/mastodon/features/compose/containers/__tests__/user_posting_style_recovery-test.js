import { fireEvent, render, screen } from '@testing-library/react';
import { Map as ImmutableMap } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { applyMiddleware, createStore } from 'redux';
import thunk from 'redux-thunk';

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

import { USER_POSTING_STYLE_RESOLUTION } from '../../../../actions/user_posting_styles';
import compose from '../../../../reducers/composer';
import { PRIMARY_COMPOSER_ID } from '../../../../utils/composer';
import { ComposerProvider } from '../../composer_id_context';
import UserPostingStylePicker from '../user_posting_style_picker_container';

const reduce = (state, action) => {
  if (!state || !action || action.type === '@@INIT') {
    return state;
  }

  return state.set('compose', compose(state.get('compose'), action));
};

const renderHeld = () => {
  const store = createStore(reduce, ImmutableMap({
    compose: compose(undefined, { type: '@@INIT' }),
  }), applyMiddleware(thunk));

  store.dispatch({
    type: USER_POSTING_STYLE_RESOLUTION,
    resolutionRequired: true,
    selectionKind: 'pending',
  });

  render(
    <Provider store={store}>
      <ComposerProvider composerId={PRIMARY_COMPOSER_ID}>
        <UserPostingStylePicker header />
      </ComposerProvider>
    </Provider>,
  );

  return store;
};

describe('posting style recovery while the selector is hidden', () => {
  it('offers retry and an explicit empty choice without the style menu', () => {
    const store = renderHeld();

    expect(screen.getByRole('button', { name: 'Retry loading the usual style' })).toBeTruthy();
    expect(screen.getByRole('button', { name: 'Post without a style' })).toBeTruthy();
    expect(screen.queryByRole('menuitemradio')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: 'Post without a style' }));

    expect(store.getState().getIn(['compose', 'userPostingStyle', 'selectionKind'])).toEqual('none');
    expect(store.getState().getIn(['compose', 'userPostingStyle', 'usageMode'])).toEqual('once');
  });
});
