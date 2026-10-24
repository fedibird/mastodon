/* eslint-disable react/prop-types */

import { fireEvent, render, screen } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import PropTypes from 'prop-types';
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
  me: 'owner',
  autoPlayEmoji: false,
  disableReactions: false,
  translationBarVisibility: 'always',
  translationPreferredMode: 'translated',
  languages: [['en', 'English', 'English']],
}));

jest.mock('react-intl', () => {
  const React = require('react');
  const intl = {
    locale: 'en',
    formatMessage: ({ defaultMessage }, values) => {
      let message = defaultMessage;

      if (values) {
        Object.keys(values).forEach(key => {
          message = message.replace(`{${key}}`, values[key]);
        });
      }

      return message;
    },
    formatDate: () => 'Jan 1',
    now: () => Date.now(),
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage, values }) => intl.formatMessage({ defaultMessage }, values),
    FormattedDate: () => 'date',
  };
});

const mockHandlers = {};

jest.mock('react-hotkeys', () => ({
  HotKeys: ({ children, handlers }) => {
    Object.assign(mockHandlers, handlers);
    return children;
  },
}));

jest.mock('../account_action_bar', () => () => <div data-testid='account-action-bar' />);
jest.mock('../status_action_bar', () => () => null);
jest.mock('../avatar', () => () => <span data-testid='account-avatar'>OWNER-AVATAR</span>);
jest.mock('../avatar_overlay', () => () => <span data-testid='account-avatar'>OWNER-AVATAR</span>);
jest.mock('../avatar_composite', () => () => null);
jest.mock('../display_name', () => () => <span data-testid='account-name'>Owner Face @owner</span>);
jest.mock('../absolute_timestamp', () => () => <span>time</span>);
jest.mock('../relative_timestamp', () => () => <span>time</span>);
jest.mock('../icon', () => ({ id }) => <i data-icon={id} />);
jest.mock('mastodon/components/icon', () => ({ id }) => <i data-icon={id} />);
jest.mock('mastodon/components/emoji_reactions_bar', () => () => null);
jest.mock('mastodon/components/picture_in_picture_placeholder', () => () => null);
jest.mock('../../features/ui/components/bundle', () => () => null);
jest.mock('../../features/status/components/card', () => () => null);
jest.mock('mastodon/containers/poll_container', () => () => null);
jest.mock('../permalink', () => ({ children }) => <span>{children}</span>);
jest.mock('mastodon/components/media_gallery', () => () => null);
jest.mock('mastodon/features/video', () => () => null);
jest.mock('mastodon/features/audio', () => () => null);

import Status, { textForScreenReader } from '../status';
import DetailedStatus from '../../features/status/components/detailed_status';
import StatusItem from '../status_item';

const store = createStore(() => fromJS({
  relationships: {},
  server: { translationLanguages: { items: {} } },
}));

const pictureInPicture = fromJS({ inUse: false, available: false });

const account = {
  id: 'owner',
  acct: 'owner',
  username: 'owner',
  display_name: 'Owner Face',
  display_name_html: 'Owner Face',
  url: 'https://fedibird.test/@owner',
  avatar: 'https://fedibird.test/avatars/owner.png',
  group: false,
};

const presentation = (extra = {}) => ({
  kind: 'external_source',
  name: 'Blog name',
  subtitle: 'RSS',
  source_url: 'https://blog.example/',
  icon_url: null,
  thumbnail_url: null,
  byline_name: 'Ada Lovelace',
  ...extra,
});

const base = (overrides = {}) => ({
  id: 's1',
  account,
  content: 'article',
  contentHtml: '<p>Article body</p>',
  spoilerHtml: '',
  spoiler_text: '',
  search_index: 'Article body',
  language: 'en',
  visibility: 'public',
  hidden: false,
  reblog: null,
  quote: null,
  media_attachments: [],
  created_at: '2024-01-01T00:00:00.000Z',
  url: 'https://fedibird.test/@owner/s1',
  in_reply_to_id: null,
  in_reply_to_account_id: null,
  matched_filters: false,
  reblogs_count: 0,
  favourites_count: 0,
  emoji_reactions_count: 0,
  status_referred_by_count: 0,
  ...overrides,
});

const externalStatus = (extra = {}, overrides = {}) => fromJS(base({
  visibility: 'external',
  fedibird_external: { protocol: 'rss', source_title: 'Blog name', canonical_url: 'https://blog.example/posts/1', interaction: 'local_only', presentation: presentation(extra) },
  ...overrides,
}));

class RouterProvider extends React.Component {

  static childContextTypes = { router: PropTypes.object };

  getChildContext () {
    return { router: { history: this.props.history } };
  }

  render () {
    return this.props.children;
  }

}

const history = { push: jest.fn() };

