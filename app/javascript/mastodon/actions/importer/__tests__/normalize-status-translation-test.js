import { fromJS } from 'immutable';

import { importFetchedStatuses, POLLS_IMPORT, STATUSES_IMPORT } from '../index';
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

  it('keeps a pending translation request when a status-stat refresh does not change sources', () => {
    const pending = previous.set('translationPending', true).set('translationRequestId', 'req-a');
    const next = normalizeStatus(buildStatus({
      updated_at: '2020-01-02T00:00:00.000Z',
      poll: incomingPoll,
      media_attachments: [
        { id: 'm1', type: 'image', description: 'cat', url: 'https://example.test/cat.jpg', remote_url: 'https://example.test/cat.jpg' },
        { id: 'm2', type: 'image', description: 'tree', url: 'https://example.test/tree.jpg', remote_url: 'https://example.test/tree.jpg' },
      ],
    }), pending, '', previousPoll);

    expect(next.translation.get('contentHtml')).toBe('<p>こんにちは</p>');
    expect(next.translationMode).toBe('bilingual');
    expect(next.translationPending).toBe(true);
    expect(next.translationRequestId).toBe('req-a');
  });

  it('drops a pending translation request when the source changes', () => {
    const pending = previous.set('translationPending', true).set('translationRequestId', 'req-a');
    const next = normalizeStatus(buildStatus({
      content: '<p>Hello again</p>',
      updated_at: '2020-01-02T00:00:00.000Z',
      poll: incomingPoll,
      media_attachments: [
        { id: 'm1', type: 'image', description: 'cat', url: 'https://example.test/cat.jpg', remote_url: 'https://example.test/cat.jpg' },
        { id: 'm2', type: 'image', description: 'tree', url: 'https://example.test/tree.jpg', remote_url: 'https://example.test/tree.jpg' },
      ],
    }), pending, '', previousPoll);

    expect(next.translation).toBeUndefined();
    expect(next.translationMode).toBeUndefined();
    expect(next.translationPending).toBeUndefined();
    expect(next.translationRequestId).toBeUndefined();
  });
});

describe('normalizeStatus CW-only translation retention', () => {
  const stored = fromJS({
    id: 's1',
    content: 'secret warning',
    spoiler_text: '',
    updated_at: '2020-01-01T00:00:00.000Z',
    language: 'en',
    poll: null,
    translation: { contentHtml: '<p>秘密</p>', language: 'ja' },
    translationMode: 'translated',
    translationPending: true,
    translationRequestId: 'req-a',
    media_attachments: [],
  });

  it('keeps the translation when a status-stat refresh only bumps updated_at on a CW-only post', () => {
    const next = normalizeStatus(buildStatus({
      content: '',
      spoiler_text: 'secret warning',
      updated_at: '2020-01-02T00:00:00.000Z',
      language: 'en',
      poll: null,
      media_attachments: [],
    }), stored, '', null);

    expect(next.content).toBe('secret warning');
    expect(next.spoiler_text).toBe('');
    expect(next.translation.get('contentHtml')).toBe('<p>秘密</p>');
    expect(next.translationMode).toBe('translated');
    expect(next.translationPending).toBe(true);
    expect(next.translationRequestId).toBe('req-a');
  });

  it('drops the translation when the CW-only warning changes', () => {
    const next = normalizeStatus(buildStatus({
      content: '',
      spoiler_text: 'other warning',
      updated_at: '2020-01-02T00:00:00.000Z',
      language: 'en',
      poll: null,
      media_attachments: [],
    }), stored, '', null);

    expect(next.translation).toBeUndefined();
    expect(next.translationMode).toBeUndefined();
    expect(next.translationPending).toBeUndefined();
    expect(next.translationRequestId).toBeUndefined();
    expect(next.content).toBe('other warning');
    expect(next.spoiler_text).toBe('');
  });
});

