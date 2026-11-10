/* eslint-disable react/prop-types */

import { act, fireEvent, render } from '@testing-library/react';
import { fromJS } from 'immutable';
import React from 'react';
import { Provider } from 'react-redux';
import { createStore } from 'redux';

import { EMOJI_MUTES_APPLY } from 'mastodon/actions/emoji_mutes';
import { normalizePoll, normalizePollOptionTranslation } from 'mastodon/actions/importer/normalizer';
import emojify from 'mastodon/features/emoji/emoji';
import { emojiMuteTextParseCount, resetEmojiMuteTextForTests } from 'mastodon/features/emoji/emoji_mute_text';
import emojiMutes from 'mastodon/reducers/emoji_mutes';

jest.mock('react-intl', () => {
  const intl = {
    locale: 'ja',
    now: () => Date.now(),
    formatMessage: ({ defaultMessage }) => defaultMessage,
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
  };
});

jest.mock('../relative_timestamp', () => () => null);
jest.mock('mastodon/components/icon', () => () => null);
jest.mock('mastodon/features/ui/util/optional_motion', () => ({ children }) => children({ width: 0 }));

import Poll from '../poll';

const THUMB = '👍';
const THUMB_LIGHT = '👍🏻';
const FAMILY = '👨‍👩‍👧‍👧';

const unicodeImg = (native, src) => (
  `<img draggable="false" class="emojione" alt="${native}" title="${native}" src="${src}">`
);

const localImg = (id, shortcode = 'blob') => (
  `<img draggable="false" class="emojione custom-emoji" alt=":${shortcode}:" title="${shortcode}" src="https://cdn.example/${id}.svg" data-shortcode="${shortcode}" data-domain="" data-original="https://cdn.example/${id}.svg" data-static="https://cdn.example/${id}.png" data-emoji-id="${id}">`
);

const remoteImg = (domain, shortcode = 'blob') => (
  `<img draggable="false" class="emojione custom-emoji" alt=":${shortcode}:" title="${shortcode}" src="https://cdn.example/${domain}/${shortcode}.svg" data-shortcode="${shortcode}" data-domain="${domain}" data-original="https://cdn.example/${domain}/${shortcode}.svg" data-static="https://cdn.example/${domain}/${shortcode}.png">`
);

