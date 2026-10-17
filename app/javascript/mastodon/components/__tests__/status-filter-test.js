/* eslint-disable react/prop-types */

import { render, fireEvent, screen } from '@testing-library/react';
import React from 'react';
import { fromJS } from 'immutable';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('../../initial_state', () => ({
  displayMedia: 'default',
  enableReaction: false,
  compactReaction: false,
  show_reply_tree_button: false,
  enableStatusReference: false,
  disableRelativeTime: true,
  hideLinkPreview: true,
  hidePhotoPreview: true,
  hideVideoPreview: true,
  hideRebloggedBy: false,
}));

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    formatMessage: ({ defaultMessage }) => defaultMessage,
    formatDate: () => '',
    now: () => Date.now(),
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
    IntlProvider: ({ children }) => children,
  };
});

jest.mock('react-hotkeys', () => ({
  HotKeys: ({ children }) => children,
}));

jest.mock('../account_action_bar', () => () => null);
jest.mock('../status_content', () => ({ status }) => <div>{status.get('content')}</div>);
jest.mock('../status_action_bar', () => ({ onFilter }) => (
  onFilter
    ? <button type='button' title='Hide post' onClick={onFilter}>Hide post</button>
    : null
));
jest.mock('../avatar', () => () => null);
jest.mock('../avatar_overlay', () => () => null);
jest.mock('../avatar_composite', () => () => null);
jest.mock('../display_name', () => () => <span>name</span>);
jest.mock('../absolute_timestamp', () => () => <span>time</span>);
jest.mock('../relative_timestamp', () => () => <span>time</span>);
jest.mock('../icon', () => () => null);
jest.mock('mastodon/components/icon', () => () => null);
jest.mock('mastodon/components/emoji_reactions_bar', () => () => null);
jest.mock('mastodon/components/picture_in_picture_placeholder', () => () => null);
jest.mock('../../features/ui/components/bundle', () => () => null);
jest.mock('../../features/status/components/card', () => () => null);

import Status from '../status';

const store = createStore(() => fromJS({
  relationships: {},
}));

const knownEmoji = {
  shortcode: 'known',
  url: 'https://cdn.example.test/known.gif',
  static_url: 'https://cdn.example.test/known.png',
};

const otherEmoji = {
  shortcode: 'other',
  url: 'https://cdn.example.test/other.gif',
  static_url: 'https://cdn.example.test/other.png',
};

const createEmojiStore = (emojis = []) => createStore((state, action) => {
  if (action.type === 'TEST_SET_EMOJIS') {
    return state.set('custom_emojis', fromJS(action.custom_emojis));
  }

  return state;
}, fromJS({
  relationships: {},
  custom_emojis: emojis,
}));

const pictureInPicture = fromJS({ inUse: false, available: false });

const buildStatus = (overrides = {}) => fromJS({
  id: 's1',
  account: {
    id: 'a1',
    acct: 'alice',
    username: 'alice',
    display_name: 'Alice',
    display_name_html: 'Alice',
    url: 'https://example.test/alice',
    avatar: '',
    group: false,
  },
  content: 'hello world',
  search_index: 'hello world',
  spoiler_text: '',
  hidden: false,
  reblog: null,
  quote: null,
  quote_id: null,
  media_attachments: [],
  visibility: 'public',
  created_at: '2024-01-01T00:00:00.000Z',
  matched_filters: false,
  url: 'https://example.test/s1',
  in_reply_to_id: null,
  in_reply_to_account_id: null,
  replies_count: 0,
  replies_total: 0,
  ...overrides,
});

const renderStatus = (status, extraProps = {}, statusStore = store) => render(
  <Provider store={statusStore}>
    <Status
      status={status}
      pictureInPicture={pictureInPicture}
      addEmojiReaction={jest.fn()}
      removeEmojiReaction={jest.fn()}
      onAddToList={jest.fn()}
      {...extraProps}
    />
  </Provider>,
);

