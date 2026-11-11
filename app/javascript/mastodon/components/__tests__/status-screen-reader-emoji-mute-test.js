/* eslint-disable react/prop-types */

import { act, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

import { EMOJI_MUTES_APPLY } from 'mastodon/actions/emoji_mutes';
import { POLLS_IMPORT } from 'mastodon/actions/importer';
import emojiMutes from 'mastodon/reducers/emoji_mutes';
import pollsReducer from 'mastodon/reducers/polls';
import { resetEmojiMuteTextForTests } from 'mastodon/features/emoji/emoji_mute_text';

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
  cropCardImages: false,
  cardCollapseLongText: false,
  me: '1',
  autoPlayEmoji: false,
}));

jest.mock('react-intl', () => {
  const ReactIntl = require('react');
  const formatMessage = ({ defaultMessage }, values) => {
    let message = defaultMessage || '';

    if (values) {
      Object.keys(values).forEach(key => {
        const value = values[key];

        if (value !== undefined && value !== null && typeof value !== 'object') {
          message = message.replace(`{${key}}`, String(value));
        }
      });
    }

    return message;
  };
  const intl = {
    formatMessage,
    formatDate: () => 'Jan 1',
    now: () => Date.now(),
  };
  const FormattedMessage = ({ defaultMessage, values }) => {
    if (!values) {
      return defaultMessage;
    }

    const parts = [];
    const pattern = /\{(\w+)\}/g;
    let last = 0;
    let match = pattern.exec(defaultMessage || '');

    while (match) {
      parts.push((defaultMessage || '').slice(last, match.index));
      parts.push(values[match[1]]);
      last = match.index + match[0].length;
      match = pattern.exec(defaultMessage || '');
    }

    parts.push((defaultMessage || '').slice(last));
    return ReactIntl.createElement(ReactIntl.Fragment, null, ...parts);
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage,
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
jest.mock('../absolute_timestamp', () => () => null);
jest.mock('../relative_timestamp', () => () => null);
jest.mock('../icon', () => () => null);
jest.mock('mastodon/components/icon', () => () => null);
jest.mock('mastodon/components/emoji_reactions_bar', () => () => null);
jest.mock('mastodon/components/picture_in_picture_placeholder', () => () => null);
jest.mock('../../features/ui/components/bundle', () => () => null);
jest.mock('../../features/status/components/card', () => () => null);
jest.mock('../thumbhash', () => () => null);
jest.mock('mastodon/components/thumbhash', () => () => null);

import Status from '../status';

const THUMB = '👍';
const thumbImg = `<img draggable="false" class="emojione" alt="${THUMB}" src="/emoji/thumb.svg">`;

const rule = (emoji, replacement = '[emoji]') => ({
  id: 'm1',
  revision: '2',
  emoji,
  replacement,
  effects: {
    replace_in_text: true,
    reject_reactions_to_own_posts: true,
    hide_reactions: true,
    hide_in_picker: true,
  },
});

const pictureInPicture = fromJS({ inUse: false, available: false });

const makeStore = () => createStore((state = fromJS({
  emojiMutes: { revision: null, rules: [] },
  relationships: {},
  polls: {},
}), action) => state
  .set('emojiMutes', emojiMutes(state.get('emojiMutes'), action))
  .set('polls', pollsReducer(state.get('polls'), action)));

const apply = (store, mutes) => {
  act(() => {
    store.dispatch({ type: EMOJI_MUTES_APPLY, revision: '2', mutes });
  });
};

const account = (extra = {}) => ({
  id: 'a1',
  acct: 'alice',
  username: 'alice',
  display_name: `Alice ${THUMB}`,
  display_name_html: `Alice ${thumbImg}`,
  url: 'https://example.test/alice',
  avatar: '',
  group: false,
  ...extra,
});

const buildStatus = (extra = {}) => fromJS({
  id: 's1',
  account: account(),
  content: `Hello ${THUMB}`,
  contentHtml: `<p>Hello ${thumbImg}</p>`,
  search_index: `Hello ${THUMB}`,
  spoiler_text: '',
  spoilerHtml: '',
  hidden: false,
  reblog: null,
  quote: null,
  media_attachments: [],
  visibility: 'public',
  created_at: '2024-01-01T00:00:00.000Z',
  url: 'https://example.test/s1',
  in_reply_to_id: null,
  matched_filters: false,
  reblogs_count: 0,
  favourites_count: 0,
  emoji_reactions_count: 0,
  ...extra,
});

const renderStatus = (status, store = makeStore(), props = {}) => render(
  <Provider store={store}>
    <Status
      status={status}
      pictureInPicture={pictureInPicture}
      addEmojiReaction={jest.fn()}
      removeEmojiReaction={jest.fn()}
      onAddToList={jest.fn()}
      {...props}
    />
  </Provider>,
);

describe('mounted screen reader labels', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
  });

  it('updates a mounted standard status label without rewriting the status', () => {
    const status = buildStatus();
    const store = makeStore();
    const { container } = renderStatus(status, store);
    const wrapper = () => container.querySelector('.status__wrapper');

    expect(wrapper().getAttribute('aria-label')).toContain(THUMB);
    expect(wrapper().getAttribute('aria-label')).toContain('Alice');

    apply(store, [rule({ kind: 'unicode', native: THUMB }, '[thumb]')]);

    expect(wrapper().getAttribute('aria-label')).toContain('Alice [thumb]');
    expect(wrapper().getAttribute('aria-label')).toContain('Hello [thumb]');
    expect(wrapper().getAttribute('aria-label')).not.toContain(THUMB);
    expect(wrapper().getAttribute('aria-label')).toContain('alice');
    expect(status.get('contentHtml')).toContain('/emoji/thumb.svg');
    expect(status.get('search_index')).toContain(THUMB);
  });

  it('keeps a boost suffix on the acct while the visible booster name follows the mute', () => {
    const status = buildStatus({
      id: 'boost',
      account: account({ id: 'booster', acct: 'booster', display_name: `Booster ${THUMB}`, display_name_html: `Booster ${thumbImg}` }),
      reblog: {
        id: 'inner',
        account: account({ id: 'inner', acct: 'inner', display_name: 'Inner', display_name_html: 'Inner' }),
        content: 'Inner hello',
        contentHtml: '<p>Inner hello</p>',
        search_index: 'Inner hello',
        spoiler_text: '',
        spoilerHtml: '',
        hidden: false,
        reblog: null,
        quote: null,
        media_attachments: [],
        visibility: 'public',
        created_at: '2024-01-01T00:00:00.000Z',
        url: 'https://example.test/inner',
        in_reply_to_id: null,
        matched_filters: false,
        reblogs_count: 0,
        favourites_count: 0,
        emoji_reactions_count: 0,
      },
    });
    const store = makeStore();
    const { container } = renderStatus(status, store);

    expect(container.querySelector('.status__prepend img')).not.toBeNull();
    expect(container.querySelector('.status__wrapper').getAttribute('aria-label')).toContain('booster boosted');
    expect(container.querySelector('.status__wrapper').getAttribute('aria-label')).toContain('Inner');
    expect(container.querySelector('.status__wrapper').getAttribute('aria-label')).not.toContain(`Booster ${THUMB}`);

    apply(store, [rule({ kind: 'unicode', native: THUMB }, '[thumb]')]);

    expect(container.querySelector('.status__prepend').textContent).toContain('[thumb]');
    expect(container.querySelector('.status__prepend').innerHTML).not.toContain('/emoji/thumb.svg');
    expect(container.querySelector('.status__wrapper').getAttribute('aria-label')).toContain('booster boosted');
    expect(status.getIn(['account', 'display_name_html'])).toContain(THUMB);
  });

  it('updates a collapsed notification from the displayed html and leaves the source content', () => {
    const status = buildStatus({ content: `<p>Hello ${THUMB}</p>` });
    const store = makeStore();
    const { container } = renderStatus(status, store, { hidden: true });

    expect(container.querySelector('.status__wrapper').textContent).toContain(`<p>Hello ${THUMB}</p>`);

    apply(store, [rule({ kind: 'unicode', native: THUMB }, '[thumb]')]);

    expect(container.querySelector('.status__wrapper').textContent).toContain('Hello [thumb]');
    expect(container.querySelector('.status__wrapper').textContent).not.toContain(THUMB);
    expect(container.querySelector('.status__wrapper').innerHTML).not.toContain('/emoji/thumb.svg');
    expect(status.get('content')).toContain(THUMB);
  });

  it('updates standard and card labels when the poll record changes and the status does not', () => {
    const status = buildStatus({
      content: '',
      contentHtml: '',
      search_index: '\n\n\n\nYes :blob:\n\nNo',
      poll: 'p1',
      account: account({ display_name: 'Alice', display_name_html: 'Alice' }),
    });
    const store = makeStore();
    const standard = renderStatus(status, store);
    const card = renderStatus(status, store, { layoutMode: 'card-1' });
    const label = view => view.container.querySelector('.status__wrapper').getAttribute('aria-label');
    const choice = id => (
      `<img class="emojione custom-emoji" alt=":blob:" data-shortcode="blob" data-domain="" data-emoji-id="${id}" src="https://cdn.example/${id}.svg">`
    );
    const poll = html => ({
      id: 'p1',
      options: [
        { title: 'Yes :blob:', title_emojified: `Yes ${html}` },
        { title: 'No', title_emojified: 'No' },
      ],
    });

    apply(store, [rule({ kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' }, '[choice]')]);

    expect(label(standard)).toContain('Yes :blob:');
    expect(label(card)).toContain('Yes :blob:');
    expect(status.get('poll')).toBe('p1');

    act(() => {
      store.dispatch({ type: POLLS_IMPORT, polls: [poll(choice('11'))] });
    });

    expect(label(standard)).toContain('Yes [choice]');
    expect(label(card)).toContain('Yes [choice]');
    expect(label(standard)).toContain('No');
    expect(label(standard)).not.toContain(':blob:');

    act(() => {
      store.dispatch({ type: POLLS_IMPORT, polls: [poll(choice('12'))] });
    });

    expect(label(standard)).toContain('Yes :blob:');
    expect(label(card)).toContain('Yes :blob:');
    expect(label(standard)).not.toContain('[choice]');
    expect(status.get('search_index')).toContain('Yes :blob:');
  });

  it('speaks the current poll title on standard and card when search_index is stale', () => {
    const status = buildStatus({
      content: '<p>Hello</p>',
      contentHtml: '<p>Hello</p>',
      search_index: '\n\nHello\n\nYes :blob:\n\nNo',
      poll: 'p1',
      account: account({ display_name: 'Alice', display_name_html: 'Alice' }),
    });
    const store = makeStore();
    const standard = renderStatus(status, store);
    const card = renderStatus(status, store, { layoutMode: 'card-1' });
    const label = view => view.container.querySelector('.status__wrapper').getAttribute('aria-label');
    const choice = '<img class="emojione custom-emoji" alt=":blob:" data-shortcode="blob" data-domain="" data-emoji-id="11" src="https://cdn.example/11.svg">';

    apply(store, [rule({ kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' }, '[choice]')]);

    act(() => {
      store.dispatch({
        type: POLLS_IMPORT,
        polls: [{
          id: 'p1',
          options: [
            { title: 'Sure :blob:', title_emojified: `Sure ${choice}` },
            { title: 'Later', title_emojified: 'Later' },
          ],
        }],
      });
    });

    expect(label(standard)).toContain('Sure [choice]');
    expect(label(card)).toContain('Sure [choice]');
    expect(label(standard)).toContain('Later');
    expect(label(standard)).not.toContain('Yes');
    expect(status.get('search_index')).toContain('Yes :blob:');
  });
});
