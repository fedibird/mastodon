import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';

jest.mock('react-intl', () => {
  const intl = {
    formatMessage: ({ defaultMessage }) => defaultMessage,
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
  };
});

import SenderIdentity from '../sender_identity';

const account = fromJS({
  id: '123',
  acct: 'admin',
  display_name: 'Admin',
  avatar: '/avatar.png',
  avatar_static: '/avatar-static.png',
});

const identity = (id, acct, authorization = 'ready') => fromJS({
  id,
  authorization,
  account: {
    id,
    acct,
    display_name: acct,
    avatar_static: `/avatar-${acct}.png`,
  },
});

const noop = () => {};

describe('SenderIdentity', () => {
  it('shows only the current sender, with avatar and acct, and does not invent other choices', () => {
    render(
      <SenderIdentity
        visible
        account={account}
        identities={fromJS([identity('local:123', 'admin')])}
        selectedId='local:123'
        catalogStatus='ready'
        canSend
      />,
    );

    expect(screen.getByText('Posting as')).toBeTruthy();
    expect(screen.getByText('Admin (@admin)')).toBeTruthy();
    expect(screen.getByRole('img').getAttribute('src')).toBe('/avatar-static.png');
    expect(screen.queryByRole('combobox')).toBeNull();
    expect(screen.queryByRole('option')).toBeNull();
  });

  it('offers a sender choice only for identities the catalog actually granted', () => {
    const onSelect = jest.fn();

    render(
      <SenderIdentity
        visible
        account={account}
        identities={fromJS([
          identity('local:123', 'admin'),
          identity('local:456', 'other'),
          identity('local:789', 'blocked', 'restricted'),
        ])}
        selectedId='local:123'
        catalogStatus='ready'
        canSend
        onSelect={onSelect}
      />,
    );

    const chooser = screen.getByRole('combobox', { name: 'Choose who this post is sent as' });

    expect(screen.getAllByRole('option').map(option => option.textContent)).toEqual([
      'admin (@admin)',
      'other (@other)',
    ]);
    expect(screen.queryByRole('option', { name: 'blocked (@blocked)' })).toBeNull();

    fireEvent.change(chooser, { target: { value: 'local:456' } });

    expect(onSelect).toHaveBeenCalledWith('local:456');
  });

  it('stays hidden unless the administrator view is enabled and explains an unconfirmed sender', () => {
    const { rerender } = render(<SenderIdentity visible={false} account={account} />);

    expect(screen.queryByTestId('sender-identity')).toBeNull();

    rerender(
      <SenderIdentity
        visible
        account={account}
        catalogStatus='failed'
        canSend={false}
        onRetry={noop}
        compact
      />,
    );

    expect(screen.getByTestId('sender-identity').className).toContain('compose-form__sender--compact');
    expect(screen.getByRole('status').textContent).toBe('Couldn’t confirm who this post is sent as');
    expect(screen.getByRole('button', { name: 'Confirm sender again' })).toBeTruthy();
  });
});
