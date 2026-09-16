import { fromJS } from 'immutable';

import { legacyNotificationFilterFlags } from '../legacy_notification_filter';

jest.mock('../../api', () => ({
  __esModule: true,
  default: jest.fn(),
  getLinks: jest.fn(),
}));

jest.mock('mastodon/initial_state', () => ({
  me: 'me',
  usePendingItems: false,
  enableReaction: true,
  enableStatusReference: true,
  enableLimitedTimeline: false,
  hideDirectFromTimeline: false,
  hidePersonalFromTimeline: false,
  maxFrequentlyUsedEmojis: 16,
}));

jest.mock('mastodon/features/emoji/emoji', () => ({
  buildCustomEmojis: () => [],
  categoriesFromEmojis: () => [],
}));

const mention = phrase => ({
  type: 'mention',
  status: {
    spoiler_text: '',
    content: `<p>${phrase}</p>`,
    poll: null,
    media_attachments: [],
  },
});

const buildState = filters => fromJS({
  filters: {},
  notification_filters: filters,
});

describe('legacyNotificationFilterFlags', () => {
  it('drops notifications matching an irreversible hide filter', () => {
    const state = buildState([{
      id: '1',
      phrase: 'spam',
      context: ['notifications'],
      irreversible: true,
      whole_word: false,
      expires_at: null,
    }]);

    expect(legacyNotificationFilterFlags(state, mention('buy spam now'))).toEqual({
      drop: true,
      filtered: false,
    });
  });

  it('keeps reversible warn matches in the column but marks them filtered', () => {
    const state = buildState([{
      id: '1',
      phrase: 'spoiler',
      context: ['notifications'],
      irreversible: false,
      whole_word: false,
      expires_at: null,
    }]);

    expect(legacyNotificationFilterFlags(state, mention('spoiler inside'))).toEqual({
      drop: false,
      filtered: true,
    });
  });

  it('does not filter unmatched notification status text', () => {
    const state = buildState([{
      id: '1',
      phrase: 'spam',
      context: ['notifications'],
      irreversible: true,
      whole_word: false,
      expires_at: null,
    }]);

    expect(legacyNotificationFilterFlags(state, mention('hello world'))).toEqual({
      drop: false,
      filtered: false,
    });
  });

  it('does not use v2 FilterResult entities for notification matching', () => {
    const state = fromJS({
      filters: {
        1: {
          id: '1',
          title: 'spam',
          context: ['notifications'],
          filter_action: 'hide',
          expires_at: null,
        },
      },
      notification_filters: [],
    });

    expect(legacyNotificationFilterFlags(state, mention('buy spam now'))).toEqual({
      drop: false,
      filtered: false,
    });
  });
});