const bareShortcodeImg = (shortcode = 'blob') => (
  `<img draggable="false" class="emojione custom-emoji" alt=":${shortcode}:" title="${shortcode}" src="https://cdn.example/plain/${shortcode}.svg" data-shortcode="${shortcode}">`
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

const localEmoji = (id, shortcode = 'blob', domain = null) => ({
  id: String(id),
  shortcode,
  domain,
  url: `https://cdn.example/${id}.svg`,
  static_url: `https://cdn.example/${id}.png`,
});

const makeStore = () => createStore((state = fromJS({ emojiMutes: { revision: null, rules: [] } }), action) => (
  state.set('emojiMutes', emojiMutes(state.get('emojiMutes'), action))
));

const apply = (store, mutes, revision = '2') => {
  act(() => {
    store.dispatch({ type: EMOJI_MUTES_APPLY, revision, mutes });
  });
};

const option = (title, html, extra = {}) => ({
  title,
  title_emojified: html,
  votes_count: 0,
  ...extra,
});

const buildPoll = (options, extra = {}) => fromJS({
  id: 'p1',
  multiple: false,
  expired: false,
  expires_at: null,
  voted: false,
  votes_count: 0,
  voters_count: 0,
  own_votes: [],
  emojis: [],
  options,
  ...extra,
});

const renderPoll = (poll, props = {}) => {
  const store = props.store || makeStore();
  const onVote = props.onVote || jest.fn();
  const view = render(
    <Provider store={store}>
      <Poll
        poll={poll}
        translationMode={props.translationMode}
        sourceLang={props.sourceLang || 'en'}
        targetLang={props.targetLang || 'ja'}
        lang='en'
        disabled={false}
        refresh={jest.fn()}
        onVote={onVote}
      />
    </Provider>,
  );

  return { ...view, store, onVote };
};

describe('poll replace_in_text', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
  });

  it('replaces original, translated, and bilingual option text and keeps the vote index', () => {
    const source = `Yes ${localImg('10')} ${localImg('11', 'other')} ${remoteImg('a.test')} ${remoteImg('b.test')} ${unicodeImg(THUMB, '/emoji/thumb.svg')} ${unicodeImg(THUMB_LIGHT, '/emoji/light.svg')} ${unicodeImg(FAMILY, '/emoji/family.svg')}`;
    const translated = `Oui ${localImg('10')} ${unicodeImg(THUMB, '/emoji/thumb.svg')}`;
    const poll = buildPoll([
      option('Yes :blob:', source, {
        translation: { title: 'Oui :blob:', titleHtml: translated },
      }),
      option('No', 'No'),
    ]);
    const { container, store, onVote } = renderPoll(poll, { translationMode: 'original' });
    const input = () => container.querySelector('.poll__input');

    expect(input().getAttribute('aria-label')).toBe('Yes :blob:');
    expect(input().getAttribute('lang')).toBe('en');
    expect(container.querySelector('[data-emoji-id="10"]')).not.toBeNull();
    expect(poll.getIn(['options', 0, 'title'])).toBe('Yes :blob:');
    expect(poll.getIn(['options', 0, 'title_emojified'])).toBe(source);

    const parsed = emojiMuteTextParseCount();

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '<img src=x onerror=alert(1)>'),
      rule({ kind: 'unicode', native: THUMB_LIGHT }, '[light]'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]'),
      rule({ kind: 'custom', scope: 'remote', domain: 'a.test', shortcode: 'blob' }, '[remote]'),
    ]);

    const text = container.querySelector('.poll__option__text');

    expect(text.textContent).toContain('[local]');
    expect(text.textContent).toContain('[remote]');
    expect(text.textContent).toContain('<img src=x onerror=alert(1)>');
    expect(text.textContent).toContain('[light]');
    expect(text.querySelector(`img[alt="${FAMILY}"]`)).not.toBeNull();
    expect(text.querySelector('[data-emoji-id="11"]')).not.toBeNull();
    expect(text.querySelector('[data-domain="b.test"]')).not.toBeNull();
    expect(text.querySelector('[data-emoji-id="10"]')).toBeNull();
    expect(text.querySelector('[data-domain="a.test"]')).toBeNull();
    expect(text.querySelector('img[src*="thumb"]')).toBeNull();
    expect(text.querySelector('img[src*="light"]')).toBeNull();
    expect(text.querySelector('img[onerror]')).toBeNull();
    expect(input().getAttribute('aria-label')).toContain('[local]');
    expect(input().getAttribute('aria-label')).toContain(FAMILY);
    expect(input().getAttribute('aria-label')).not.toContain('cdn.example/10');
    expect(input().getAttribute('aria-label')).not.toContain('/emoji/thumb.svg');
    expect(input().getAttribute('lang')).toBe('en');
    expect(poll.getIn(['options', 0, 'title_emojified'])).toBe(source);
    expect(poll.getIn(['options', 0, 'translation', 'titleHtml'])).toBe(translated);
    expect(emojiMuteTextParseCount()).toBe(parsed + 1);

    apply(store, [
      rule({ kind: 'unicode', native: THUMB }, '<img src=x onerror=alert(1)>'),
      rule({ kind: 'unicode', native: THUMB_LIGHT }, '[light]'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]'),
      rule({ kind: 'custom', scope: 'remote', domain: 'a.test', shortcode: 'blob' }, '[remote]'),
    ], '3');

    expect(emojiMuteTextParseCount()).toBe(parsed + 1);

    fireEvent.click(container.querySelector('input[name="vote-options"]'));
    fireEvent.click(container.querySelector('button'));

    expect(onVote).toHaveBeenCalledWith(['0']);
    expect(container.querySelectorAll('.poll__option__text')[1].textContent).toBe('No');

    const { container: translatedView } = renderPoll(poll, { store, translationMode: 'translated' });
    const translatedText = translatedView.querySelector('.poll__option__text');

    expect(translatedText.textContent).toContain('[local]');
    expect(translatedText.textContent).not.toContain('cdn.example/10');
    expect(translatedText.getAttribute('lang')).toBe('ja');
    expect(translatedView.querySelector('.poll__input').getAttribute('aria-label')).toBe(translatedText.textContent);
    expect(translatedView.querySelector('.poll__input').getAttribute('lang')).toBe('ja');

    const { container: bilingual } = renderPoll(poll, { store, translationMode: 'bilingual' });
    const sourceNode = bilingual.querySelector('.status-translation-pair__source');
    const targetNode = bilingual.querySelector('.status-translation-pair__target');

    expect(sourceNode.textContent).toContain('[remote]');
    expect(sourceNode.getAttribute('lang')).toBe('en');
    expect(targetNode.textContent).toContain('[local]');
    expect(targetNode.getAttribute('lang')).toBe('ja');
    expect(bilingual.querySelector('.poll__input').getAttribute('aria-label')).toBeNull();
    expect(bilingual.querySelector('.poll__input').getAttribute('aria-labelledby')).toBe('poll-p1-0-source poll-p1-0-target');
    expect(sourceNode.id).toBe('poll-p1-0-source');
    expect(targetNode.id).toBe('poll-p1-0-target');

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]', { replace_in_text: false }),
    ], '4');

    expect(container.querySelector('[data-emoji-id="10"]')).not.toBeNull();
    expect(container.querySelector('.poll__input').getAttribute('aria-label')).toBe('Yes :blob:');
  });

  it('does not mute a custom image that has no stable id or the wrong domain', () => {
    const html = `Keep ${bareShortcodeImg()} ${localImg('11')}`;
    const poll = buildPoll([option('Keep :blob:', html)]);
    const { container, store } = renderPoll(poll);

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]'),
      rule({ kind: 'custom', scope: 'remote', domain: 'other.test', shortcode: 'blob' }, '[remote]'),
    ]);

    expect(container.querySelector('.poll__option__text').innerHTML).toContain('cdn.example/plain/blob.svg');
    expect(container.querySelector('[data-emoji-id="11"]')).not.toBeNull();
    expect(container.textContent).not.toContain('[local]');
    expect(container.querySelector('.poll__input').getAttribute('aria-label')).toBe('Keep :blob:');
  });

  it('builds fallback html from the emoji row and fails closed without an id', () => {
    const identified = buildPoll([
      { title: 'Yes :blob:', votes_count: 0 },
    ], { emojis: [localEmoji('10')] });
    const { container, store } = renderPoll(identified);

    expect(container.querySelector('[data-emoji-id="10"]')).not.toBeNull();
    expect(identified.getIn(['options', 0, 'title'])).toBe('Yes :blob:');

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, ''),
    ]);

    expect(container.querySelector('img')).toBeNull();
    expect(container.querySelector('.poll__option__text').textContent).toBe('Yes ');
    expect(container.querySelector('.poll__input').getAttribute('aria-label')).toBe('Yes ');
    expect(container.innerHTML).not.toContain('cdn.example/10');

    const anonymous = buildPoll([
      { title: 'Yes :blob:', votes_count: 0 },
    ], { emojis: [{ shortcode: 'blob', url: 'https://cdn.example/plain.svg', static_url: 'https://cdn.example/plain.png', domain: null }] });
    const anonymousView = renderPoll(anonymous);

    apply(anonymousView.store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[local]'),
    ]);

    expect(anonymousView.container.querySelector('img').getAttribute('src')).toContain('cdn.example/plain.png');
    expect(anonymousView.container.querySelector('[data-emoji-id]')).toBeNull();
    expect(anonymousView.container.textContent).not.toContain('[local]');
  });

  it('uses the remote author domain for a translated option and ignores a shortcode-only rule', () => {
    const poll = buildPoll([
      { title: 'Yes :blob:', votes_count: 0, translation: { title: 'Oui :blob:' } },
    ], { emojis: [localEmoji('9', 'blob', 'remote.test')] });
    const { container, store } = renderPoll(poll, { translationMode: 'bilingual' });
    const images = container.querySelectorAll('img.custom-emoji');

    expect(images).toHaveLength(2);
    images.forEach(image => {
      expect(image.getAttribute('data-domain')).toBe('remote.test');
      expect(image.hasAttribute('data-emoji-id')).toBe(false);
    });

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '9', shortcode: 'blob' }, '[local]'),
    ]);

    expect(container.querySelectorAll('img.custom-emoji')).toHaveLength(2);

    apply(store, [
      rule({ kind: 'custom', scope: 'remote', domain: 'remote.test', shortcode: 'blob' }, '[remote]'),
    ], '5');

    expect(container.querySelector('img')).toBeNull();
    expect(container.querySelector('.status-translation-pair__source').textContent).toContain('[remote]');
    expect(container.querySelector('.status-translation-pair__target').textContent).toContain('[remote]');
    expect(container.querySelector('.status-translation-pair__source').getAttribute('lang')).toBe('en');
    expect(container.querySelector('.status-translation-pair__target').getAttribute('lang')).toBe('ja');
  });
});

