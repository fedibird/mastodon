/* eslint-disable react/prop-types */

import { act, fireEvent, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import PropTypes from 'prop-types';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

import { EMOJI_MUTES_APPLY } from 'mastodon/actions/emoji_mutes';
import { emojiMuteTextParseCount, resetEmojiMuteTextForTests } from 'mastodon/features/emoji/emoji_mute_text';
import emojiMutes from 'mastodon/reducers/emoji_mutes';

jest.mock('mastodon/initial_state', () => ({
  displayMedia: 'default',
  enableReaction: false,
  compactReaction: false,
  show_reply_tree_button: false,
  enableStatusReference: false,
  disableRelativeTime: true,
  hideLinkPreview: false,
  hidePhotoPreview: true,
  hideVideoPreview: true,
  hideRebloggedBy: false,
  cropCardImages: true,
  cardCollapseLongText: false,
  me: '1',
  autoPlayEmoji: false,
  disableReactions: false,
  translationBarVisibility: 'always',
  translationPreferredMode: 'translated',
  languages: [['en', 'English', 'English'], ['ja', 'Japanese', '日本語']],
}));

jest.mock('react-intl', () => {
  const intl = {
    locale: 'en',
    formatMessage: ({ defaultMessage }, values) => {
      const ReactIntl = require('react');
      let message = defaultMessage || '';

      if (values) {
        Object.keys(values).forEach(key => {
          const value = values[key];

          if (value === undefined || value === null || ReactIntl.isValidElement(value)) {
            message = message.replace(`{${key}}`, '');
          } else {
            message = message.replace(`{${key}}`, String(value));
          }
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
    FormattedDate: () => 'Jan 1',
  };
});

jest.mock('react-hotkeys', () => ({
  HotKeys: ({ children }) => children,
}));

jest.mock('../avatar', () => () => <span data-testid='avatar' />);
jest.mock('../display_name', () => () => <span>name</span>);
jest.mock('../icon', () => () => null);
jest.mock('mastodon/components/icon', () => () => null);
jest.mock('../icon_button', () => ({ title, onClick }) => <button type='button' aria-label={title} onClick={onClick} />);
jest.mock('../status_action_bar', () => () => null);
jest.mock('../account_action_bar', () => () => null);
jest.mock('mastodon/components/emoji_reactions_bar', () => () => null);
jest.mock('mastodon/components/picture_in_picture_placeholder', () => () => null);
jest.mock('mastodon/components/thumbhash', () => () => null);
jest.mock('../../features/ui/components/bundle', () => () => null);
jest.mock('../../features/status/components/card', () => () => <div data-testid='link-preview' />);
jest.mock('mastodon/containers/poll_container', () => () => null);
jest.mock('../permalink', () => ({ children }) => <span>{children}</span>);
jest.mock('mastodon/components/media_gallery', () => () => null);
jest.mock('mastodon/features/video', () => () => null);
jest.mock('mastodon/features/audio', () => () => null);
jest.mock('mastodon/components/attachment_list', () => () => null);

import Status from '../status';
import StatusItem from '../status_item';
import QuoteIndicator from '../../features/compose/components/quote_indicator';
import ReplyIndicator from '../../features/compose/components/reply_indicator';

const THUMB = '👍';
const OK = '👌';

const unicodeImg = (native, src) => (
  `<img draggable="false" class="emojione" alt="${native}" title="${native}" src="${src}">`
);

const localImg = (id) => (
  `<img draggable="false" class="emojione custom-emoji" alt=":blob:" title="blob" src="https://cdn.example/${id}.svg" data-shortcode="blob" data-domain="" data-original="https://cdn.example/${id}.svg" data-static="https://cdn.example/${id}.png" data-emoji-id="${id}">`
);

const rule = (emoji, replacement = '［絵文字］', effects = {}) => ({
  id: 'm1',
  revision: '2',
  emoji,
  replacement,
  effects: {
    replace_in_text: true,
    reject_reactions_to_own_posts: true,
    hide_reactions: true,
    hide_in_picker: true,
    ...effects,
  },
});

const makeStore = (relationships = {}) => createStore((state = fromJS({
  emojiMutes: { revision: null, rules: [] },
  relationships,
  server: { translationLanguages: { items: { en: ['ja'] } } },
}), action) => state.set('emojiMutes', emojiMutes(state.get('emojiMutes'), action)));

const apply = (store, mutes, revision = '2') => {
  act(() => {
    store.dispatch({ type: EMOJI_MUTES_APPLY, revision, mutes });
  });
};

class RouterStub extends React.Component {

  static propTypes = {
    children: PropTypes.node,
    router: PropTypes.object,
  };

  static childContextTypes = {
    router: PropTypes.object.isRequired,
  };

  getChildContext() {
    return { router: this.props.router };
  }

  render() {
    return this.props.children;
  }

}

const account = {
  id: 'a1',
  acct: 'alice',
  username: 'alice',
  display_name: 'Alice',
  display_name_html: 'Alice',
  url: 'https://example.test/alice',
  avatar: '',
  group: false,
};

const quoteAccount = {
  ...account,
  id: 'q-account',
  acct: 'quoter',
  username: 'quoter',
  display_name: 'Quoter',
  url: 'https://example.test/quoter',
};

const statusBase = (extra) => ({
  id: 's1',
  account,
  content: 'outer',
  contentHtml: '<p>outer</p>',
  spoilerHtml: '',
  spoiler_text: '',
  search_index: 'outer',
  language: 'en',
  visibility: 'public',
  hidden: false,
  reblog: null,
  media_attachments: [],
  created_at: '2024-01-01T00:00:00.000Z',
  url: 'https://example.test/s1',
  in_reply_to_id: null,
  in_reply_to_account_id: null,
  matched_filters: false,
  reblogs_count: 0,
  favourites_count: 0,
  emoji_reactions_count: 0,
  status_referred_by_count: 0,
  mentions: [],
  tags: [],
  emojis: [],
  ...extra,
});

describe('preview replace_in_text', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
  });

  it('replaces short html on a mounted mini status without rewriting it', () => {
    const shortHtml = `<p>Hello ${unicodeImg(THUMB, '/emoji/thumb.svg')} ${localImg('10')} ${localImg('11')}</p>`;
    const status = fromJS(statusBase({ shortHtml, language: 'ja' }));
    const store = makeStore();
    const { container } = render(
      <Provider store={store}>
        <StatusItem status={status} onUnselectReference={jest.fn()} />
      </Provider>,
    );
    const text = () => container.querySelector('.mini-status__content__text');

    expect(text().getAttribute('lang')).toBe('ja');
    expect(text().querySelector('[data-emoji-id="10"]')).not.toBeNull();

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[thumb]'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]'),
    ]);

    expect(text().textContent).toContain('[thumb]');
    expect(text().textContent).toContain('[local]');
    expect(text().querySelector('[data-emoji-id="11"]')).not.toBeNull();
    expect(text().querySelector('[data-emoji-id="10"]')).toBeNull();
    expect(text().querySelector('img[src*="thumb"]')).toBeNull();
    expect(text().innerHTML).not.toContain('/emoji/thumb.svg');
    expect(status.get('shortHtml')).toBe(shortHtml);

    apply(store, [], '3');

    expect(text().querySelector('[data-emoji-id="10"]')).not.toBeNull();
    expect(text().textContent).not.toContain('[local]');
  });

  it('replaces quote and reply indicators without changing the compose source', () => {
    const contentHtml = `<p>Quoted ${localImg('10')} ${unicodeImg(OK, '/emoji/ok.svg')}</p>`;
    const composeText = 'raw :blob: input';
    const status = fromJS(statusBase({
      id: 'q1',
      contentHtml,
      media_attachments: [],
    }));
    const store = makeStore();
    const { container } = render(
      <Provider store={store}>
        <RouterStub router={{ history: { push: jest.fn() } }}>
          <textarea readOnly value={composeText} />
          <QuoteIndicator status={status} onCancel={jest.fn()} />
          <ReplyIndicator status={status} onCancel={jest.fn()} />
        </RouterStub>
      </Provider>,
    );

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[blob]'),
    ]);

    const quote = container.querySelector('.quote-indicator__content');
    const reply = container.querySelector('.reply-indicator__content');

    expect(container.querySelector('textarea').value).toBe(composeText);
    expect(quote.getAttribute('dir')).toBe('auto');
    expect(quote.textContent).toContain('[blob]');
    expect(quote.querySelector('img[src*="ok"]')).not.toBeNull();
    expect(quote.querySelector('[data-emoji-id="10"]')).toBeNull();
    expect(quote.innerHTML).not.toContain('cdn.example/10');
    expect(reply.className).toContain('translate');
    expect(reply.textContent).toContain('[blob]');
    expect(reply.querySelector('[data-emoji-id]')).toBeNull();
    expect(status.get('contentHtml')).toBe(contentHtml);

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[blob]', { replace_in_text: false }),
    ], '4');

    expect(quote.querySelector('[data-emoji-id="10"]')).not.toBeNull();
    expect(container.querySelector('textarea').value).toBe(composeText);
  });

  it('projects a timeline card quote, keeps concealed quotes hidden, and leaves the link preview', () => {
    const contentHtml = `<p>Hello ${unicodeImg(THUMB, '/emoji/thumb.svg')} ${unicodeImg(OK, '/emoji/ok.svg')}</p>`;
    const history = { push: jest.fn() };
    const quote = {
      ...statusBase({
        id: 'q1',
        account: quoteAccount,
        contentHtml,
        search_index: 'Hello',
        visibility: 'public',
      }),
    };
    const parent = fromJS(statusBase({
      search_index: `outer ${THUMB}`,
      contentHtml: `<p>outer ${unicodeImg(THUMB, '/emoji/thumb.svg')}</p>`,
      quote,
      quote_id: 'q1',
      card: { url: 'https://example.test/article', type: 'link' },
    }));
    const store = makeStore();
    const { container } = render(
      <Provider store={store}>
        <RouterStub router={{ history }}>
          <Status
            status={parent}
            layoutMode='card-1'
            contextType='home'
            pictureInPicture={fromJS({ inUse: false, available: false })}
            addEmojiReaction={jest.fn()}
            removeEmojiReaction={jest.fn()}
            onAddToList={jest.fn()}
            onToggleCollapsed={jest.fn()}
          />
        </RouterStub>
      </Provider>,
    );
    const quoteText = () => container.querySelector('.timeline-card__quote-text');

    expect(container.querySelector('[data-testid="link-preview"]')).toBeNull();
    expect(quoteText().textContent).toContain('Hello');
    expect(quoteText().textContent).not.toContain(THUMB);
    expect(quoteText().textContent).not.toContain(OK);
    expect(container.querySelector('.status__wrapper').getAttribute('aria-label')).toContain(THUMB);
    expect(parent.get('contentHtml')).toContain('/emoji/thumb.svg');
    expect(parent.getIn(['quote', 'contentHtml'])).toBe(contentHtml);

    const parsed = emojiMuteTextParseCount();

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[thumb]'),
    ]);

    expect(quoteText().textContent).toContain('Hello');
    expect(quoteText().textContent).toContain('[thumb]');
    expect(quoteText().textContent).toContain(OK);
    expect(quoteText().textContent).not.toContain('/emoji/thumb.svg');
    expect(quoteText().querySelector('img')).toBeNull();
    expect(container.querySelector('.status__wrapper').getAttribute('aria-label')).toContain(THUMB);
    expect(parent.get('contentHtml')).toContain('/emoji/thumb.svg');
    expect(parent.getIn(['quote', 'contentHtml'])).toBe(contentHtml);
    expect(container.querySelector('.status__wrapper').getAttribute('data-id')).toBe('s1');

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '[thumb]'),
    ], '3');

    expect(emojiMuteTextParseCount()).toBe(parsed + 2);

    fireEvent.click(container.querySelector('.timeline-card__quote'));

    expect(history.push).toHaveBeenCalledWith('/statuses/q1');

    apply(store, [], '4');

    expect(quoteText().textContent).not.toContain('[thumb]');
    expect(quoteText().textContent).not.toContain(THUMB);
  });

  it('shows a CW replacement, hides unlisted and muted quotes, and still renders a link card', () => {
    const secretBody = `<p>secret ${localImg('10')}</p>`;
    const spoilerHtml = `<p>cw ${unicodeImg(THUMB, '/emoji/thumb.svg')}</p>`;
    const concealed = (extra) => fromJS(statusBase({
      quote: {
        ...statusBase({
          id: 'q1',
          account: quoteAccount,
          contentHtml: secretBody,
          spoiler_text: `cw ${THUMB}`,
          spoilerHtml,
          hidden: true,
          visibility: 'public',
        }),
        ...extra,
      },
      quote_id: 'q1',
    }));
    const store = makeStore();
    const cw = render(
      <Provider store={store}>
        <Status
          status={concealed()}
          layoutMode='card-1'
          contextType='home'
          pictureInPicture={fromJS({ inUse: false, available: false })}
          addEmojiReaction={jest.fn()}
          removeEmojiReaction={jest.fn()}
          onAddToList={jest.fn()}
          onToggleCollapsed={jest.fn()}
        />
      </Provider>,
    );

    expect(cw.container.querySelector('.timeline-card__quote-text').textContent).toBe(`cw ${THUMB}`);
    expect(cw.container.innerHTML).not.toContain('cdn.example/10');

    apply(store, [rule({ kind: 'unicode', native: THUMB }, '[thumb]')]);

    const cwText = cw.container.querySelector('.timeline-card__quote-text').textContent;

    expect(cwText).toContain('[thumb]');
    expect(cwText).not.toContain(THUMB);
    expect(cw.container.innerHTML).not.toContain('/emoji/thumb.svg');
    expect(cw.container.innerHTML).not.toContain('cdn.example/10');

    const unlisted = render(
      <Provider store={makeStore()}>
        <Status
          status={concealed({ visibility: 'unlisted', hidden: false, spoiler_text: '' })}
          layoutMode='card-1'
          contextType='public'
          pictureInPicture={fromJS({ inUse: false, available: false })}
          addEmojiReaction={jest.fn()}
          removeEmojiReaction={jest.fn()}
          onAddToList={jest.fn()}
          onToggleCollapsed={jest.fn()}
        />
      </Provider>,
    );

    expect(unlisted.container.querySelector('.timeline-card__quote').textContent).toBe('Unlisted quote');
    expect(unlisted.container.querySelector('.timeline-card__quote').innerHTML).not.toContain('cdn.example/10');

    const homeUnlisted = render(
      <Provider store={makeStore()}>
        <Status
          status={concealed({ visibility: 'unlisted', hidden: false, spoiler_text: '' })}
          layoutMode='card-1'
          contextType='home'
          pictureInPicture={fromJS({ inUse: false, available: false })}
          addEmojiReaction={jest.fn()}
          removeEmojiReaction={jest.fn()}
          onAddToList={jest.fn()}
          onToggleCollapsed={jest.fn()}
        />
      </Provider>,
    );

    expect(homeUnlisted.container.querySelector('.timeline-card__quote-text').textContent).toContain('secret');

    const muted = render(
      <Provider store={makeStore({ 'q-account': { muting: true } })}>
        <Status
          status={concealed({ hidden: false, spoiler_text: '' })}
          layoutMode='card-1'
          contextType='home'
          pictureInPicture={fromJS({ inUse: false, available: false })}
          addEmojiReaction={jest.fn()}
          removeEmojiReaction={jest.fn()}
          onAddToList={jest.fn()}
          onToggleCollapsed={jest.fn()}
        />
      </Provider>,
    );

    expect(muted.container.querySelector('.timeline-card__quote').textContent).toBe('Muted quote');
    expect(muted.container.querySelector('.timeline-card__quote').innerHTML).not.toContain('cdn.example/10');

    const linkCard = render(
      <Provider store={makeStore()}>
        <Status
          status={fromJS(statusBase({ card: { url: 'https://example.test/article', type: 'link' } }))}
          layoutMode='card-1'
          pictureInPicture={fromJS({ inUse: false, available: false })}
          addEmojiReaction={jest.fn()}
          removeEmojiReaction={jest.fn()}
          onAddToList={jest.fn()}
          onToggleCollapsed={jest.fn()}
        />
      </Provider>,
    );

    expect(linkCard.container.querySelector('[data-testid="link-preview"]')).not.toBeNull();
    expect(linkCard.container.querySelector('.timeline-card__quote')).toBeNull();
  });
});
