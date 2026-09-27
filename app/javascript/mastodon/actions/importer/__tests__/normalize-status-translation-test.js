import { fromJS } from 'immutable';

import { normalizeStatus } from '../normalizer';

const buildStatus = (overrides = {}) => ({
  id: 's1',
  account: { id: 'a1', acct: 'alice' },
  content: '<p>Hello</p>',
  spoiler_text: 'cw',
  emojis: [],
  media_attachments: [
    { id: 'm1', type: 'image', description: 'cat', url: 'https://example.test/cat.jpg', remote_url: 'https://example.test/cat.jpg' },
  ],
  mentions: [],
  visibility: 'public',
  sensitive: false,
  language: 'en',
  url: 'https://example.test/1',
  uri: 'https://example.test/1',
  updated_at: '2020-01-01T00:00:00.000Z',
  quote: null,
  ...overrides,
});

describe('normalizeStatus translation retention', () => {
  const previous = fromJS({
    id: 's1',
    content: '<p>Hello</p>',
    spoiler_text: 'cw',
    updated_at: '2020-01-01T00:00:00.000Z',
    search_index: 'cw Hello',
    shortHtml: '<p>cw Hello</p>',
    contentHtml: '<p>Hello</p>',
    spoilerHtml: 'cw',
    hidden: true,
    visibility: 'public',
    translation: { contentHtml: '<p>こんにちは</p>', language: 'ja' },
    media_attachments: [
      { id: 'm1', description: 'cat', translation: { description: 'ねこ' } },
    ],
  });

  it('keeps the translation when a refresh does not change the status', () => {
    const next = normalizeStatus(buildStatus(), previous, '');

    expect(next.translation.get('contentHtml')).toBe('<p>こんにちは</p>');
    expect(next.media_attachments.getIn([0, 'translation', 'description'])).toBe('ねこ');
  });

  it('drops the text translation when the status content changes and keeps an unchanged media translation', () => {
    const next = normalizeStatus(buildStatus({
      content: '<p>Hello again</p>',
      updated_at: '2020-01-02T00:00:00.000Z',
    }), previous, '');

    expect(next.translation).toBeUndefined();
    expect(next.media_attachments[0].translation.get('description')).toBe('ねこ');
  });

  it('drops a media translation when that attachment description changes', () => {
    const next = normalizeStatus(buildStatus({
      content: '<p>Hello again</p>',
      updated_at: '2020-01-02T00:00:00.000Z',
      media_attachments: [
        { id: 'm1', type: 'image', description: 'dog', url: 'https://example.test/dog.jpg', remote_url: 'https://example.test/dog.jpg' },
      ],
    }), previous, '');

    expect(next.media_attachments[0].translation).toBeUndefined();
    expect(next.media_attachments[0].description).toBe('dog');
  });
});
