import { fromJS } from 'immutable';

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

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  FormattedMessage: () => null,
  injectIntl: Component => Component,
}));

jest.mock('react-hotkeys', () => ({
  HotKeys: ({ children }) => children,
}));

jest.mock('../account_action_bar', () => () => null);
jest.mock('../status_content', () => () => null);
jest.mock('../status_action_bar', () => () => null);
jest.mock('../avatar', () => () => null);
jest.mock('../avatar_overlay', () => () => null);
jest.mock('../avatar_composite', () => () => null);
jest.mock('../display_name', () => () => null);
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

import { normalizePoll, normalizeStatus } from 'mastodon/actions/importer/normalizer';
import { buildReplaceInTextIndex, emojiMuteTextParseCount, resetEmojiMuteTextForTests } from 'mastodon/features/emoji/emoji_mute_text';
import { defaultMediaVisibility as statusMediaVisibility, indexedText, resetScreenReaderIndexForTests, textForScreenReader } from '../status';
import { defaultMediaVisibility as defaultMediaTileVisibility } from 'mastodon/utils/media_display';

const intl = {
  formatDate: () => 'Jan 1, 12:00 PM',
};

const translation = {
  contentHtml: '<p>こんにちは</p>',
  spoiler_text: '警告',
  spoilerHtml: '警告',
  language: 'ja',
  detected_source_language: 'en',
  provider: 'DeepL',
  requested_source_language: 'en',
  requested_target_language: 'ja',
};

const buildStatus = (overrides = {}) => fromJS({
  created_at: '2024-01-01T00:00:00.000Z',
  spoiler_text: '',
  search_index: 'Hello',
  hidden: false,
  account: {
    display_name: 'Alice',
    acct: 'alice@example.com',
  },
  ...overrides,
});

const label = (status, rebloggedByText) => textForScreenReader(intl, status, rebloggedByText);

