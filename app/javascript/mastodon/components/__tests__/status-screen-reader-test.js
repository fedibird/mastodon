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

import { textForScreenReader } from '../status';

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