describe('importFetchedStatuses translation request retention', () => {
  const account = {
    id: 'a1',
    username: 'alice',
    acct: 'alice',
    display_name: 'Alice',
    note: '',
    followed_message: '',
    emojis: [],
    fields: [],
    url: 'https://example.test/@alice',
    uri: 'https://example.test/users/alice',
  };

  const media = [
    { id: 'm1', type: 'image', description: 'cat', url: 'https://example.test/cat.jpg', remote_url: 'https://example.test/cat.jpg' },
    { id: 'm2', type: 'image', description: 'tree', url: 'https://example.test/tree.jpg', remote_url: 'https://example.test/tree.jpg' },
  ];

  const dispatchImport = (status, storedStatus, storedPoll) => {
    const actions = [];
    const getState = () => fromJS({
      statuses: { s1: storedStatus },
      polls: { p1: storedPoll },
      accounts: {},
    });
    const dispatch = (action) => {
      if (typeof action === 'function') {
        action(dispatch, getState);
      } else {
        actions.push(action);
      }
    };

    importFetchedStatuses([status])(dispatch, getState);

    return {
      status: actions.find(action => action.type === STATUSES_IMPORT).statuses[0],
      poll: actions.find(action => action.type === POLLS_IMPORT).polls[0],
    };
  };

  const storedStatus = fromJS({
    id: 's1',
    content: '<p>Hello</p>',
    spoiler_text: 'cw',
    updated_at: '2020-01-01T00:00:00.000Z',
    language: 'en',
    poll: 'p1',
    translation: { contentHtml: '<p>こんにちは</p>', language: 'ja' },
    translationMode: 'bilingual',
    translationPending: true,
    translationRequestId: 'req-a',
    media_attachments: [
      { id: 'm1', description: 'cat', translation: { description: 'ねこ' } },
      { id: 'm2', description: 'tree', translation: { description: '木' } },
    ],
  });

  const storedPoll = fromJS({
    id: 'p1',
    emojis: [],
    options: [{ title: 'Yes' }, { title: 'No' }],
    translationRequestId: 'req-a',
  });

  it('keeps the poll translation request when a status-stat refresh does not change sources', () => {
    const imported = dispatchImport(buildStatus({
      account,
      updated_at: '2020-01-02T00:00:00.000Z',
      poll: { id: 'p1', emojis: [], own_votes: [], options: [{ title: 'Yes' }, { title: 'No' }] },
      media_attachments: media,
    }), storedStatus, storedPoll);

    expect(imported.status.translationRequestId).toBe('req-a');
    expect(imported.status.translationPending).toBe(true);
    expect(imported.poll.translationRequestId).toBe('req-a');
  });

  it('drops the poll translation request when the status source changes', () => {
    const imported = dispatchImport(buildStatus({
      account,
      content: '<p>Hello again</p>',
      updated_at: '2020-01-02T00:00:00.000Z',
      poll: { id: 'p1', emojis: [], own_votes: [], options: [{ title: 'Yes' }, { title: 'No' }] },
      media_attachments: media,
    }), storedStatus, storedPoll);

    expect(imported.status.translation).toBeUndefined();
    expect(imported.status.translationRequestId).toBeUndefined();
    expect(imported.poll.translationRequestId).toBeUndefined();
  });
});

