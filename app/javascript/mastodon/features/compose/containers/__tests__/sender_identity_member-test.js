import { Map as ImmutableMap } from 'immutable';
import { render, screen } from '@testing-library/react';
import React from 'react';
import { Provider } from 'react-redux';

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
  me: '42',
  isAdministrator: false,
}));

import { initialState as composerInitialState } from '../../../../reducers/composer';
import { ComposerProvider } from '../../composer_id_context';
import SenderIdentityContainer, { mapStateToProps } from '../sender_identity_container';

const state = ImmutableMap({
  compose: composerInitialState.merge({
    text: 'hello',
    senderIdentity: ImmutableMap({
      id: 'delegated:99',
      status: 'ready',
      selectionOrigin: 'explicit',
      changeEpoch: 1,
    }),
  }),
  accounts: ImmutableMap({
    42: ImmutableMap({
      id: '42',
      acct: 'member',
      display_name: 'Member',
      avatar_static: '/avatars/member.png',
    }),
  }),
});

describe('regular account sender avatar', () => {
  it('shows the signed-in avatar and does not fetch or offer identity choices', () => {
    const props = mapStateToProps(state, { composerId: 'primary' });
    const dispatch = jest.fn();

    expect(props.visible).toBe(true);
    expect(props.selectable).toBe(false);
    expect(props.current.getIn(['account', 'acct'])).toEqual('member');
    expect(props.choices.size).toBe(0);
    expect(props.selectedId).toEqual('local:42');

    render(
      <Provider store={{ getState: () => state, dispatch, subscribe: () => () => {} }}>
        <ComposerProvider composerId='primary'>
          <SenderIdentityContainer />
        </ComposerProvider>
      </Provider>,
    );

    expect(dispatch).not.toHaveBeenCalled();
    expect(document.querySelector('.compose-form__sender-avatar').getAttribute('src')).toBe('/avatars/member.png');
    expect(document.querySelector('.compose-form__sender-stack')).toBeNull();
    expect(screen.queryByRole('button', { name: /Choose posting account/ })).toBeNull();
    expect(screen.queryByRole('menuitemradio')).toBeNull();
    expect(screen.getByTestId('sender-identity-current').textContent).toContain('@member');
  });
});