describe('poll html identity', () => {
  const base = {
    id: 'p1',
    own_votes: [],
    options: [{ title: 'Yes :blob:' }, { title: 'No' }],
  };

  it('records a local id and a remote domain without rewriting the option title', () => {
    const local = normalizePoll({ ...base, emojis: [localEmoji('10')] });
    const remote = normalizePoll({
      ...base,
      emojis: [localEmoji('9', 'blob', 'remote.test')],
    });
    const mixed = normalizePoll({
      ...base,
      options: [{ title: 'Yes :localblob: :remoteblob:' }, { title: 'No' }],
      emojis: [localEmoji('10', 'localblob'), localEmoji('9', 'remoteblob', 'remote.test')],
    });

    expect(local.options[0].title).toBe('Yes :blob:');
    expect(local.options[0].title_emojified).toContain('data-emoji-id="10"');
    expect(local.options[0].title_emojified).toContain('data-domain=""');
    expect(remote.options[0].title_emojified).toContain('data-domain="remote.test"');
    expect(remote.options[0].title_emojified).not.toContain('data-emoji-id');
    expect(mixed.options[0].title_emojified).toContain('data-emoji-id="10"');
    expect(mixed.options[0].title_emojified).toContain('data-shortcode="remoteblob"');
    expect(mixed.options[0].title_emojified).toContain('data-domain="remote.test"');
    expect(mixed.options[0].title).toBe('Yes :localblob: :remoteblob:');
  });

  it('keeps a separate domain on every poll and announcement row', () => {
    const emojis = [
      localEmoji('10', 'localblob'),
      localEmoji('19', 'blob', 'a.test'),
      localEmoji('20', 'remotea', 'a.test'),
      localEmoji('21', 'remoteb', 'b.test'),
      localEmoji('22', 'blob', 'b.test'),
    ];
    const poll = normalizePoll({
      id: 'p1',
      own_votes: [],
      emojis,
      options: [{ title: 'Yes :localblob: :remotea: :remoteb: :blob:' }],
    });
    const html = poll.options[0].title_emojified;
    const translated = normalizePollOptionTranslation({ title: 'Oui :localblob: :remotea: :blob:' }, fromJS({ emojis }));

    expect(html).toContain('data-emoji-id="10"');
    expect(html).toContain('data-domain="a.test"');
    expect(html).toContain('data-domain="b.test"');
    expect(html).not.toContain('data-emoji-id="19"');
    expect(html).not.toContain('data-emoji-id="22"');
    expect(poll.options[0].title).toBe('Yes :localblob: :remotea: :remoteb: :blob:');
    expect(translated.title).toBe('Oui :localblob: :remotea: :blob:');
    expect(translated.titleHtml).toContain('data-emoji-id="10"');
    expect(translated.titleHtml).toContain('data-shortcode="remotea"');
    expect(translated.titleHtml).toContain('data-domain="a.test"');
    expect(translated.titleHtml).toContain('data-domain="b.test"');
    expect(translated.titleHtml).not.toContain('data-emoji-id="22"');

    const shown = fromJS({
      id: 'p1',
      multiple: false,
      expired: false,
      expires_at: null,
      voted: false,
      votes_count: 0,
      voters_count: 0,
      own_votes: [],
      emojis,
      options: [{
        title: poll.options[0].title,
        title_emojified: html,
        votes_count: 0,
        translation: { title: translated.title, titleHtml: translated.titleHtml },
      }],
    });
    const { container, store } = renderPoll(shown, { translationMode: 'bilingual' });

    apply(store, [
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'localblob' }, '[local]'),
      rule({ kind: 'custom', scope: 'remote', domain: 'a.test', shortcode: 'remotea' }, '[a]'),
      rule({ kind: 'custom', scope: 'remote', domain: 'a.test', shortcode: 'blob' }, '[wrong-domain]'),
    ]);

    const source = container.querySelector('.status-translation-pair__source');
    const target = container.querySelector('.status-translation-pair__target');

    expect(source.textContent).toContain('[local]');
    expect(source.textContent).toContain('[a]');
    expect(source.textContent).not.toContain('[wrong-domain]');
    expect(source.querySelector('[data-emoji-id="10"]')).toBeNull();
    expect(source.querySelector('[data-shortcode="remotea"]')).toBeNull();
    expect(source.querySelector('[data-shortcode="remoteb"]').getAttribute('data-domain')).toBe('b.test');
    expect(source.querySelector('[data-shortcode="blob"]').getAttribute('data-domain')).toBe('b.test');
    expect(source.innerHTML).not.toContain('cdn.example/10');
    expect(target.textContent).toContain('[local]');
    expect(target.textContent).toContain('[a]');
    expect(target.querySelector('[data-shortcode="blob"]').getAttribute('data-domain')).toBe('b.test');
    expect(shown.getIn(['options', 0, 'title_emojified'])).toBe(html);
    expect(shown.getIn(['options', 0, 'translation', 'titleHtml'])).toBe(translated.titleHtml);

    const authorHtml = emojify(':blob:', {
      ':blob:': localEmoji('7', 'blob', 'row.test'),
    }, 'author.test');

    expect(authorHtml).toContain('data-domain="author.test"');
    expect(authorHtml).not.toContain('data-domain="row.test"');
    expect(authorHtml).not.toContain('data-emoji-id');
  });

  it('rebuilds translated option html when the emoji row changes and keeps it when the row does not', () => {
    const previous = fromJS(normalizePoll({ ...base, emojis: [localEmoji('10')] }))
      .setIn(['options', 0, 'translation'], fromJS({ title: 'Oui :blob:', titleHtml: 'old-10' }));
    const same = normalizePoll({ ...base, emojis: [localEmoji('10')] }, previous);
    const next = normalizePoll({ ...base, emojis: [localEmoji('11')] }, previous);
    const dropped = normalizePoll({ ...base, emojis: [localEmoji('11')] }, previous.setIn(['options', 0, 'translation'], fromJS({ titleHtml: 'old-10' })));

    expect(same.options[0].translation.get('titleHtml')).toBe('old-10');
    expect(next.options[0].title).toBe('Yes :blob:');
    expect(next.options[0].title_emojified).toContain('data-emoji-id="11"');
    expect(next.options[0].title_emojified).not.toContain('data-emoji-id="10"');
    expect(next.options[0].translation.title).toBe('Oui :blob:');
    expect(next.options[0].translation.titleHtml).toContain('data-emoji-id="11"');
    expect(next.options[0].translation.titleHtml).not.toContain('old-10');
    expect(dropped.options[0].translation).toBeUndefined();
  });

  it('stamps the poll emoji domain onto a translation result', () => {
    const poll = fromJS({ emojis: [localEmoji('9', 'blob', 'remote.test')] });
    const translated = normalizePollOptionTranslation({ title: 'Oui :blob:' }, poll);

    expect(translated.title).toBe('Oui :blob:');
    expect(translated.titleHtml).toContain('data-domain="remote.test"');
    expect(translated.titleHtml).not.toContain('data-emoji-id');
  });
});
