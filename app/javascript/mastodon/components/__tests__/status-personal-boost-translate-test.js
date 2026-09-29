/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

jest.mock('mastodon/initial_state', () => ({
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
  me: '1',
  autoPlayEmoji: false,
  disableReactions: false,
  translationPrivateContentAllowed: false,
  translationBarVisibility: 'always',
  translationPreferredMode: 'both',
  languages: [
    ['en', 'English', 'English'],
    ['ja', 'Japanese', '日本語'],
  ],
}));

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    locale: 'ja',
    formatMessage: ({ defaultMessage }, values) => {
      let message = defaultMessage;

      if (values) {
        Object.keys(values).forEach(key => {
          message = message.replace(`{${key}}`, values[key]);
        });
      }

      return message;
    },
    formatDate: () => '',
    now: () => Date.now(),
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage, values }) => intl.formatMessage({ defaultMessage }, values),
    FormattedDate: () => 'date',
  };
});

jest.mock('react-hotkeys', () => ({
  HotKeys: ({ children }) => children,
}));

jest.mock('../account_action_bar', () => () => null);
jest.mock('../status_action_bar', () => () => null);
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
jest.mock('mastodon/containers/poll_container', () => () => null);
jest.mock('../permalink', () => ({ children }) => <span>{children}</span>);
jest.mock('mastodon/components/media_gallery', () => () => null);
jest.mock('mastodon/features/video', () => () => null);
jest.mock('mastodon/features/audio', () => () => null);

import Status from '../status';
import DetailedStatus from '../../features/status/components/detailed_status';

const store = createStore(() => fromJS({
  relationships: {},
  server: {
    translationLanguages: {
      items: { en: ['ja'] },
    },
  },
}));

const pictureInPicture = fromJS({ inUse: false, available: false });

const accountFor = (id) => ({
  id,
  acct: `user-${id}`,
  username: `user-${id}`,
  display_name: `User ${id}`,
  display_name_html: `User ${id}`,
  url: `https://example.test/${id}`,
  avatar: '',
  group: false,
});

const properStatus = (accountId, visibility = 'public') => ({
  id: 'proper',
  account: accountFor(accountId),
  content: 'Hello',
  contentHtml: '<p>Hello</p>',
  spoilerHtml: '',
  spoiler_text: '',
  search_index: 'Hello',
  language: 'en',
  visibility,
  hidden: false,
  mentions: [],
  media_attachments: [],
  reblog: null,
  created_at: '2024-01-01T00:00:00.000Z',
  url: 'https://example.test/proper',
});

const boost = (wrapperVisibility, properAccountId, properVisibility = 'public') => fromJS({
  id: 'wrap',
  account: accountFor('1'),
  content: '',
  contentHtml: '',
  spoilerHtml: '',
  spoiler_text: '',
  search_index: '',
  language: null,
  visibility: wrapperVisibility,
  hidden: false,
  mentions: [],
  media_attachments: [],
  reblog: properStatus(properAccountId, properVisibility),
  created_at: '2024-01-01T00:00:00.000Z',
  url: 'https://example.test/wrap',
});

const renderTimeline = (status, onTranslate) => render(
  <Provider store={store}>
    <Status
      status={status}
      pictureInPicture={pictureInPicture}
      addEmojiReaction={jest.fn()}
      removeEmojiReaction={jest.fn()}
      onAddToList={jest.fn()}
      onToggleCollapsed={jest.fn()}
      onTranslate={onTranslate}
    />
  </Provider>,
);

const renderDetail = (status, onTranslate) => render(
  <Provider store={store}>
    <DetailedStatus
      status={status}
      pictureInPicture={pictureInPicture}
      domain='example.test'
      onTranslate={onTranslate}
      onOpenMedia={jest.fn()}
      onOpenVideo={jest.fn()}
      onOpenMediaQuote={jest.fn()}
      onOpenVideoQuote={jest.fn()}
      onToggleHidden={jest.fn()}
      addEmojiReaction={jest.fn()}
      removeEmojiReaction={jest.fn()}
    />
  </Provider>,
);

describe.each([
  ['timeline status', renderTimeline],
  ['detailed status', renderDetail],
])('%s personal boost translation', (_label, renderStatus) => {
  it('hides Translate when a personal wrapper boosts someone else', () => {
    renderStatus(boost('personal', '9', 'public'), jest.fn());

    expect(screen.queryByRole('button', { name: 'Translate' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Bilingual' })).toBeNull();
  });

  it('translates a personal wrapper of the viewer own status through the wrapper id', () => {
    const onTranslate = jest.fn();
    renderStatus(boost('personal', '1', 'private'), onTranslate);

    expect(screen.getByRole('button', { name: 'Translate' })).toBeEnabled();
    expect(screen.getByRole('button', { name: 'Bilingual' })).toBeEnabled();
    fireEvent.click(screen.getByRole('button', { name: 'Translate' }));

    expect(onTranslate).toHaveBeenCalledTimes(1);
    expect(onTranslate.mock.calls[0][0].get('id')).toBe('wrap');
    expect(onTranslate.mock.calls[0][0].get('visibility')).toBe('personal');
    expect(onTranslate.mock.calls[0][1]).toBe('translated');
  });

  it('keeps an ordinary boost request on the boosted status', () => {
    const onTranslate = jest.fn();
    renderStatus(boost('public', '9', 'public'), onTranslate);

    fireEvent.click(screen.getByRole('button', { name: 'Translate' }));

    expect(onTranslate).toHaveBeenCalledTimes(1);
    expect(onTranslate.mock.calls[0][0].get('id')).toBe('proper');
    expect(onTranslate.mock.calls[0][1]).toBe('translated');
  });
});