const timeline = (status, props = {}) => render(
  <Provider store={store}>
    <RouterProvider history={history}>
      <Status
        status={status}
        pictureInPicture={pictureInPicture}
        addEmojiReaction={jest.fn()}
        removeEmojiReaction={jest.fn()}
        onAddToList={jest.fn()}
        onToggleCollapsed={jest.fn()}
        onMention={jest.fn()}
        {...props}
      />
    </RouterProvider>
  </Provider>,
);

const detail = (status) => render(
  <Provider store={store}>
    <RouterProvider history={history}>
      <DetailedStatus
        status={status}
        pictureInPicture={pictureInPicture}
        domain='fedibird.test'
        onOpenMedia={jest.fn()}
        onOpenVideo={jest.fn()}
        onOpenMediaQuote={jest.fn()}
        onOpenVideoQuote={jest.fn()}
        onToggleHidden={jest.fn()}
        addEmojiReaction={jest.fn()}
        removeEmojiReaction={jest.fn()}
      />
    </RouterProvider>
  </Provider>,
);

beforeEach(() => {
  history.push.mockClear();
  Object.keys(mockHandlers).forEach(key => delete mockHandlers[key]);
});

describe.each([
  ['timeline status', timeline],
  ['detailed status', detail],
])('%s of an external projection', (_label, renderStatus) => {
  it('names the external source and never the owner account', () => {
    renderStatus(externalStatus());

    expect(screen.getByText('Blog name')).toBeTruthy();
    expect(screen.getByText('RSS · External content (only you)')).toBeTruthy();
    expect(screen.getByText('by Ada Lovelace')).toBeTruthy();
    expect(screen.queryByTestId('account-avatar')).toBeNull();
    expect(screen.queryByTestId('account-name')).toBeNull();
    expect(screen.queryByText(/Owner Face/)).toBeNull();
    expect(document.querySelector('[data-external-source] [data-icon="rss"]')).toBeTruthy();
    expect(document.querySelector('a[href*="/@owner"]')).toBeFalsy();
  });

  it('points the time link at the article, not at an owner status page', () => {
    renderStatus(externalStatus());
    const time = document.querySelector('.status__relative-time, .detailed-status__datetime');

    expect(time.getAttribute('href')).toBe('https://blog.example/posts/1');
    expect(time.getAttribute('target')).toBe('_blank');
    expect(time.getAttribute('rel')).toBe('noopener noreferrer');
  });

  it('links the name to the source site in a new tab and never routes to the owner profile', () => {
    renderStatus(externalStatus());
    const link = document.querySelector('a[data-external-source]');

    expect(link.getAttribute('href')).toBe('https://blog.example/');
    expect(link.getAttribute('target')).toBe('_blank');
    expect(link.getAttribute('rel')).toBe('noopener noreferrer');
    expect(link.getAttribute('data-id')).toBeNull();

    fireEvent.click(link, { button: 0 });
    expect(history.push).not.toHaveBeenCalled();
  });

  it('renders no link at all when there is no verified source url', () => {
    renderStatus(externalStatus({ source_url: null }));

    expect(screen.getByText('Blog name')).toBeTruthy();
    expect(document.querySelector('a[data-external-source]')).toBeNull();
    expect(document.querySelector('span[data-external-source]')).toBeTruthy();
    expect(history.push).not.toHaveBeenCalled();
  });

  it('refuses a javascript: or data: source url', () => {
    renderStatus(externalStatus({ source_url: 'javascript:alert(1)' }));

    expect(document.querySelector('a[data-external-source]')).toBeNull();
    expect(document.querySelector('[href^="javascript:"]')).toBeNull();
  });

  it('renders markup in names as text and creates no elements from it', () => {
    renderStatus(externalStatus({ name: '<img src=x onerror=alert(1)>', byline_name: '<b>bold</b>' }));

    expect(screen.getByText('<img src=x onerror=alert(1)>')).toBeTruthy();
    expect(screen.getByText('by <b>bold</b>')).toBeTruthy();
    expect(document.querySelector('[data-external-source] img')).toBeNull();
    expect(document.querySelector('[data-external-source] b')).toBeNull();
  });

  it('uses a managed icon when given and falls back to the protocol icon when it breaks', () => {
    renderStatus(externalStatus({ icon_url: 'https://fedibird.test/system/external/icon.png' }));
    const image = document.querySelector('.external-source-icon__image');

    expect(image.getAttribute('src')).toBe('https://fedibird.test/system/external/icon.png');
    expect(image.getAttribute('alt')).toBe('');
    expect(image.getAttribute('referrerpolicy')).toBe('no-referrer');
    expect(document.querySelector('.external-source-icon').getAttribute('aria-hidden')).toBe('true');

    fireEvent.error(image);

    expect(document.querySelector('.external-source-icon__image')).toBeNull();
    expect(document.querySelector('.external-source-icon [data-icon="rss"]')).toBeTruthy();
  });

  it('does not load a raw third-party image', () => {
    renderStatus(externalStatus({ icon_url: 'http://tracker.example/pixel.gif' }));

    expect(document.querySelector('.external-source-icon__image')).toBeNull();
    expect(document.querySelector('.external-source-icon [data-icon="rss"]')).toBeTruthy();
  });

  it('shows the generic external identity, not the owner, when the presentation is missing', () => {
    renderStatus(fromJS(base({ visibility: 'external', fedibird_external: { protocol: 'atom', source_title: 'Old API feed' } })));

    expect(screen.getByText('Old API feed')).toBeTruthy();
    expect(screen.getByText('Atom · External content (only you)')).toBeTruthy();
    expect(screen.queryByTestId('account-name')).toBeNull();
    expect(document.querySelector('a[data-external-source]')).toBeNull();
  });
});

