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

const identity = (id, acct, authorization = 'ready', kind = 'local') => ImmutableMap({
  id,
  kind,
  authorization,
  capabilities: ImmutableMap({
    post: authorization === 'ready' ? 'supported' : 'unavailable',
  }),
    account: ImmutableMap({
    id,
    acct: id.startsWith('delegated:') ? `${acct}@example.test` : acct,
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
    expect(screen.getByTestId('sender-identity').textContent).not.toContain('does not change the account you are logged in as');
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
    expect(sender.getAttribute('title')).toBeNull();
  });

  it('stacks the signed-in account on the posting account in the toolbar', () => {
    render(
      <SenderIdentity
        header
        current={identity('delegated:99', 'author', 'ready', 'delegated')}
        choices={ImmutableList([
          identity('local:42', 'admin'),
          identity('delegated:99', 'author', 'ready', 'delegated'),
        ])}
        catalog={ImmutableList([
          identity('local:42', 'admin'),
          identity('delegated:99', 'author', 'ready', 'delegated'),
        ])}
        selectedId='delegated:99'
        sessionIdentityId='local:42'
        onSelect={jest.fn()}
      />,
    );

    const stack = document.querySelector('.compose-form__sender-stack');
    const base = stack.querySelector('.compose-form__sender-stack-base');
    const self = stack.querySelector('.compose-form__sender-stack-self');

    expect(base.getAttribute('src')).toBe('/avatars/author.png');
    expect(self.getAttribute('src')).toBe('/avatars/admin.png');

    fireEvent.click(screen.getByRole('button', { name: /Choose posting account/ }));

    expect(screen.getByRole('menuitemradio', { name: /@author@example.test/ })).toBeTruthy();
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
    expect(screen.getByText('This linked account is not available right now.')).toBeTruthy();
    expect(screen.getByTestId('sender-identity-current').textContent).toContain('@author');
    expect(screen.getByTestId('sender-identity-current').textContent).not.toContain('@admin');
  });

  it('does not present a missing linked account as the signed-in account', () => {
    const missing = ImmutableMap({
      id: 'delegated:99',
      kind: 'delegated',
      authorization: 'unavailable',
      selectionOrigin: 'explicit',
      status: 'ready',
    });

    const { rerender } = render(
      <SenderIdentity
        current={missing}
        choices={ImmutableList([identity('local:42', 'admin')])}
        selectedId='delegated:99'
        sessionIdentityId='local:42'
        text='Keep this draft'
      />,
    );

    expect(screen.getByText('This linked account is not available right now.')).toBeTruthy();
    expect(screen.getByTestId('sender-identity-current').textContent).not.toContain('@admin');
    expect(screen.getByTestId('sender-identity-current').textContent).not.toContain('admin');
    expect(screen.getByRole('radio', { name: /@admin/ })).toBeTruthy();
    expect(screen.getByTestId('sender-identity').textContent).not.toContain('does not change the account you are logged in as');

    rerender(
      <SenderIdentity
        compact
        current={missing}
        choices={ImmutableList([identity('local:42', 'admin')])}
        selectedId='delegated:99'
        sessionIdentityId='local:42'
        text='Keep this draft'
      />,
    );

    const sender = screen.getByTestId('sender-identity');

    expect(sender.className).toContain('compose-form__sender--compact');
    expect(screen.getByText('This linked account is not available right now.')).toBeTruthy();
    expect(screen.getByTestId('sender-identity-current').textContent).not.toContain('@admin');
    expect(sender.textContent).not.toContain('does not change the account you are logged in as');
    expect(screen.getByRole('radio', { name: /@admin/ })).toBeTruthy();
  });

  it('opens an avatar menu without presenting an expired identity as the signed-in account', () => {
    const missing = ImmutableMap({
      id: 'delegated:99',
      kind: 'delegated',
      authorization: 'unavailable',
      selectionOrigin: 'explicit',
    });

    render(
      <SenderIdentity
        header
        current={missing}
        catalog={ImmutableList([
          identity('local:42', 'admin'),
          identity('delegated:99', 'author', 'unavailable', 'delegated'),
        ])}
        choices={ImmutableList([identity('local:42', 'admin')])}
        selectedId='delegated:99'
        sessionIdentityId='local:42'
        text='Keep this draft'
      />,
    );

    const button = screen.getByRole('button', { name: 'Choose posting account' });

    expect(button.querySelector('.compose-form__sender-stack-base')).toBeNull();
    expect(button.querySelector('.compose-form__sender-stack-self').getAttribute('src')).toBe('/avatars/admin.png');
    expect(screen.getByTestId('sender-identity-current').textContent).not.toContain('@admin');
    expect(screen.getByText('This linked account is not available right now.')).toBeTruthy();

    fireEvent.click(button);

    const menu = document.querySelector('.compose-form__sender-menu');

    expect(screen.getByRole('menuitemradio', { name: /@admin/ })).toBeTruthy();
    expect(screen.getByRole('menuitemradio', { name: /@author/ })).toBeDisabled();
    expect(screen.getByText('Authorization expired')).toBeTruthy();
    expect(screen.queryByText(/Server /)).toBeNull();
    expect(screen.getByText('Linked account')).toBeTruthy();
    expect(screen.getByText('Main account')).toBeTruthy();
    expect(screen.getByText('@author@example.test')).toBeTruthy();
    expect(menu).toBeTruthy();

    fireEvent.keyDown(document, { key: 'Escape' });

    expect(document.querySelector('.compose-form__sender-menu')).toBeNull();
    expect(document.activeElement).toBe(button);
  });

  it('selects the account when its custom emoji is clicked', () => {
    const onSelect = jest.fn();
    const linked = identity('delegated:7', 'painter', 'ready', 'delegated')
      .setIn(['account', 'displayName'], 'Paint :blob:')
      .setIn(['account', 'emojis'], ImmutableList([
        ImmutableMap({
          shortcode: 'blob',
          url: 'https://cdn.example/blob.gif',
          static_url: 'https://cdn.example/blob.png',
        }),
      ]));
    const revoked = identity('delegated:8', 'expired', 'unavailable', 'delegated')
      .setIn(['account', 'displayName'], 'Old :blob:')
      .setIn(['account', 'emojis'], ImmutableList([
        ImmutableMap({
          shortcode: 'blob',
          url: 'https://cdn.example/blob.gif',
          static_url: 'https://cdn.example/blob.png',
        }),
      ]));

    render(
      <SenderIdentity
        header
        current={identity('local:42', 'admin')}
        catalog={ImmutableList([identity('local:42', 'admin'), linked, revoked])}
        choices={ImmutableList([identity('local:42', 'admin'), linked])}
        selectedId='local:42'
        sessionIdentityId='local:42'
        onSelect={onSelect}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Choose posting account, @admin' }));

    const images = screen.getAllByRole('img', { name: ':blob:' });
    const readyEmoji = images.find(image => !image.closest('button').disabled);
    const revokedEmoji = images.find(image => image.closest('button').disabled);

    expect(readyEmoji).toHaveAttribute('draggable', 'false');
    expect(revokedEmoji.closest('button')).toBeDisabled();

    fireEvent.click(revokedEmoji);
    fireEvent.click(readyEmoji);

    expect(onSelect).toHaveBeenCalledTimes(1);
    expect(onSelect).toHaveBeenCalledWith('delegated:7', { confirmed: true });
    expect(document.querySelector('a[href]')).toBeNull();
    expect(document.querySelector('.compose-form__sender-menu')).toBeNull();
    expect(document.activeElement).toBe(screen.getByRole('button', { name: 'Choose posting account, @admin' }));
  });

  it('closes the menu when the current account is chosen again and keeps it open if the switch is cancelled', () => {
    const onSelect = jest.fn();
    const confirm = jest.spyOn(window, 'confirm').mockReturnValue(false);

    render(
      <SenderIdentity
        header
        current={identity('local:42', 'admin')}
        catalog={ImmutableList([identity('local:42', 'admin'), identity('delegated:7', 'painter', 'ready', 'delegated')])}
        choices={ImmutableList([identity('local:42', 'admin'), identity('delegated:7', 'painter', 'ready', 'delegated')])}
        selectedId='local:42'
        sessionIdentityId='local:42'
        text='draft'
        onSelect={onSelect}
      />,
    );

    const trigger = screen.getByRole('button', { name: 'Choose posting account, @admin' });

    fireEvent.click(trigger);
    fireEvent.click(screen.getByRole('menuitemradio', { name: /@admin/ }));

    expect(onSelect).not.toHaveBeenCalled();
    expect(document.querySelector('.compose-form__sender-menu')).toBeNull();

    fireEvent.click(trigger);
    fireEvent.click(screen.getByRole('menuitemradio', { name: /painter/ }));

    expect(confirm).toHaveBeenCalled();
    expect(onSelect).not.toHaveBeenCalled();
    expect(document.querySelector('.compose-form__sender-menu')).toBeTruthy();

    confirm.mockRestore();
  });

  it('opens the account menu outside a footer that hides overflow', () => {
    const { container } = render(
      <div className='compose-form__buttons-wrapper'>
        <div className='compose-form__buttons'>
          <SenderIdentity
            header
            composerId='primary'
            current={identity('local:42', 'admin')}
            choices={ImmutableList([identity('local:42', 'admin')])}
            catalog={ImmutableList([identity('local:42', 'admin')])}
            selectedId='local:42'
            sessionIdentityId='local:42'
            onSelect={jest.fn()}
          />
        </div>
      </div>,
    );

    fireEvent.click(screen.getByRole('button', { name: /Choose posting account/ }));

    const menu = document.querySelector('.compose-form__sender-menu');
    const footer = container.querySelector('.compose-form__buttons-wrapper');

    expect(menu).toBeTruthy();
    expect(footer.contains(menu)).toBe(false);
    expect(container.querySelector('.compose-form__buttons').contains(menu)).toBe(false);

    fireEvent.mouseDown(document.body);

    expect(document.querySelector('.compose-form__sender-menu')).toBeNull();
  });

  it('does not let one composer account menu own another composer', () => {
    render(
      <React.Fragment>
        <SenderIdentity
          header
          composerId='primary'
          current={identity('local:42', 'admin')}
          choices={ImmutableList([identity('local:42', 'admin')])}
          catalog={ImmutableList([identity('local:42', 'admin')])}
          selectedId='local:42'
          sessionIdentityId='local:42'
          onSelect={jest.fn()}
        />
        <SenderIdentity
          header
          composerId='portable:list:9'
          current={identity('local:7', 'editor')}
          choices={ImmutableList([identity('local:7', 'editor')])}
          catalog={ImmutableList([identity('local:7', 'editor')])}
          selectedId='local:7'
          sessionIdentityId='local:7'
          onSelect={jest.fn()}
        />
      </React.Fragment>,
    );

    const [primaryButton, portableButton] = screen.getAllByRole('button', { name: /Choose posting account/ });

    fireEvent.click(primaryButton);
    expect(document.querySelector('[data-composer-id="primary"]')).toBeTruthy();

    fireEvent.mouseDown(portableButton);
    fireEvent.click(portableButton);

    expect(document.querySelector('[data-composer-id="primary"]')).toBeNull();
    expect(document.querySelector('[data-composer-id="portable:list:9"]')).toBeTruthy();

    fireEvent.keyDown(document, { key: 'Escape' });

    expect(document.querySelector('.compose-form__sender-menu')).toBeNull();
    expect(document.activeElement).toBe(portableButton);
  });

  it('shows reply and quote as separate permissions on a linked account', () => {
    const replyOnly = identity('delegated:7', 'painter', 'ready', 'delegated').set('capabilities', ImmutableMap({
      post: 'supported',
      reply: 'supported',
      quote: 'unavailable',
    }));
    const quoteOnly = identity('delegated:8', 'quoter', 'ready', 'delegated').set('capabilities', ImmutableMap({
      post: 'supported',
      reply: 'unavailable',
      quote: 'supported',
    }));

    render(
      <SenderIdentity
        header
        current={replyOnly}
        catalog={ImmutableList([identity('local:42', 'admin'), replyOnly, quoteOnly])}
        choices={ImmutableList([identity('local:42', 'admin'), replyOnly, quoteOnly])}
        selectedId='delegated:7'
        sessionIdentityId='local:42'
        onSelect={jest.fn()}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: /Choose posting account/ }));

    expect(screen.getByTestId('sender-capabilities-delegated:7').textContent).toContain('Replies');
    expect(screen.getByTestId('sender-capabilities-delegated:7').textContent).not.toContain('Quotes');
    expect(screen.getByTestId('sender-capabilities-delegated:8').textContent).toContain('Quotes');
    expect(screen.getByTestId('sender-capabilities-delegated:8').textContent).not.toContain('Replies');
  });

  it('keeps the compact sender label in simple mode', () => {
    render(
      <SenderIdentity
        compact
        current={identity('local:42', 'admin')}
        choices={ImmutableList([identity('local:42', 'admin')])}
        selectedId='local:42'
        sessionIdentityId='local:42'
      />,
    );

    expect(document.querySelector('.compose-form__sender--compact')).toBeTruthy();
    expect(screen.getByTestId('sender-identity').textContent).toContain('Posting as');
    expect(screen.getByTestId('sender-identity-current').textContent).toContain('@admin');
  });

  it('shows only the signed-in avatar when identity selection is unavailable', () => {
    render(
      <SenderIdentity
        header
        selectable={false}
        current={identity('local:42', 'admin')}
        selectedId='local:42'
      />,
    );

    expect(document.querySelector('.compose-form__sender-avatar').getAttribute('src')).toBe('/avatars/admin.png');
    expect(screen.queryByRole('button', { name: /Choose posting account/ })).toBeNull();
    expect(screen.queryByRole('menuitemradio')).toBeNull();
    expect(screen.getByTestId('sender-identity-current').textContent).toContain('@admin');
  });
});
