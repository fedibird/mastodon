/**
 * @jest-environment jsdom
 */

import { referenceFromInlineEmoji } from '../inline_emoji';

describe('inline custom emoji identity', () => {
  it('uses a pinned local id when one is present', () => {
    const image = document.createElement('img');
    image.dataset.shortcode = 'fedibird';
    image.dataset.emojiId = '58';
    expect(referenceFromInlineEmoji(image)).toEqual({
      kind: 'custom', scope: 'local', custom_emoji_id: '58', shortcode: 'fedibird',
    });
  });

  it('never mistakes a remote row for a local row', () => {
    const image = document.createElement('img');
    image.dataset.shortcode = 'fedibird';
    image.dataset.domain = 'remote.example';
    image.dataset.emojiId = '58';
    expect(referenceFromInlineEmoji(image)).toEqual({
      kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'fedibird',
    });
  });

  it('allows local shortcode resolution when HTML lacks a row id', () => {
    const image = document.createElement('img');
    image.dataset.shortcode = 'local';
    expect(referenceFromInlineEmoji(image)).toEqual({
      kind: 'custom', scope: 'local', shortcode: 'local',
    });
    expect(referenceFromInlineEmoji(document.createElement('img'))).toBeNull();
  });
});