describe('textForScreenReader translation mode', () => {
  it('reads the original body when the status has no translation', () => {
    expect(label(buildStatus())).toBe('Alice, Hello, Jan 1, 12:00 PM, alice@example.com');
  });

  it('reads the original body when a translation remains attached in original mode', () => {
    const status = buildStatus({
      translationMode: 'original',
      translation,
    });

    expect(label(status)).toBe('Alice, Hello, Jan 1, 12:00 PM, alice@example.com');
    expect(status.getIn(['translation', 'contentHtml'])).toContain('こんにちは');
  });

  it('reads the translated body in translated mode', () => {
    expect(label(buildStatus({
      translationMode: 'translated',
      translation,
    }))).toBe('Alice, こんにちは, Jan 1, 12:00 PM, alice@example.com');
  });

  it('reads the original body and then the translated body in bilingual mode', () => {
    expect(label(buildStatus({
      translationMode: 'bilingual',
      translation,
    }))).toBe('Alice, Hello → こんにちは, Jan 1, 12:00 PM, alice@example.com');
  });

  it('reads only the original content warning while a hidden CW is collapsed in original mode', () => {
    expect(label(buildStatus({
      hidden: true,
      spoiler_text: 'secret',
      search_index: 'secret\n\nHello',
      translationMode: 'original',
      translation,
    }))).toBe('Alice, secret, Jan 1, 12:00 PM, alice@example.com');
  });

  it('reads only the translated content warning while a hidden CW is collapsed in translated mode', () => {
    expect(label(buildStatus({
      hidden: true,
      spoiler_text: 'secret',
      search_index: 'secret\n\nHello',
      translationMode: 'translated',
      translation,
    }))).toBe('Alice, 警告, Jan 1, 12:00 PM, alice@example.com');
  });

  it('reads the original content warning and then the translated one while a hidden CW is collapsed in bilingual mode', () => {
    expect(label(buildStatus({
      hidden: true,
      spoiler_text: 'secret',
      search_index: 'secret\n\nHello',
      translationMode: 'bilingual',
      translation,
    }))).toBe('Alice, secret → 警告, Jan 1, 12:00 PM, alice@example.com');
  });

  it('returns to the original text when the mode changes back to original without dropping the translation', () => {
    const translated = buildStatus({
      translationMode: 'translated',
      translation,
    });
    const original = translated.set('translationMode', 'original');

    expect(label(translated)).toBe('Alice, こんにちは, Jan 1, 12:00 PM, alice@example.com');
    expect(label(original)).toBe('Alice, Hello, Jan 1, 12:00 PM, alice@example.com');
    expect(original.get('translation')).toBe(translated.get('translation'));
    expect(original.getIn(['translation', 'contentHtml'])).toContain('こんにちは');
  });

  it('reads the original text after a viewer target change keeps the translation and sets original mode', () => {
    const status = buildStatus({
      translationMode: 'original',
      translationPending: false,
      translation,
    }).delete('translationRequestId');

    expect(status.get('translationMode')).toBe('original');
    expect(status.get('translationPending')).toBe(false);
    expect(status.get('translationRequestId')).toBeUndefined();
    expect(status.getIn(['translation', 'requested_target_language'])).toBe('ja');
    expect(label(status)).toBe('Alice, Hello, Jan 1, 12:00 PM, alice@example.com');
  });

  it('falls back to the original text when the translated content or content warning is empty', () => {
    const emptyBody = buildStatus({
      translationMode: 'translated',
      translation: {
        ...translation,
        contentHtml: '<p> </p>',
        spoiler_text: '',
      },
    });
    const emptyWarning = buildStatus({
      hidden: true,
      spoiler_text: 'secret',
      search_index: 'secret\n\nHello',
      translationMode: 'translated',
      translation: {
        ...translation,
        spoiler_text: '   ',
      },
    });
    const emptyBilingual = buildStatus({
      translationMode: 'bilingual',
      translation: {
        ...translation,
        contentHtml: '',
      },
    });

    expect(label(emptyBody)).toBe('Alice, Hello, Jan 1, 12:00 PM, alice@example.com');
    expect(label(emptyWarning)).toBe('Alice, secret, Jan 1, 12:00 PM, alice@example.com');
    expect(label(emptyBilingual)).toBe('Alice, Hello, Jan 1, 12:00 PM, alice@example.com');
  });

  it('reads the body instead of the content warning after a CW status is expanded', () => {
    const expanded = {
      hidden: false,
      spoiler_text: 'secret',
      search_index: 'secret\n\nHello',
      translation,
    };

    expect(label(buildStatus({ ...expanded, translationMode: 'original' }))).toBe('Alice, \n\nHello, Jan 1, 12:00 PM, alice@example.com');
    expect(label(buildStatus({ ...expanded, translationMode: 'translated' }))).toBe('Alice, こんにちは, Jan 1, 12:00 PM, alice@example.com');
    expect(label(buildStatus({ ...expanded, translationMode: 'bilingual' }))).toBe('Alice, \n\nHello → こんにちは, Jan 1, 12:00 PM, alice@example.com');
  });

  it('reads the displayed original body of a CW-only status while original mode keeps the translation', () => {
    expect(label(buildStatus({
      spoiler_text: '',
      search_index: 'secret warning',
      hidden: false,
      translationMode: 'original',
      translation: {
        ...translation,
        contentHtml: '<p>秘密の警告</p>',
        spoiler_text: '',
      },
    }))).toBe('Alice, secret warning, Jan 1, 12:00 PM, alice@example.com');
  });

  it('keeps the author, date, account, and reblog context around the status text', () => {
    expect(label(buildStatus({
      translationMode: 'bilingual',
      translation,
    }), 'Bob boosted')).toBe('Alice, Hello → こんにちは, Jan 1, 12:00 PM, alice@example.com, Bob boosted');
  });
});

const THUMB = '👍';
const thumbImg = `<img draggable="false" class="emojione" alt="${THUMB}" src="/emoji/thumb.svg">`;
const localImg = (id, shortcode = 'blob') => (
  `<img draggable="false" class="emojione custom-emoji" alt=":${shortcode}:" title="${shortcode}" src="https://cdn.example/${id}.svg" data-shortcode="${shortcode}" data-domain="" data-original="https://cdn.example/${id}.svg" data-emoji-id="${id}">`
);
const remoteImg = (domain) => (
  `<img draggable="false" class="emojione custom-emoji" alt=":blob:" src="https://cdn.example/${domain}/blob.svg" data-shortcode="blob" data-domain="${domain}">`
);

