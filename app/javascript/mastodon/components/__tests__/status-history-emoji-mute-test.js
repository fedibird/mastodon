/* eslint-disable react/prop-types */

import { act, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

import { EMOJI_MUTES_APPLY } from 'mastodon/actions/emoji_mutes';
import emojiMutes from 'mastodon/reducers/emoji_mutes';
import { resetEmojiMuteTextForTests } from 'mastodon/features/emoji/emoji_mute_text';
import CompareHistoryModal from 'mastodon/features/ui/components/compare_history_modal';

jest.mock('react-intl', () => {
  const ReactIntl = require('react');

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
    defineMessages: messages => messages,
    injectIntl: Component => props => <Component {...props} intl={{ formatDate: value => String(value), formatMessage: ({ defaultMessage }) => defaultMessage }} />,
    FormattedMessage,
  };
});

jest.mock('../relative_timestamp', () => ({ timestamp }) => <time>{timestamp}</time>);
jest.mock('../icon', () => () => null);
jest.mock('mastodon/components/icon', () => () => null);

import StatusHistoryRevision from '../status_history_revision';

const OK = '👌';

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

const localEmoji = (id, shortcode = 'blob') => ({
  id: String(id),
  shortcode,
  domain: null,
  url: `https://cdn.example/${id}.svg`,
  static_url: `https://cdn.example/${id}.png`,
});

const account = (acct = 'alice') => fromJS({
  id: 'a1',
  username: 'alice',
  acct,
  display_name: 'Alice',
  display_name_html: 'Alice',
  url: 'https://example.test/@alice',
  avatar: 'https://example.test/a.png',
  avatar_static: 'https://example.test/a.png',
});

const revision = (extra = {}) => fromJS({
  content: `<p>Hello :blob: ${OK} <a href="https://example.test/keep">keep</a></p>`,
  spoiler_text: `Secret ${OK}`,
  created_at: '2026-01-02T03:04:00.000Z',
  account: 'a1',
  original: false,
  sensitive: true,
  emojis: [localEmoji('10')],
  poll: { options: [{ title: 'Yes :blob:' }, { title: 'No <b>' }] },
  media_attachments: [{ id: 'm1', description: 'a photo' }],
  ...extra,
});

const makeStore = (items, editor = account()) => createStore((state = fromJS({
  emojiMutes: { revision: null, rules: [] },
  statuses: { s1: { language: 'ja' } },
  history: { s1: { items } },
  accounts: { a1: editor },
}), action) => state.set('emojiMutes', emojiMutes(state.get('emojiMutes'), action)));

const apply = (store, mutes, revisionNumber = '2') => {
  act(() => {
    store.dispatch({ type: EMOJI_MUTES_APPLY, revision: revisionNumber, mutes });
  });
};

const renderRevision = (node) => render(node);

