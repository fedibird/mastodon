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
    language: 'en',
    poll: 'p1',
    translation: { contentHtml: '<p>こんにちは</p>', language: 'ja' },
    translationMode: 'bilingual',
    media_attachments: [
      { id: 'm1', description: 'cat', translation: { description: 'ねこ' } },
      { id: 'm2', description: 'tree', translation: { description: '木' } },
    ],
  });

  const previousPoll = fromJS({
    id: 'p1',
    options: [{ title: 'Yes' }, { title: 'No' }],
  });

  const incomingPoll = {
    id: 'p1',
    options: [{ title: 'Yes' }, { title: 'No' }],
  };

  it('keeps the translation when a refresh does not change the status', () => {
    const next = normalizeStatus(buildStatus({
      poll: incomingPoll,
      media_attachments: [
        { id: 'm1', type: 'image', description: 'cat', url: 'https://example.test/cat.jpg', remote_url: 'https://example.test/cat.jpg' },
        { id: 'm2', type: 'image', description: 'tree', url: 'https://example.test/tree.jpg', remote_url: 'https://example.test/tree.jpg' },
      ],
    }), previous, '', previousPoll);

    expect(next.translation.get('contentHtml')).toBe('<p>こんにちは</p>');
    expect(next.translationMode).toBe('bilingual');
    expect(next.media_attachments.getIn([0, 'translation', 'description'])).toBe('ねこ');
  });

  it('keeps the translation and mode when an edit does not change translation sources', () => {
    const next = normalizeStatus(buildStatus({
      updated_at: '2020-01-02T00:00:00.000Z',
      poll: incomingPoll,
      media_attachments: [
        { id: 'm2', type: 'image', description: 'tree', url: 'https://example.test/tree.jpg', remote_url: 'https://example.test/tree.jpg' },
        { id: 'm1', type: 'image', description: 'cat', url: 'https://example.test/cat.jpg', remote_url: 'https://example.test/cat.jpg' },
      ],
    }), previous, '', previousPoll);

    expect(next.translation.get('contentHtml')).toBe('<p>こんにちは</p>');
    expect(next.translationMode).toBe('bilingual');
    expect(next.media_attachments[0].translation.get('description')).toBe('木');
    expect(next.media_attachments[1].translation.get('description')).toBe('ねこ');
  });

  it('drops the text translation when the status content changes and keeps an unchanged media translation', () => {
    const next = normalizeStatus(buildStatus({
      content: '<p>Hello again</p>',
      updated_at: '2020-01-02T00:00:00.000Z',
      poll: incomingPoll,
    }), previous, '', previousPoll);

    expect(next.translation).toBeUndefined();
    expect(next.translationMode).toBeUndefined();
    expect(next.media_attachments[0].translation.get('description')).toBe('ねこ');
  });

  it('drops a media translation when that attachment description changes', () => {
    const next = normalizeStatus(buildStatus({
      content: '<p>Hello again</p>',
      updated_at: '2020-01-02T00:00:00.000Z',
      poll: incomingPoll,
      media_attachments: [
        { id: 'm1', type: 'image', description: 'dog', url: 'https://example.test/dog.jpg', remote_url: 'https://example.test/dog.jpg' },
      ],
    }), previous, '', previousPoll);

    expect(next.media_attachments[0].translation).toBeUndefined();
    expect(next.media_attachments[0].description).toBe('dog');
  });

  it('drops the status translation when only a media description changes so it can be fetched again', () => {
    const next = normalizeStatus(buildStatus({
      updated_at: '2020-01-02T00:00:00.000Z',
      poll: incomingPoll,
      media_attachments: [
        { id: 'm1', type: 'image', description: 'cat', url: 'https://example.test/cat.jpg', remote_url: 'https://example.test/cat.jpg' },
        { id: 'm2', type: 'image', description: 'forest', url: 'https://example.test/tree.jpg', remote_url: 'https://example.test/tree.jpg' },
      ],
    }), previous, '', previousPoll);

    expect(next.translation).toBeUndefined();
    expect(next.translationMode).toBeUndefined();
    expect(next.media_attachments[0].translation.get('description')).toBe('ねこ');
    expect(next.media_attachments[1].translation).toBeUndefined();
    expect(next.media_attachments[1].description).toBe('forest');
  });

  it('drops the status translation when a media attachment is added', () => {
    const next = normalizeStatus(buildStatus({
      updated_at: '2020-01-02T00:00:00.000Z',
      poll: incomingPoll,
      media_attachments: [
        { id: 'm1', type: 'image', description: 'cat', url: 'https://example.test/cat.jpg', remote_url: 'https://example.test/cat.jpg' },
        { id: 'm2', type: 'image', description: 'tree', url: 'https://example.test/tree.jpg', remote_url: 'https://example.test/tree.jpg' },
        { id: 'm3', type: 'image', description: 'bird', url: 'https://example.test/bird.jpg', remote_url: 'https://example.test/bird.jpg' },
      ],
    }), previous, '', previousPoll);

    expect(next.translation).toBeUndefined();
    expect(next.translationMode).toBeUndefined();
    expect(next.media_attachments[2].translation).toBeUndefined();
    expect(next.media_attachments[2].description).toBe('bird');
  });

  it('drops the status translation when the source language changes', () => {
    const next = normalizeStatus(buildStatus({
      language: 'de',
      updated_at: '2020-01-02T00:00:00.000Z',
      poll: incomingPoll,
      media_attachments: [
        { id: 'm1', type: 'image', description: 'cat', url: 'https://example.test/cat.jpg', remote_url: 'https://example.test/cat.jpg' },
        { id: 'm2', type: 'image', description: 'tree', url: 'https://example.test/tree.jpg', remote_url: 'https://example.test/tree.jpg' },
      ],
    }), previous, '', previousPoll);

    expect(next.translation).toBeUndefined();
    expect(next.translationMode).toBeUndefined();
    expect(next.language).toBe('de');
    expect(next.media_attachments[0].translation.get('description')).toBe('ねこ');
  });

  it('drops the status translation when poll option titles change', () => {
    const next = normalizeStatus(buildStatus({
      updated_at: '2020-01-02T00:00:00.000Z',
      poll: {
        id: 'p1',
        options: [{ title: 'Yeah' }, { title: 'No' }],
      },
      media_attachments: [
        { id: 'm1', type: 'image', description: 'cat', url: 'https://example.test/cat.jpg', remote_url: 'https://example.test/cat.jpg' },
        { id: 'm2', type: 'image', description: 'tree', url: 'https://example.test/tree.jpg', remote_url: 'https://example.test/tree.jpg' },
      ],
    }), previous, '', previousPoll);

    expect(next.translation).toBeUndefined();
    expect(next.translationMode).toBeUndefined();
    expect(next.poll).toBe('p1');
  });

  it('drops the status translation when a refresh changes poll options without a new edit time', () => {
    const next = normalizeStatus(buildStatus({
      poll: {
        id: 'p1',
        options: [{ title: 'Yeah' }, { title: 'No' }],
      },
      media_attachments: [
        { id: 'm1', type: 'image', description: 'cat', url: 'https://example.test/cat.jpg', remote_url: 'https://example.test/cat.jpg' },
        { id: 'm2', type: 'image', description: 'tree', url: 'https://example.test/tree.jpg', remote_url: 'https://example.test/tree.jpg' },
      ],
    }), previous, '', previousPoll);

    expect(next.translation).toBeUndefined();
    expect(next.translationMode).toBeUndefined();
    expect(next.media_attachments.getIn([0, 'translation', 'description'])).toBe('ねこ');
  });
});