describe('ordinary statuses are unchanged', () => {
  it.each([
    ['timeline', timeline],
    ['detail', detail],
  ])('keeps the account avatar, name, and profile link on a normal %s status', (_label, renderStatus) => {
    renderStatus(fromJS(base()));

    expect(screen.getByTestId('account-avatar')).toBeTruthy();
    expect(screen.getByTestId('account-name')).toBeTruthy();
    expect(document.querySelector('[data-external-source]')).toBeNull();
    expect(document.querySelector('a[href="https://fedibird.test/@owner"]')).toBeTruthy();
  });

  it('keeps the author of a boosted public link note and the booster prepend', () => {
    const note = base({ id: 'note', content: 'link note' });
    const wrapper = fromJS(base({ id: 'wrap', content: '', reblog: note }));

    timeline(wrapper);

    expect(screen.getAllByTestId('account-name').length).toBeGreaterThan(0);
    expect(document.querySelector('[data-external-source]')).toBeNull();
    expect(document.querySelector('.status__prepend')).toBeTruthy();
  });

  it('keeps a personal status with the owner identity when it has no presentation', () => {
    timeline(fromJS(base({ visibility: 'personal' })));

    expect(screen.getByTestId('account-name')).toBeTruthy();
    expect(document.querySelector('[data-external-source]')).toBeNull();
  });
});

describe('external timeline status details', () => {
  it('hides the account follow action bar for an external projection', () => {
    timeline(externalStatus());
    expect(screen.queryByTestId('account-action-bar')).toBeNull();

    document.body.innerHTML = '';
    timeline(fromJS(base()));
    expect(screen.getByTestId('account-action-bar')).toBeTruthy();
  });

  it('does not open the owner profile or mention the owner from the keyboard', () => {
    const onMention = jest.fn();
    timeline(externalStatus(), { onMention });

    mockHandlers.openProfile();
    mockHandlers.mention({ preventDefault: jest.fn() });

    expect(history.push).not.toHaveBeenCalled();
    expect(onMention).not.toHaveBeenCalled();
  });

  it('still routes a normal status to the profile and mention', () => {
    const onMention = jest.fn();
    timeline(fromJS(base()), { onMention });

    mockHandlers.openProfile();
    mockHandlers.mention({ preventDefault: jest.fn() });

    expect(history.push).toHaveBeenCalledWith('/accounts/owner');
    expect(onMention).toHaveBeenCalled();
  });

  it('reads the source and the private scope aloud instead of the owner name and handle', () => {
    const intl = { formatDate: () => 'Jan 1', formatMessage: ({ defaultMessage }, values) => defaultMessage.replace(/\{(\w+)\}/g, (_, key) => values[key]) };
    const text = textForScreenReader(intl, externalStatus());

    expect(text).toContain('External content from Blog name (RSS) by Ada Lovelace, only visible to you');
    expect(text).toContain('Article body');
    expect(text).not.toContain('Owner Face');
    expect(text).not.toContain('owner');
    expect(document.body.innerHTML).not.toContain('Owner Face');
  });

  it('puts the same reader text on the status wrapper', () => {
    timeline(externalStatus());

    const label = document.querySelector('.status__wrapper').getAttribute('aria-label');

    expect(label).toContain('External content from Blog name (RSS)');
    expect(label).not.toContain('Owner Face');
  });
});

describe('quote and mini status', () => {
  it('names the source in the quote header of a timeline and a detailed status', () => {
    const quoted = fromJS(base({ id: 'q', visibility: 'public', quote: externalStatus().toJS(), quote_id: 'q' }));

    [timeline, detail].forEach(renderStatus => {
      document.body.innerHTML = '';
      renderStatus(quoted);
      const header = document.querySelector('.quote-status .status__info');

      expect(header.textContent).toContain('Blog name');
      expect(header.textContent).not.toContain('Owner Face');
      expect(header.querySelector('[data-external-source]')).toBeTruthy();
    });
  });

  it('draws the source icon in the mini status and no profile link', () => {
    render(
      <RouterProvider history={history}>
        <StatusItem status={externalStatus()} onUnselectReference={jest.fn()} />
      </RouterProvider>,
    );

    expect(document.querySelector('.mini-status__avatar [data-icon="rss"]')).toBeTruthy();
    expect(screen.queryByTestId('account-avatar')).toBeNull();
    expect(document.querySelector('.mini-status__account a')).toBeNull();
  });
});
