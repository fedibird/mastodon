import { fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import React from 'react';

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

import SenderIdentity from '../sender_identity';

const identity = (id, acct, authorization = 'ready') => ImmutableMap({
  id,
  authorization,
  account: ImmutableMap({
    id,
    acct,
    displayName: acct,
    avatarStatic: `/avatars/${acct}.png`,
  }),
});

describe('SenderIdentity', () => {
  it('shows only the current sender when no other identity is available', () => {
    render(
      <SenderIdentity
        current={identity('local:42', 'admin')}
        choices={ImmutableList([identity('local:42', 'admin'), identity('local:99', 'other', 'unavailable')])}
        selectedId='local:42'
      />,
    );

    expect(screen.getByTestId('sender-identity').textContent).toContain('Posting as');
    expect(screen.getByTestId('sender-identity').textContent).toContain('@admin');
    expect(screen.getByTestId('sender-identity').textContent).toContain('does not change the account you are logged in as');
    expect(screen.queryByRole('button', { name: 'Post as other' })).toBeNull();
    expect(screen.queryByText('@other')).toBeNull();
    expect(screen.getByTestId('sender-identity-current')).toBeTruthy();
  });

  it('offers a choice only for identities that are ready to post', () => {
    const onSelect = jest.fn();

    render(
      <SenderIdentity
        current={identity('local:42', 'admin')}
        choices={ImmutableList([
          identity('local:42', 'admin'),
          identity('local:77', 'editor'),
          identity('local:99', 'other', 'unavailable'),
        ])}
        selectedId='local:42'
        onSelect={onSelect}
      />,
    );

    expect(screen.queryByText('@other')).toBeNull();
    fireEvent.click(screen.getByRole('button', { name: '@editor' }));
    expect(onSelect).toHaveBeenCalledWith('local:77');
  });

  it('stays visible in the compact composer', () => {
    render(
      <SenderIdentity
        compact
        current={identity('local:42', 'admin')}
        choices={ImmutableList([identity('local:42', 'admin')])}
        selectedId='local:42'
      />,
    );

    expect(screen.getByTestId('sender-identity').className).toContain('compose-form__sender--compact');
    expect(screen.getByTestId('sender-identity').textContent).toContain('@admin');
  });
});