describe('Status filter warning UI', () => {
  const filteredText = () => screen.getByRole('button', { name: 'Show anyway' }).parentElement.textContent;

  it('shows matched filter titles and Show anyway', () => {
    renderStatus(buildStatus({ matched_filters: ['spoiler'] }));

    expect(filteredText()).toContain('Filtered');
    expect(filteredText()).toContain('spoiler');
    expect(screen.getByRole('button', { name: 'Show anyway' })).toBeInTheDocument();
    expect(screen.queryByTitle('Hide post')).not.toBeInTheDocument();
  });

  it('shows multiple matched filter titles', () => {
    renderStatus(buildStatus({ matched_filters: ['spoiler', 'politics'] }));

    expect(filteredText()).toContain('spoiler, politics');
  });

  it('reveals the status after Show anyway', () => {
    renderStatus(buildStatus({ matched_filters: ['spoiler'] }));

    fireEvent.click(screen.getByRole('button', { name: 'Show anyway' }));

    expect(screen.getByText('hello world')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Show anyway' })).not.toBeInTheDocument();
    expect(screen.getByTitle('Hide post')).toBeInTheDocument();
  });

  it('re-hides the status from the eye button', () => {
    renderStatus(buildStatus({ matched_filters: ['spoiler'] }));

    fireEvent.click(screen.getByRole('button', { name: 'Show anyway' }));
    fireEvent.click(screen.getByTitle('Hide post'));

    expect(filteredText()).toContain('Filtered');
    expect(screen.getByRole('button', { name: 'Show anyway' })).toBeInTheDocument();
    expect(screen.queryByText('hello world')).not.toBeInTheDocument();
  });

  it('does not show a placeholder or eye button for ordinary statuses', () => {
    renderStatus(buildStatus({ matched_filters: false }));

    expect(screen.queryByRole('button', { name: 'Show anyway' })).not.toBeInTheDocument();
    expect(screen.queryByTitle('Hide post')).not.toBeInTheDocument();
    expect(screen.getByText('hello world')).toBeInTheDocument();
  });

  it('does not show a placeholder for an empty matched_filters list', () => {
    renderStatus(buildStatus({ matched_filters: [] }));

    expect(screen.queryByRole('button', { name: 'Show anyway' })).not.toBeInTheDocument();
    expect(screen.getByText('hello world')).toBeInTheDocument();
  });

  it('resets Show anyway when the status id changes', () => {
    const { rerender } = renderStatus(buildStatus({ matched_filters: ['spoiler'] }));

    fireEvent.click(screen.getByRole('button', { name: 'Show anyway' }));
    expect(screen.getByText('hello world')).toBeInTheDocument();

    rerender(
      <Provider store={store}>
        <Status
          status={buildStatus({ id: 's2', content: 'next post', matched_filters: ['politics'] })}
          pictureInPicture={pictureInPicture}
          addEmojiReaction={jest.fn()}
          removeEmojiReaction={jest.fn()}
          onAddToList={jest.fn()}
        />
      </Provider>,
    );

    expect(filteredText()).toContain('Filtered');
    expect(filteredText()).toContain('politics');
    expect(screen.queryByText('hello world')).not.toBeInTheDocument();
    expect(screen.queryByText('next post')).not.toBeInTheDocument();
  });

  it('returns to the status body when matched filters disappear after re-hide', () => {
    const { rerender } = renderStatus(buildStatus({ matched_filters: ['spoiler'] }));

    fireEvent.click(screen.getByRole('button', { name: 'Show anyway' }));
    fireEvent.click(screen.getByTitle('Hide post'));
    expect(filteredText()).toContain('Filtered');

    rerender(
      <Provider store={store}>
        <Status
          status={buildStatus({ matched_filters: false })}
          pictureInPicture={pictureInPicture}
          addEmojiReaction={jest.fn()}
          removeEmojiReaction={jest.fn()}
          onAddToList={jest.fn()}
        />
      </Provider>,
    );

    expect(screen.queryByRole('button', { name: 'Show anyway' })).not.toBeInTheDocument();
    expect(screen.queryByTitle('Hide post')).not.toBeInTheDocument();
    expect(screen.getByText('hello world')).toBeInTheDocument();
  });

  it('returns to the status body when matched_filters becomes an empty list', () => {
    const { rerender } = renderStatus(buildStatus({ matched_filters: ['spoiler'] }));

    fireEvent.click(screen.getByRole('button', { name: 'Show anyway' }));
    fireEvent.click(screen.getByTitle('Hide post'));

    rerender(
      <Provider store={store}>
        <Status
          status={buildStatus({ matched_filters: [] })}
          pictureInPicture={pictureInPicture}
          addEmojiReaction={jest.fn()}
          removeEmojiReaction={jest.fn()}
          onAddToList={jest.fn()}
        />
      </Provider>,
    );

    expect(screen.queryByRole('button', { name: 'Show anyway' })).not.toBeInTheDocument();
    expect(screen.queryByTitle('Hide post')).not.toBeInTheDocument();
    expect(screen.getByText('hello world')).toBeInTheDocument();
  });

  it('renders filter titles as text rather than HTML', () => {
    renderStatus(buildStatus({
      matched_filters: ['<script>alert(1)</script>'],
    }));

    const wrapper = screen.getByRole('button', { name: 'Show anyway' }).parentElement;
    expect(wrapper.textContent).toContain('<script>alert(1)</script>');
    expect(wrapper.querySelector('script')).toBeNull();
  });

  it('renders a known local shortcode inside the filter placeholder', () => {
    const emojiStore = createEmojiStore([knownEmoji, otherEmoji]);

    renderStatus(buildStatus({
      matched_filters: ['重要 :known: 話題'],
      account: {
        id: 'a1',
        acct: 'alice',
        username: 'alice',
        display_name: 'Alice',
        display_name_html: 'Alice',
        url: 'https://example.test/alice',
        avatar: '',
        group: false,
        emojis: [{
          shortcode: 'known',
          url: 'https://remote.example.test/known.png',
          static_url: 'https://remote.example.test/known.png',
        }],
      },
    }), {}, emojiStore);

    const wrapper = screen.getByRole('button', { name: 'Show anyway' }).parentElement;
    const image = screen.getByRole('img', { name: ':known:' });

    expect(image).toHaveAttribute('src', 'https://cdn.example.test/known.png');
    expect(image).not.toHaveAttribute('src', 'https://remote.example.test/known.png');
    expect(wrapper.textContent).toContain('重要 ');
    expect(wrapper.textContent).toContain(' 話題');
    expect(wrapper).toHaveAttribute('tabindex', '0');
  });

  it('renders adjacent shortcodes and keeps each filter title', () => {
    renderStatus(buildStatus({
      matched_filters: ['理由A :known::other:', '理由B'],
    }), {}, createEmojiStore([knownEmoji, otherEmoji]));

    const wrapper = screen.getByRole('button', { name: 'Show anyway' }).parentElement;
    const images = wrapper.querySelectorAll('img.custom-emoji');

    expect(images).toHaveLength(2);
    expect(images[0]).toHaveAttribute('alt', ':known:');
    expect(images[1]).toHaveAttribute('alt', ':other:');
    expect(images[0].nextSibling).toBe(images[1]);
    expect(wrapper.textContent).toContain('理由A ');
    expect(wrapper.textContent).toContain(', ');
    expect(wrapper.textContent).toContain('理由B');
  });

  it('leaves an unknown shortcode as text in the placeholder', () => {
    renderStatus(buildStatus({
      matched_filters: ['確認 :unknown:'],
    }), {}, createEmojiStore([knownEmoji]));

    const wrapper = screen.getByRole('button', { name: 'Show anyway' }).parentElement;

    expect(wrapper.querySelector('img')).toBeNull();
    expect(wrapper.textContent).toContain('確認 :unknown:');
  });

  it('does not execute HTML written into a filter title', () => {
    renderStatus(buildStatus({
      matched_filters: ['<img src=x onerror=alert(1)>'],
    }), {}, createEmojiStore([knownEmoji]));

    const wrapper = screen.getByRole('button', { name: 'Show anyway' }).parentElement;

    expect(wrapper.textContent).toContain('<img src=x onerror=alert(1)>');
    expect(wrapper.querySelector('img')).toBeNull();
    expect(wrapper.querySelector('script')).toBeNull();
  });

  it('replaces shortcodes already on screen when the local catalog arrives', () => {
    const emojiStore = createEmojiStore([]);

    renderStatus(buildStatus({
      matched_filters: ['確認 :known:'],
    }), {}, emojiStore);

    const wrapper = screen.getByRole('button', { name: 'Show anyway' }).parentElement;

    expect(wrapper.querySelector('img')).toBeNull();
    expect(wrapper.textContent).toContain('確認 :known:');

    emojiStore.dispatch({ type: 'TEST_SET_EMOJIS', custom_emojis: [knownEmoji] });

    expect(screen.getByRole('img', { name: ':known:' })).toHaveAttribute('src', 'https://cdn.example.test/known.png');
    expect(wrapper.textContent).toContain('確認 ');
    expect(wrapper.textContent).not.toContain(':known:');
  });

  it('still reveals the status from Show anyway when the reason contains an emoji', () => {
    renderStatus(buildStatus({
      matched_filters: ['確認 :known:'],
    }), {}, createEmojiStore([knownEmoji]));

    const button = screen.getByRole('button', { name: 'Show anyway' });

    button.focus();
    expect(button).toHaveFocus();
    fireEvent.click(button);

    expect(screen.getByText('hello world')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Show anyway' })).not.toBeInTheDocument();
    expect(screen.queryByRole('img', { name: ':known:' })).not.toBeInTheDocument();
  });

  it('renders quotes and reblogs without a filter placeholder', () => {
    const quoted = {
      id: 'q1',
      visibility: 'public',
      content: 'quoted text',
      spoiler_text: '',
      hidden: false,
      media_attachments: [],
      account: {
        id: 'a2',
        acct: 'bob',
        username: 'bob',
        display_name: 'Bob',
        url: 'https://example.test/bob',
        group: false,
      },
    };

    renderStatus(buildStatus({ quote: quoted }));
    expect(screen.getByText('hello world')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Show anyway' })).not.toBeInTheDocument();
  });
});
