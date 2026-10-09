import { render, screen } from '@testing-library/react';
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

const identity = (id, acct, authorization = 'ready', kind = 'local') => ImmutableMap({
  id,
  kind,
  authorization,
  capabilities: ImmutableMap({
    post: authorization === 'ready' ? 'supported' : 'unavailable',
  }),
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
        sessionIdentityId='local:42'
      />,
    );

    expect(screen.getByTestId('sender-identity').textContent).toContain('Posting as');
    expect(screen.getByTestId('sender-identity').textContent).toContain('@admin');
    expect(screen.getByTestId('sender-identity').textContent).toContain('does not change the account you are logged in as');
    expect(screen.queryByRole('button', { name: 'Post as other' })).toBeNull();
    expect(screen.queryByText('@other')).toBeNull();
    expect(screen.getByTestId('sender-identity-current')).toBeTruthy();
  });

  it('does not offer a sender switch while only the signed-in identity can post', () => {
    render(
      <SenderIdentity
        current={identity('local:42', 'admin')}
        choices={ImmutableList([
          identity('local:42', 'admin'),
          identity('local:77', 'editor'),
          identity('local:99', 'other', 'unavailable'),
        ])}
        selectedId='local:42'
        sessionIdentityId='local:42'
      />,
    );

    expect(screen.queryByRole('button', { name: '@editor' })).toBeNull();
    expect(screen.queryByText('@other')).toBeNull();
    expect(screen.queryByText('@editor')).toBeNull();
    expect(screen.getByTestId('sender-identity-current').textContent).toContain('@admin');
  });

  it('shows 投稿者 @acct compactly in simple mode', () => {
    render(
      <SenderIdentity
        compact
        current={identity('local:42', 'admin')}
        selectedId='local:42'
      />,
    );

    const sender = screen.getByTestId('sender-identity');

    expect(sender.className).toContain('compose-form__sender--compact');
    expect(sender.textContent).toContain('Posting as');
    expect(sender.textContent).toContain('@admin');
    expect(sender.textContent).not.toContain('does not change the account you are logged in as');
    expect(sender.getAttribute('title')).toContain('does not change the account you are logged in as');
  });

  it('keeps the signed-in account available while a linked account is selected', () => {
    const onSelect = jest.fn();

    render(
      <SenderIdentity
        compact
        current={identity('delegated:99', 'author', 'ready', 'delegated')}
        choices={ImmutableList([
          identity('local:42', 'admin'),
          identity('delegated:99', 'author', 'ready', 'delegated'),
        ])}
        selectedId='delegated:99'
        sessionIdentityId='local:42'
        onSelect={onSelect}
      />,
    );

    expect(screen.getByRole('radio', { name: /@admin/ })).toBeTruthy();
    expect(screen.getByRole('radio', { name: /@author/ })).toBeTruthy();
    expect(screen.getByRole('radio', { name: /Linked account/ })).toBeTruthy();

    screen.getByRole('radio', { name: /@admin/ }).click();

    expect(onSelect).toHaveBeenCalledWith('local:42', { confirmed: true });
  });

  it('still offers the signed-in account after the linked account leaves the catalog', () => {
    render(
      <SenderIdentity
        current={identity('delegated:99', 'author', 'unavailable', 'delegated')}
        choices={ImmutableList([
          identity('local:42', 'admin'),
          identity('delegated:99', 'author', 'unavailable', 'delegated'),
        ])}
        selectedId='delegated:99'
        sessionIdentityId='local:42'
        text='Keep this draft'
      />,
    );

    expect(screen.getByRole('radio', { name: /@admin/ })).toBeTruthy();
    expect(screen.queryByRole('radio', { name: /@author/ })).toBeNull();
  });
});
