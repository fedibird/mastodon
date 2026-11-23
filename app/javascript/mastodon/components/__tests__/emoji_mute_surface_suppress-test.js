import { render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/initial_state', () => ({
  me: '1',
  autoPlayEmoji: false,
  reduceMotion: true,
  hideReactionCounter: false,
  hideListOfEmojiReactionsToPosts: false,
}));

import CustomEmojiText from '../custom_emoji_text';
import DisplayName from '../display_name';
import EmojiReactionsBar from '../emoji_reactions_bar';

const OK = '👌';
const emojiHtml = `Alice <img class="emojione" alt="${OK}" title="${OK}" src="/emoji/1f44c.svg" srcset="/emoji/1f44c.svg 2x"><img class="emojione custom-emoji" alt=":blob:" src="https://cdn.example/secret.svg" data-shortcode="blob" data-domain=""><img src="/media/x.jpg" alt="${OK}" srcset="/media/x.jpg 2x">`;

const storeFor = display => createStore(() => fromJS({
  emojiMutes: { display, rules: [], phase: display === 'suppress' ? 'error' : 'ready', availability: 'enabled' },
}));

const account = fromJS({
  id: 'a1',
  acct: 'alice',
  display_name_html: emojiHtml,
});

describe('unverified emoji on profile, reactions, and custom emoji text', () => {
  it('suppresses a display name without removing the account photo alt source', () => {
    const { container } = render(
      <Provider store={storeFor('suppress')}>
        <DisplayName account={account} />
      </Provider>,
    );
    const photo = container.querySelector('img[src="/media/x.jpg"]');

    expect(container.querySelector('img.emojione, img.custom-emoji')).toBeNull();
    expect(container.innerHTML).not.toContain('/emoji/1f44c.svg');
    expect(container.innerHTML).not.toContain('secret.svg');
    expect(container.innerHTML).not.toContain(OK);
    expect(photo.getAttribute('alt')).toBe('◻');
    expect(photo.getAttribute('srcset')).toBe('/media/x.jpg 2x');
  });

  it('shows the display name again when emoji muting is off', () => {
    const { container } = render(
      <Provider store={storeFor('show')}>
        <DisplayName account={account} />
      </Provider>,
    );

    expect(container.querySelector('img.emojione')).not.toBeNull();
    expect(container.querySelector('img[src="/media/x.jpg"]').getAttribute('alt')).toBe(OK);
  });

  it('renders no reaction controls while unverified', () => {
    const status = fromJS({
      id: 's1',
      emoji_reactions: [{ name: OK, count: 2, account_ids: ['2'], url: 'https://cdn.example/secret.svg' }],
    });
    const { container } = render(
      <Provider store={storeFor('suppress')}>
        <EmojiReactionsBar status={status} addEmojiReaction={jest.fn()} removeEmojiReaction={jest.fn()} />
      </Provider>,
    );

    expect(container.querySelector('.emoji-reactions-bar')).toBeNull();
    expect(container.innerHTML).not.toContain('secret.svg');
    expect(container.innerHTML).not.toContain(OK);
  });

  it('suppresses custom emoji text rendered as images', () => {
    const { container } = render(
      <Provider store={storeFor('suppress')}>
        <CustomEmojiText
          text={`Hi :blob: ${OK}`}
          customEmojis={fromJS([{ shortcode: 'blob', url: 'https://cdn.example/secret.svg', static_url: 'https://cdn.example/secret.png' }])}
        />
      </Provider>,
    );

    expect(container.querySelector('img')).toBeNull();
    expect(container.innerHTML).not.toContain('secret.svg');
    expect(container.innerHTML).not.toContain(OK);
    expect(container.textContent).toContain('Hi');
  });
});