const rule = (emoji, replacement = '[emoji]', effects = {}) => ({
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

const muteIndex = rules => buildReplaceInTextIndex(rules);

describe('textForScreenReader emoji mute', () => {
  const named = (extra = {}) => buildStatus({
    search_index: `Hello ${THUMB}`,
    contentHtml: `<p>Hello ${thumbImg}</p>`,
    account: {
      display_name: `Alice ${THUMB} :blob:`,
      display_name_html: `Alice ${thumbImg} ${localImg('10')}`,
      acct: 'alice@example.com',
    },
    ...extra,
  });

  it('keeps the stored plain text and speaks the presented html when a mute matches', () => {
    const status = named();
    const index = muteIndex([
      rule({ kind: 'unicode', native: THUMB }, '[thumb]'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[blob]'),
    ]);
    const spoken = label(status, false);

    expect(textForScreenReader(intl, status, false, index)).toBe('Alice [thumb] [blob], Hello [thumb], Jan 1, 12:00 PM, alice@example.com');
    expect(spoken).toBe(`Alice ${THUMB} :blob:, Hello ${THUMB}, Jan 1, 12:00 PM, alice@example.com`);
    expect(status.get('search_index')).toBe(`Hello ${THUMB}`);
    expect(status.get('contentHtml')).toContain('/emoji/thumb.svg');
    expect(status.getIn(['account', 'display_name'])).toContain(THUMB);
  });

  it('keeps poll choices when a body emoji is muted and does not guess their shortcode', () => {
    const status = buildStatus({
      content: `<p>Hello ${THUMB} :blob:</p>`,
      contentHtml: `<p>Hello ${thumbImg} ${localImg('10')}</p>`,
      search_index: `\n\nHello ${THUMB} :blob:\n\nYes :blob:\n\nNo`,
      poll: {
        options: [
          { title: 'Yes :blob:', title_emojified: `Yes ${localImg('11')}` },
          { title: 'No', title_emojified: 'No' },
        ],
      },
    });
    const index = muteIndex([
      rule({ kind: 'unicode', native: THUMB }, '[thumb]'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[blob]'),
    ]);
    const spoken = textForScreenReader(intl, status, false, index);

    expect(spoken).toContain('Hello [thumb] [blob]');
    expect(spoken).toContain('Yes :blob:');
    expect(spoken).not.toContain('Yes [blob]');
    expect(spoken).toContain('\n\nNo');
    expect(spoken).not.toContain(THUMB);
    expect(status.get('search_index')).toContain('Yes :blob:');
    expect(textForScreenReader(intl, status, false, muteIndex([]))).toBe(label(status));
  });

  it('projects a poll choice from its own emoji html without dropping the other choice', () => {
    const choice = `Pick ${THUMB}`;
    const status = buildStatus({
      content: '<p>Hello</p>',
      contentHtml: '<p>Hello</p>',
      search_index: `\n\nHello\n\n${choice}\n\nNo`,
      translationMode: 'bilingual',
      translation,
      poll: {
        options: [
          { title: choice, title_emojified: `Pick ${thumbImg}` },
          { title: 'No', title_emojified: 'No' },
        ],
      },
    });
    const hidden = status.set('hidden', true).set('translationMode', 'original').set('spoiler_text', 'secret').set('spoilerHtml', 'secret').set('search_index', `secret\n\nHello\n\n${choice}`);
    const index = muteIndex([rule({ kind: 'unicode', native: THUMB }, '[thumb]')]);
    const hiddenLabel = textForScreenReader(intl, hidden, false, index);

    expect(textForScreenReader(intl, status, false, index)).toContain('Hello');
    expect(textForScreenReader(intl, status, false, index)).toContain('Pick [thumb]');
    expect(textForScreenReader(intl, status, false, index)).toContain('No');
    expect(textForScreenReader(intl, status, false, index)).toContain('こんにちは');
    expect(hiddenLabel).toBe('Alice, secret, Jan 1, 12:00 PM, alice@example.com');
    expect(hiddenLabel).not.toContain('Pick');
    expect(hidden.get('search_index')).toContain(choice);
  });

  it('does not treat another local id, a false effect, or a remote shortcode as this emoji', () => {
    const status = named({
      account: {
        display_name: 'Alice :blob:',
        display_name_html: `Alice ${remoteImg('remote.example')}`,
        acct: 'alice@remote.example',
      },
      search_index: 'Hello :blob:',
      contentHtml: `<p>Hello ${localImg('10')}</p>`,
    });

    expect(textForScreenReader(intl, status, false, muteIndex([
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' }, '[other]'),
    ]))).toBe(label(status));
    expect(textForScreenReader(intl, status, false, muteIndex([
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[blob]', { replace_in_text: false }),
    ]))).toBe(label(status));
    expect(textForScreenReader(intl, status, false, muteIndex([
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[blob]'),
      rule({ kind: 'custom', scope: 'remote', domain: 'other.example', shortcode: 'blob' }, '[remote]'),
    ]))).toContain('[blob]');
    expect(textForScreenReader(intl, status, false, muteIndex([
      rule({ kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'blob' }, '[remote]'),
    ]))).toContain('[remote]');
    expect(status.get('contentHtml')).toContain('data-emoji-id="10"');
  });

  it('reads a hidden content warning without the body, in original, translated, and bilingual modes', () => {
    const hidden = {
      hidden: true,
      spoiler_text: `secret ${THUMB}`,
      spoilerHtml: `secret ${thumbImg}`,
      search_index: `secret ${THUMB}\n\nHello body ${THUMB}`,
      contentHtml: `<p>Hello body ${thumbImg}</p>`,
      translationMode: 'original',
      translation: {
        ...translation,
        contentHtml: `<p>本文 ${thumbImg}</p>`,
        spoiler_text: '警告',
        spoilerHtml: '警告',
      },
    };
    const index = muteIndex([rule({ kind: 'unicode', native: THUMB }, '[thumb]')]);

    expect(textForScreenReader(intl, buildStatus(hidden), false, index)).toBe('Alice, secret [thumb], Jan 1, 12:00 PM, alice@example.com');
    expect(textForScreenReader(intl, buildStatus(hidden), false, index)).not.toContain('Hello body');
    expect(textForScreenReader(intl, buildStatus({ ...hidden, translationMode: 'translated' }), false, index)).toBe('Alice, 警告, Jan 1, 12:00 PM, alice@example.com');
    expect(textForScreenReader(intl, buildStatus({ ...hidden, translationMode: 'bilingual' }), false, index)).toBe('Alice, secret [thumb] → 警告, Jan 1, 12:00 PM, alice@example.com');
    expect(buildStatus(hidden).get('search_index')).toContain('Hello body');
  });

  it('reads the translated and bilingual bodies from their html', () => {
    const translatedHtml = `<p>こんにちは ${thumbImg}</p>`;
    const status = buildStatus({
      search_index: 'Hello',
      contentHtml: '<p>Hello</p>',
      translationMode: 'translated',
      translation: { ...translation, contentHtml: translatedHtml },
    });
    const index = muteIndex([rule({ kind: 'unicode', native: THUMB }, '[thumb]')]);

    expect(textForScreenReader(intl, status, false, index)).toBe('Alice, こんにちは [thumb], Jan 1, 12:00 PM, alice@example.com');
    expect(textForScreenReader(intl, status.set('translationMode', 'bilingual'), false, index)).toBe('Alice, Hello → こんにちは [thumb], Jan 1, 12:00 PM, alice@example.com');
    expect(status.getIn(['translation', 'contentHtml'])).toBe(translatedHtml);
  });

  it('replaces unicode in an external byline and does not read the owner emoji id', () => {
    const readerIntl = {
      formatDate: () => 'Jan 1, 12:00 PM',
      formatMessage: ({ defaultMessage }, values) => (defaultMessage || '').replace(/\{(\w+)\}/g, (_, key) => (values && values[key] !== undefined && values[key] !== null ? String(values[key]) : '')),
    };
    const status = buildStatus({
      search_index: 'Article body',
      contentHtml: '<p>Article body</p>',
      account: {
        display_name: 'Owner Face',
        display_name_html: `Owner ${localImg('10')}`,
        acct: 'owner@example.com',
      },
      visibility: 'public',
      fedibird_external: {
        protocol: 'rss',
        canonical_url: 'https://blog.example/post',
        presentation: {
          kind: 'external_source',
          name: 'Blog name',
          subtitle: 'RSS',
          source_url: 'https://blog.example/',
          byline_name: `Ada ${THUMB} :blob:`,
        },
      },
    });
    const spoken = textForScreenReader(readerIntl, status, false, muteIndex([
      rule({ kind: 'unicode', native: THUMB }, '[thumb]'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[blob]'),
    ]));

    expect(spoken).toContain('Ada [thumb] :blob:');
    expect(spoken).not.toContain(THUMB);
    expect(spoken).not.toContain('[blob]');
    expect(spoken).not.toContain('Owner Face');
    expect(spoken).toContain('Article body');
  });

  it('reads a normalized poll by id and ignores quote-inline text', () => {
    const normalized = normalizeStatus({
      id: 's1',
      account: { id: 'a1', acct: 'alice', username: 'alice', display_name: 'Alice' },
      content: '<p>Hello :blob:</p><span class="quote-inline">secret :blob:</span><span class="reference-link-inline">ref :blob:</span>',
      spoiler_text: '',
      emojis: [{ id: '10', shortcode: 'blob', url: 'https://cdn.example/10.svg', static_url: 'https://cdn.example/10.png' }],
      poll: {
        id: 'p1',
        options: [{ title: 'Yes :blob:' }, { title: 'No' }],
        emojis: [{ id: '11', shortcode: 'blob', url: 'https://cdn.example/11.svg', static_url: 'https://cdn.example/11.png' }],
        expired: false,
        multiple: false,
        votes_count: 0,
        voters_count: null,
      },
      quote: { id: 'q1' },
      media_attachments: [],
      mentions: [],
      tags: [],
      visibility: 'public',
      sensitive: false,
      language: 'en',
      created_at: '2024-01-01T00:00:00.000Z',
    }, null, '');
    const storedPoll = fromJS(normalizePoll({
      id: 'p1',
      options: [{ title: 'Yes :blob:' }, { title: 'No' }],
      emojis: [{ id: '11', shortcode: 'blob', url: 'https://cdn.example/11.svg', static_url: 'https://cdn.example/11.png' }],
      expired: false,
      multiple: false,
      votes_count: 0,
      voters_count: null,
    }));
    const status = buildStatus({
      ...normalized,
      account: {
        id: 'a1',
        acct: 'alice',
        username: 'alice',
        display_name: 'Alice',
        display_name_html: 'Alice',
      },
    });
    const index = muteIndex([
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[body]'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' }, '[choice]'),
    ]);

    expect(status.get('poll')).toBe('p1');
    expect(status.get('search_index')).not.toContain('secret');
    expect(status.get('search_index')).not.toContain('ref');
    expect(indexedText(status.get('content'))).not.toContain('secret');
    expect(indexedText(status.get('content'))).toContain('Hello :blob:');

    const spoken = textForScreenReader(intl, status, false, index, storedPoll);

    expect(spoken).toContain('Hello [body]');
    expect(spoken).toContain('Yes [choice]');
    expect(spoken).toContain('No');
    expect(spoken).not.toContain('secret');
    expect(spoken).not.toContain(':blob:');
    expect(storedPoll.getIn(['options', 0, 'title'])).toBe('Yes :blob:');
    expect(storedPoll.get('id')).toBe('p1');
    expect(textForScreenReader(intl, status.set('poll', 'p1'), false, muteIndex([
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[body]', { replace_in_text: false }),
    ]), storedPoll)).toContain('Hello :blob:');
    expect(textForScreenReader(intl, status.set('poll', 'p1'), false, muteIndex([
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[body]', { replace_in_text: false }),
    ]), storedPoll)).toContain('Yes :blob:');
  });

  it('does not parse status html when no replace_in_text rule is active', () => {
    resetEmojiMuteTextForTests();
    resetScreenReaderIndexForTests();
    const status = buildStatus({
      content: '<p>Hello :blob:</p>',
      contentHtml: `<p>Hello ${localImg('10')}</p>`,
      search_index: 'Hello :blob:',
    });

    for (let count = 0; count < 1000; count += 1) {
      textForScreenReader(intl, status);
    }

    expect(emojiMuteTextParseCount()).toBe(0);

    const index = muteIndex([rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[blob]')]);
    resetEmojiMuteTextForTests();
    resetScreenReaderIndexForTests();

    for (let count = 0; count < 1000; count += 1) {
      textForScreenReader(intl, status, false, index);
    }

    expect(emojiMuteTextParseCount()).toBeLessThan(5);
    expect(textForScreenReader(intl, status, false, index)).toContain('[blob]');
  });
});

describe('status and tile visibility defaults', () => {
  it('keeps the existing status-level boolean helper separate from the media-tile policy helper', () => {
    expect(statusMediaVisibility(buildStatus({ sensitive: false }))).toBe(true);
    expect(statusMediaVisibility(buildStatus({ sensitive: true }))).toBe(false);
    expect(statusMediaVisibility(null)).toBeUndefined();
    expect(defaultMediaTileVisibility()).toBe('hide_sensitive');
  });
});