describe('personal boost wrapper translation source changes', () => {
  const account = {
    id: 'a1',
    username: 'alice',
    acct: 'alice',
    display_name: 'Alice',
    note: '',
    followed_message: '',
    emojis: [],
    fields: [],
    url: 'https://example.test/@alice',
    uri: 'https://example.test/users/alice',
  };

  const media = [
    { id: 'm1', type: 'image', description: 'a cat', url: 'https://example.test/cat.jpg', remote_url: 'https://example.test/cat.jpg' },
  ];

  const proper = (overrides = {}) => buildStatus({
    id: 'proper',
    account,
    content: '<p>Hello</p>',
    spoiler_text: '',
    language: 'en',
    visibility: 'private',
    poll: null,
    media_attachments: media,
    ...overrides,
  });

  const storedProper = fromJS({
    id: 'proper',
    account: 'a1',
    content: '<p>Hello</p>',
    spoiler_text: '',
    language: 'en',
    visibility: 'private',
    poll: null,
    media_attachments: [{ id: 'm1', description: 'a cat', type: 'image' }],
    favourites_count: 1,
  });

  const storedWrapper = fromJS({
    id: 'wrap',
    account: 'a1',
    reblog: 'proper',
    content: '',
    spoiler_text: '',
    language: null,
    visibility: 'personal',
    media_attachments: [],
    favourites_count: 0,
    translation: {
      contentHtml: '<p>こんにちは</p>',
      media_attachments: [{ id: 'm1', description: 'ねこ' }],
    },
    translationMode: 'translated',
    translationPending: true,
    translationRequestId: 'req-a',
    translationContentSignature: 'old',
    translationStatusSignature: 'old',
  });

  const importProper = (status, extra = {}) => {
    const actions = [];
    const getState = () => fromJS({
      statuses: { proper: storedProper, wrap: storedWrapper },
      polls: extra.polls || {},
      accounts: {},
    });
    const dispatch = (action) => {
      if (typeof action === 'function') {
        action(dispatch, getState);
      } else {
        actions.push(action);
      }
    };

    importFetchedStatuses([status])(dispatch, getState);

    return actions.find(action => action.type === STATUSES_IMPORT).statuses;
  };

  const wrapperOf = (statuses) => statuses.find(status => status.id === 'wrap');

  it('drops the wrapper translation after the boosted status body changes', () => {
    const statuses = importProper(proper({
      content: '<p>Hello again</p>',
      updated_at: '2020-01-02T00:00:00.000Z',
    }));
    const wrapper = wrapperOf(statuses);

    expect(wrapper.translation).toBeUndefined();
    expect(wrapper.translationMode).toBeUndefined();
    expect(wrapper.translationPending).toBeUndefined();
    expect(wrapper.translationRequestId).toBeUndefined();
    expect(wrapper.translationContentSignature).toBeUndefined();
    expect(wrapper.translationStatusSignature).toBeUndefined();
    expect(statuses.find(status => status.id === 'proper').content).toBe('<p>Hello again</p>');
  });

  it('drops the wrapper translation after a boosted media description changes', () => {
    const statuses = importProper(proper({
      updated_at: '2020-01-02T00:00:00.000Z',
      media_attachments: [
        { id: 'm1', type: 'image', description: 'a kitten', url: 'https://example.test/cat.jpg', remote_url: 'https://example.test/cat.jpg' },
      ],
    }));

    expect(wrapperOf(statuses).translation).toBeUndefined();
    expect(wrapperOf(statuses).translationRequestId).toBeUndefined();
  });

  it('keeps the wrapper translation when a refresh only changes a counter', () => {
    const statuses = importProper(proper({
      updated_at: '2020-01-02T00:00:00.000Z',
      favourites_count: 4,
    }));

    expect(wrapperOf(statuses)).toBeUndefined();
    expect(statuses.find(status => status.id === 'proper').favourites_count).toBe(4);
  });

  it('keeps fresh wrapper fields when the boost payload arrives with an edited proper status', () => {
    const statuses = importProper({
      ...proper({
        content: '<p>Hello again</p>',
        updated_at: '2020-01-02T00:00:00.000Z',
      }),
      id: 'wrap',
      visibility: 'personal',
      reblog: proper({
        content: '<p>Hello again</p>',
        updated_at: '2020-01-02T00:00:00.000Z',
      }),
      reblogs_count: 3,
      content: '',
      spoiler_text: '',
      media_attachments: [],
    });
    const wrapper = wrapperOf(statuses);

    expect(wrapper.translation).toBeUndefined();
    expect(wrapper.translationRequestId).toBeUndefined();
    expect(wrapper.reblogs_count).toBe(3);
    expect(statuses.find(status => status.id === 'proper').content).toBe('<p>Hello again</p>');
  });

  it('drops the wrapper translation when boosted poll option titles change', () => {
    const withPoll = storedProper.set('poll', 'p1');
    const actions = [];
    const getState = () => fromJS({
      statuses: {
        proper: withPoll,
        wrap: storedWrapper,
      },
      polls: {
        p1: { id: 'p1', emojis: [], options: [{ title: 'Yes' }, { title: 'No' }] },
      },
      accounts: {},
    });
    const dispatch = (action) => {
      if (typeof action === 'function') {
        action(dispatch, getState);
      } else {
        actions.push(action);
      }
    };

    importFetchedStatuses([proper({
      updated_at: '2020-01-02T00:00:00.000Z',
      poll: { id: 'p1', emojis: [], own_votes: [], options: [{ title: 'Yeah' }, { title: 'No' }] },
    })])(dispatch, getState);

    const statuses = actions.find(action => action.type === STATUSES_IMPORT).statuses;

    expect(wrapperOf(statuses).translation).toBeUndefined();
    expect(wrapperOf(statuses).translationRequestId).toBeUndefined();
  });
});
