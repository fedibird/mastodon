/* eslint-disable react/prop-types */

import { render, screen } from '@testing-library/react';
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
  disableRelativeTime: false,
  hideLinkPreview: true,
  hidePhotoPreview: true,
  hideVideoPreview: true,
  hideRebloggedBy: false,
}));

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    formatMessage: ({ defaultMessage }, values) => {
      if (!values) return defaultMessage;
      return defaultMessage.replace(/\{(\w+)\}/g, (_, key) => String(values[key]));
    },
    formatDate: value => `formatted:${value}`,
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
jest.mock('../status_content', () => () => null);
jest.mock('../status_action_bar', () => () => null);
jest.mock('../avatar', () => () => null);
jest.mock('../avatar_overlay', () => () => null);
jest.mock('../avatar_composite', () => () => null);
jest.mock('../display_name', () => () => <span>name</span>);
jest.mock('../absolute_timestamp', () => () => <span>absolute</span>);
jest.mock('../relative_timestamp', () => () => <time>1d</time>);
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
  created_at: '2026-09-23T20:11:00.000Z',
  edited_at: null,
  matched_filters: false,
  url: 'https://example.test/s1',
  in_reply_to_id: null,
  in_reply_to_account_id: null,
  replies_count: 0,
  replies_total: 0,
  ...overrides,
});

const renderStatus = status => render(
  <Provider store={store}>
    <Status
      status={status}
      pictureInPicture={pictureInPicture}
      addEmojiReaction={jest.fn()}
      removeEmojiReaction={jest.fn()}
      onAddToList={jest.fn()}
    />
  </Provider>,
);

describe('Status timeline edit indicator', () => {
  it('shows an asterisk inside the permalink for an edited status', () => {
    const { container } = renderStatus(buildStatus({ edited_at: '2026-09-24T20:11:00.000Z' }));
    const link = container.querySelector('a.status__relative-time');
    const abbr = link.querySelector('abbr');

    expect(abbr).toHaveTextContent('*');
    expect(abbr).toHaveAttribute('title', 'Edited formatted:2026-09-24T20:11:00.000Z');
    expect(screen.queryByRole('button', { name: /Edited/ })).not.toBeInTheDocument();
  });

  it('does not show an edit asterisk for an unedited status', () => {
    const { container } = renderStatus(buildStatus({ edited_at: null }));
    const link = container.querySelector('a.status__relative-time');

    expect(link.querySelector('abbr')).toBeNull();
    expect(link).not.toHaveTextContent('*');
    expect(screen.queryByRole('button', { name: /Edited/ })).not.toBeInTheDocument();
  });
});