describe('status history replace_in_text', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
  });

  it('bakes the revision emoji id and updates both history entrances without rewriting the revision', () => {
    const stored = revision();
    const store = makeStore(fromJS([stored]));
    const { container } = renderRevision(
      <Provider store={store}>
        <div>
          <CompareHistoryModal statusId='s1' index={0} onClose={jest.fn()} />
          <StatusHistoryRevision revision={stored} account={account()} language='ja' onClose={jest.fn()} />
        </div>
      </Provider>,
    );
    const bodies = () => container.querySelectorAll('.status__content__text');

    expect(bodies().length).toBe(2);
    expect(bodies()[0].getAttribute('lang')).toBe('ja');
    expect(bodies()[0].querySelector('[data-emoji-id="10"]')).not.toBeNull();
    expect(bodies()[0].querySelector('a').getAttribute('href')).toBe('https://example.test/keep');
    expect(container.querySelector('.compare-history-modal__poll').textContent).toContain('No <b>');
    expect(container.querySelector('.compare-history-modal__poll b')).toBeNull();
    expect(container.textContent).toContain('Media description: a photo');
    expect(container.textContent).toContain('2026-01-02T03:04:00.000Z');
    expect(stored.get('content')).toContain(':blob:');
    expect(stored.get('spoiler_text')).toBe(`Secret ${OK}`);

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' }, '[new]'),
    ]);

    expect(bodies()[0].querySelector('[data-emoji-id="10"]')).not.toBeNull();
    expect(container.textContent).not.toContain('[new]');

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '<img src="https://evil.test/x.png">'),
      rule({ kind: 'unicode', native: OK }, '[ok]'),
    ], '3');

    Array.from(bodies()).forEach(body => {
      expect(body.querySelector('[data-emoji-id]')).toBeNull();
      expect(body.querySelector('img')).toBeNull();
      expect(body.querySelector('[src*="evil.test"]')).toBeNull();
      expect(body.innerHTML).not.toContain('cdn.example');
      expect(body.innerHTML).toContain('&lt;img');
      expect(body.textContent).toContain('<img src="https://evil.test/x.png">');
      expect(body.textContent).toContain('[ok]');
      expect(body.querySelector('a').getAttribute('href')).toBe('https://example.test/keep');
    });
    expect(container.querySelector('.compare-history-modal__poll').textContent).toContain('<img src="https://evil.test/x.png">');
    expect(container.querySelector('.compare-history-modal__poll').innerHTML).not.toContain('cdn.example');
    expect(container.textContent).toContain('[ok]');
    expect(container.textContent).toContain('2026-01-02T03:04:00.000Z');
    expect(stored.get('content')).toContain(':blob:');
    expect(stored.getIn(['poll', 'options', 0, 'title'])).toBe('Yes :blob:');

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[blob]', { replace_in_text: false }),
    ], '4');

    expect(bodies()[0].querySelector('[data-emoji-id="10"]')).not.toBeNull();
  });

  it('keeps an older local id distinct from a reused shortcode and a remote author distinct from another domain', () => {
    const older = revision({ emojis: [localEmoji('10')] });
    const newer = revision({ emojis: [localEmoji('11')] });
    const remoteAccount = account('alice@remote.example');
    const remote = revision({
      emojis: [{ ...localEmoji('10'), domain: 'wrong.example' }],
    });
    const store = makeStore(fromJS([remote]), remoteAccount);
    const { container } = renderRevision(
      <Provider store={store}>
        <div>
          <StatusHistoryRevision revision={older} account={account()} onClose={jest.fn()} />
          <StatusHistoryRevision revision={newer} account={account()} onClose={jest.fn()} />
          <StatusHistoryRevision revision={remote} account={remoteAccount} onClose={jest.fn()} />
          <StatusHistoryRevision revision={remote} account={null} onClose={jest.fn()} />
        </div>
      </Provider>,
    );
    const bodies = () => container.querySelectorAll('.status__content__text');

    expect(bodies()[2].querySelector('[data-domain="remote.example"]')).not.toBeNull();
    expect(bodies()[2].querySelector('[data-emoji-id]')).toBeNull();
    expect(bodies()[2].innerHTML).not.toContain('wrong.example');
    expect(bodies()[3].querySelector('[data-emoji-id]')).toBeNull();
    expect(bodies()[3].querySelector('[data-domain="remote.example"]')).toBeNull();

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[old]'),
      rule({ kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'blob' }, '[remote]'),
    ]);

    expect(bodies()[0].textContent).toContain('[old]');
    expect(bodies()[0].querySelector('[data-emoji-id="10"]')).toBeNull();
    expect(bodies()[1].querySelector('[data-emoji-id="11"]')).not.toBeNull();
    expect(bodies()[1].textContent).not.toContain('[old]');
    expect(bodies()[2].textContent).toContain('[remote]');
    expect(bodies()[2].querySelector('img.custom-emoji')).toBeNull();
    expect(bodies()[3].querySelector('img.custom-emoji')).not.toBeNull();
    expect(bodies()[3].textContent).not.toContain('[remote]');
  });

  it('leaves a local revision emoji without an id unmapped to a shortcode', () => {
    const unnamed = revision({
      emojis: [{ shortcode: 'blob', domain: null, url: 'https://cdn.example/blob.svg', static_url: 'https://cdn.example/blob.png' }],
    });
    const store = makeStore(fromJS([unnamed]));
    const { container } = render(
      <Provider store={store}>
        <StatusHistoryRevision revision={unnamed} account={account()} onClose={jest.fn()} />
      </Provider>,
    );

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[blob]'),
    ]);

    const body = container.querySelector('.status__content__text');

    expect(body.querySelector('[data-emoji-id]')).toBeNull();
    expect(body.querySelector('img.custom-emoji')).not.toBeNull();
    expect(body.textContent).not.toContain('[blob]');
    expect(unnamed.getIn(['emojis', 0, 'shortcode'])).toBe('blob');
  });

  it('does not paint a re-registered id onto an original revision the api could not prove', () => {
    const original = revision({
      content: '<p>hello :blob:</p>',
      spoiler_text: '',
      emojis: [],
      poll: null,
      original: true,
    });
    const store = makeStore(fromJS([original]));
    const { container } = render(
      <Provider store={store}>
        <StatusHistoryRevision revision={original} account={account()} onClose={jest.fn()} />
      </Provider>,
    );

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' }, '[new]'),
    ]);

    const body = container.querySelector('.status__content__text');

    expect(body.innerHTML).not.toContain('data-emoji-id');
    expect(body.textContent).toContain(':blob:');
    expect(body.textContent).not.toContain('[new]');
    expect(original.get('emojis').size).toBe(0);
  });
});
