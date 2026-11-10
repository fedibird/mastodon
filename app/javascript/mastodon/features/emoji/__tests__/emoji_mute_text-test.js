import { fromJS } from 'immutable';

import { EMOJI_MUTES_APPLY } from 'mastodon/actions/emoji_mutes';
import { normalizeStatus, normalizeStatusTranslation } from 'mastodon/actions/importer/normalizer';
import statusesReducer from 'mastodon/reducers/statuses';

import emojify from '../emoji';
import {
  buildReplaceInTextIndex,
  emojiMuteTextParseCount,
  replaceEmojiInDisplayHtml,
  replaceInTextIndexFromRules,
  resetEmojiMuteTextForTests,
} from '../emoji_mute_text';

const THUMBS = '👍';
const THUMBS_LIGHT = '👍🏻';
const FAMILY = '👨‍👩‍👧‍👧';
const PERSON = '👨';
const EXCLAMATION = '❗';
const DOUBLE_EXCLAMATION = '‼️';

const localEmoji = (id, shortcode = 'blob') => ({
  id: String(id),
  shortcode,
  url: `https://cdn.example/${id}.svg`,
  static_url: `https://cdn.example/${id}.png`,
  domain: null,
});

const rule = (emoji, replacement = '［絵文字］', effects = {}) => ({
  id: 'm1',
  revision: '1',
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

const unicodeRule = (native, replacement, effects) => rule({ kind: 'unicode', native }, replacement, effects);

const img = ({ alt, src = '/emoji/x.svg', extra = '', custom = false }) => (
  `<img draggable="false" class="emojione${custom ? ' custom-emoji' : ''}" alt="${alt}" title=":name:" src="${src}"${extra}>`
);

const show = (html, rules) => replaceEmojiInDisplayHtml(html, buildReplaceInTextIndex(rules));

const textOf = html => {
  const template = document.createElement('template');
  template.innerHTML = html;
  return template.content.textContent;
};

describe('replace_in_text display transform', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
  });

  it('replaces a whole unicode sequence and leaves a different sequence', () => {
    const html = `<p>${img({ alt: THUMBS, src: '/emoji/1f44d.svg' })}${img({ alt: THUMBS_LIGHT, src: '/emoji/1f44d-1f3fb.svg' })}${img({ alt: FAMILY, src: '/emoji/family.svg' })}</p>`;
    const result = show(html, [unicodeRule(THUMBS_LIGHT, '[skin]'), unicodeRule(FAMILY, '[family]')]);
    const template = document.createElement('template');
    template.innerHTML = result;

    expect(textOf(result)).toBe('[skin][family]');
    expect(template.content.querySelectorAll('img')).toHaveLength(1);
    expect(template.content.querySelector('img').getAttribute('alt')).toBe(THUMBS);
    expect(template.content.querySelector('img').getAttribute('src')).toBe('/emoji/1f44d.svg');
    expect(result).not.toContain('1f44d-1f3fb');
    expect(result).not.toContain('family.svg');
    expect(result).not.toContain(THUMBS_LIGHT);
    expect(result).not.toContain(PERSON);
  });

  it('treats variation selectors as different emoji', () => {
    const html = `<p>${img({ alt: EXCLAMATION, src: '/emoji/2757.svg' })}${img({ alt: DOUBLE_EXCLAMATION, src: '/emoji/203c.svg' })}</p>`;
    const result = show(html, [unicodeRule(EXCLAMATION, '[one]')]);

    const template = document.createElement('template');
    template.innerHTML = result;
    const kept = template.content.querySelector('img');

    expect(textOf(result)).toBe('[one]');
    expect(kept.getAttribute('alt')).toBe(DOUBLE_EXCLAMATION);
    expect(kept.getAttribute('src')).toBe('/emoji/203c.svg');
    expect(result).not.toContain('/emoji/2757.svg');
  });

  it('removes the picture wrapper so srcset and alt do not remain', () => {
    const html = `<picture><source media="(prefers-color-scheme: dark)" srcset="/emoji/dark.svg"><img class="emojione" alt="${THUMBS}" title=":thumbsup:" src="/emoji/light.svg"></picture>`;
    const result = show(html, [unicodeRule(THUMBS, 'x')]);

    expect(result).toBe('x');
    expect(result).not.toContain('src');
    expect(result).not.toContain('alt');
    expect(result).not.toContain('title');
  });

  it('replaces a local custom emoji only from the id stored on the image', () => {
    const current = localEmoji('10');
    const html = emojify('<p>Hi :blob: there</p>', { ':blob:': current }, '');
    const withoutId = emojify('<p>Hi :blob: there</p>', {
      ':blob:': { shortcode: 'blob', url: current.url, static_url: current.static_url },
    }, '');
    const mute10 = [rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[blob]')];
    const mute11 = [rule({ kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' }, '[new]')];
    const matched = show(html, mute10);
    const otherRow = show(html, mute11);

    expect(html).toContain('data-emoji-id="10"');
    expect(textOf(matched)).toBe('Hi [blob] there');
    expect(matched).not.toContain('cdn.example');
    expect(matched).not.toContain('data-emoji-id');
    expect(matched).not.toContain('alt=');
    expect(otherRow).toBe(html);
    expect(withoutId).not.toContain('data-emoji-id');
    expect(show(withoutId, mute10)).toBe(withoutId);
  });

  it('keeps an older generated image on its own id when the shortcode is reused', () => {
    const html = emojify('<p>:blob:</p>', { ':blob:': localEmoji('10') }, '');
    const mute10 = [rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[old]')];
    const mute11 = [rule({ kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' }, '[new]')];

    expect(textOf(show(html, mute10))).toBe('[old]');
    expect(show(html, mute11)).toBe(html);
    expect(html).toContain('cdn.example/10.svg');
  });

  it('keeps a literal shortcode when the emoji was not rendered', () => {
    const html = '<p>Say :blob: plainly</p>';
    const result = show(html, [rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' })]);

    expect(result).toBe(html);
  });

  it('replaces a remote custom emoji by domain and shortcode, not by cache id or a local id', () => {
    const remote = { shortcode: 'blob', url: 'https://remote.example/blob.svg', static_url: 'https://remote.example/blob.png', domain: 'remote.example', id: '99' };
    const html = emojify('<p>:blob:</p>', { ':blob:': remote }, 'remote.example');
    const otherDomain = emojify('<p>:blob:</p>', { ':blob:': { ...remote, url: 'https://other.example/blob.svg' } }, 'other.example');
    const mute = [rule({ kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'blob' }, '[remote]')];

    const matched = show(html, mute);
    const wrongDomain = show(otherDomain, mute);
    const localOnly = show(html, [rule({ kind: 'custom', scope: 'local', custom_emoji_id: '99', shortcode: 'blob' })]);

    expect(html).not.toContain('data-emoji-id');
    expect(textOf(matched)).toBe('[remote]');
    expect(matched).not.toContain('remote.example/blob');
    expect(wrongDomain).toBe(otherDomain);
    expect(localOnly).toBe(html);
  });

  it('escapes replacement text and does not emojify it again', () => {
    const html = `<p>A ${img({ alt: THUMBS, src: '/emoji/1f44d.svg' })} B</p>`;
    const nasty = show(html, [unicodeRule(THUMBS, '<img src=x onerror=alert(1)>&')]);
    const emojiText = show(html, [unicodeRule(THUMBS, `${THUMBS}<script>alert(1)</script>`)]);
    const empty = show(html, [unicodeRule(THUMBS, '')]);
    const specialText = 'a&b<c>"\'';
    const special = show(html, [unicodeRule(THUMBS, specialText)]);

    expect(nasty).not.toMatch(/<img/i);
    expect(nasty).not.toMatch(/<script/i);
    expect(nasty).toContain('&lt;img');
    expect(nasty).toContain('&amp;');
    expect(textOf(nasty)).toBe('A <img src=x onerror=alert(1)>& B');
    expect(emojiText).not.toContain('<script');
    expect(emojiText).not.toContain('class="emojione"');
    expect(textOf(emojiText)).toBe(`A ${THUMBS}<script>alert(1)</script> B`);
    expect(textOf(empty)).toBe('A  B');
    expect(empty).not.toContain('emojione');
    expect(textOf(special)).toBe(`A ${specialText} B`);
  });

  it('leaves html unchanged when replace_in_text is false', () => {
    const html = `<p>${img({ alt: THUMBS })} <a href="https://example.test/@alice" class="mention">@alice</a></p>`;
    const result = show(html, [unicodeRule(THUMBS, '[x]', { replace_in_text: false, hide_reactions: true })]);

    expect(result).toBe(html);
    expect(emojiMuteTextParseCount()).toBe(0);
  });

  it('keeps links and hashtags around a replaced emoji', () => {
    const html = `<p>${img({ alt: THUMBS, src: '/emoji/1f44d.svg' })} <a href="https://example.test/@alice" class="mention">@alice</a> <a href="https://example.test/tags/fedibird" class="mention hashtag">#fedibird</a></p>`;
    const result = show(html, [unicodeRule(THUMBS, '[ok]')]);
    const template = document.createElement('template');
    template.innerHTML = result;

    expect(textOf(result)).toBe('[ok] @alice #fedibird');
    expect(template.content.querySelector('a.mention').getAttribute('href')).toBe('https://example.test/@alice');
    expect(template.content.querySelector('a.hashtag').getAttribute('href')).toBe('https://example.test/tags/fedibird');
    expect(template.content.querySelector('img')).toBeNull();
  });

  it('memoizes by the generated html and the replace rules', () => {
    const html = emojify('<p>:blob:</p>', { ':blob:': localEmoji('10') }, '');
    const mute = buildReplaceInTextIndex([rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[blob]')]);
    const otherId = buildReplaceInTextIndex([rule({ kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' }, '[other]')]);

    const first = replaceEmojiInDisplayHtml(html, mute);
    const second = replaceEmojiInDisplayHtml(html, mute);
    expect(emojiMuteTextParseCount()).toBe(1);
    expect(second).toBe(first);

    const cleared = replaceEmojiInDisplayHtml(html, otherId);
    expect(cleared).toBe(html);
    expect(first).toContain('[blob]');
    expect(emojiMuteTextParseCount()).toBe(2);
  });

  it('reuses one index object when replace_in_text did not change', () => {
    const rules = fromJS([unicodeRule(THUMBS)]);
    const first = replaceInTextIndexFromRules(rules);
    const hideOnly = fromJS([unicodeRule(THUMBS, '［絵文字］', { hide_reactions: false })]);
    const second = replaceInTextIndexFromRules(hideOnly);
    const removed = replaceInTextIndexFromRules(fromJS([]));

    expect(second).toBe(first);
    expect(first.active).toBe(true);
    expect(removed.active).toBe(false);
    expect(replaceInTextIndexFromRules(fromJS([]))).toBe(removed);
  });

  it('keeps stored status html on normalize reuse and on mute apply', () => {
    const emoji = localEmoji('10');
    const payload = {
      id: '1',
      account: { id: 'a', acct: 'alice' },
      content: '<p>Hello :blob: 👌</p>',
      spoiler_text: 'CW :blob:',
      emojis: [emoji],
      media_attachments: [],
      mentions: [],
      tags: [],
      visibility: 'public',
      sensitive: false,
      language: 'en',
      url: 'https://example.test/1',
      uri: 'https://example.test/1',
      updated_at: '2026-11-10T00:00:00.000Z',
      quote: null,
    };
    const first = normalizeStatus(payload, null, '');
    const second = normalizeStatus({ ...payload }, fromJS(first), '');
    const index = buildReplaceInTextIndex([
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[blob]'),
      unicodeRule('👌', '[ok]'),
    ]);
    const shown = replaceEmojiInDisplayHtml(second.contentHtml, index);
    const shownSpoiler = replaceEmojiInDisplayHtml(second.spoilerHtml, index);
    const translation = normalizeStatusTranslation({
      content: '<p>Bonjour :blob:</p>',
      spoiler_text: 'Alerte :blob:',
      detected_source_language: 'en',
      language: 'fr',
      provider: 'test',
    }, fromJS(second), '');
    const shownTranslation = replaceEmojiInDisplayHtml(translation.contentHtml, index);

    expect(second.contentHtml).toBe(first.contentHtml);
    expect(second.spoilerHtml).toBe(first.spoilerHtml);
    expect(first.contentHtml).toContain('cdn.example/10.svg');
    expect(textOf(shown)).toBe('Hello [blob] [ok]');
    expect(textOf(shownSpoiler)).toBe('CW [blob]');
    expect(textOf(shownTranslation)).toBe('Bonjour [blob]');
    expect(translation.contentHtml).toContain('cdn.example/10.svg');
    expect(shown).not.toContain('cdn.example');

    let state = statusesReducer(undefined, {
      type: 'STATUS_IMPORT',
      status: { id: 's1', contentHtml: first.contentHtml, spoilerHtml: first.spoilerHtml, emoji_reactions: [] },
    });
    state = statusesReducer(state, {
      type: EMOJI_MUTES_APPLY,
      mutes: [],
      revision: '4',
      sameDocument: false,
      hideShrunk: false,
    });

    expect(state.getIn(['s1', 'contentHtml'])).toBe(first.contentHtml);
    expect(state.getIn(['s1', 'spoilerHtml'])).toBe(first.spoilerHtml);
    expect(first.contentHtml).toContain('data-emoji-id="10"');
  });

  it('rebuilds html when the same shortcode is a new local emoji and does not cross the ids', () => {
    const base = {
      id: '1',
      account: { id: 'a', acct: 'alice' },
      content: '<p>Hello :blob:</p>',
      spoiler_text: 'CW :blob:',
      media_attachments: [],
      mentions: [],
      tags: [],
      visibility: 'public',
      sensitive: false,
      language: 'en',
      url: 'https://example.test/1',
      uri: 'https://example.test/1',
      updated_at: '2026-11-10T00:00:00.000Z',
      quote: null,
    };
    const first = normalizeStatus({ ...base, emojis: [localEmoji('10')] }, null, '');
    const stored = fromJS(first).set('translation', fromJS({
      contentHtml: first.contentHtml,
      spoilerHtml: first.spoilerHtml,
      spoiler_text: '',
      language: 'ja',
    }));
    const second = normalizeStatus({ ...base, emojis: [localEmoji('11')] }, stored, '');
    const third = normalizeStatus({ ...base, emojis: [localEmoji('11')] }, fromJS(second), '');
    const mute10 = buildReplaceInTextIndex([rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[old]')]);
    const mute11 = buildReplaceInTextIndex([rule({ kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' }, '[new]')]);
    const keptTranslation = second.translation.get('contentHtml');

    expect(second.contentHtml).not.toBe(first.contentHtml);
    expect(second.contentHtml).toContain('data-emoji-id="11"');
    expect(second.contentHtml).not.toContain('data-emoji-id="10"');
    expect(second.spoilerHtml).toContain('data-emoji-id="11"');
    expect(second.shortHtml).toContain('data-emoji-id="11"');
    expect(third.contentHtml).toBe(second.contentHtml);
    expect(third.spoilerHtml).toBe(second.spoilerHtml);
    expect(keptTranslation).toBe(first.contentHtml);

    expect(replaceEmojiInDisplayHtml(first.contentHtml, mute11)).toBe(first.contentHtml);
    expect(replaceEmojiInDisplayHtml(first.contentHtml, mute10)).not.toContain('cdn.example/10');
    expect(replaceEmojiInDisplayHtml(second.contentHtml, mute10)).toBe(second.contentHtml);
    expect(replaceEmojiInDisplayHtml(second.contentHtml, mute11)).not.toContain('cdn.example/11');
    expect(replaceEmojiInDisplayHtml(second.spoilerHtml, mute10)).toBe(second.spoilerHtml);
    expect(replaceEmojiInDisplayHtml(keptTranslation, mute11)).toBe(keptTranslation);
    expect(replaceEmojiInDisplayHtml(keptTranslation, mute10)).not.toContain('data-emoji-id="10"');
  });

  it('looks up many rules without scanning them into unrelated emoji', () => {
    const rules = [];

    for (let index = 0; index < 300; index += 1) {
      rules.push(unicodeRule(`not-emoji-${index}`, `[${index}]`));
    }

    rules.push(unicodeRule(THUMBS, '[ok]'));
    const html = `<p>${img({ alt: THUMBS, src: '/emoji/1f44d.svg' })}${img({ alt: FAMILY, src: '/emoji/family.svg' })}</p>`;
    const result = show(html, rules);

    const template = document.createElement('template');
    template.innerHTML = result;

    expect(textOf(result)).toBe('[ok]');
    expect(template.content.querySelector('img').getAttribute('alt')).toBe(FAMILY);
    expect(result).toContain('/emoji/family.svg');
    expect(result).not.toContain('not-emoji');
  });
});
