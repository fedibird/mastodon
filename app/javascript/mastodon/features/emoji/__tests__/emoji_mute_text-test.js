import { fromJS } from 'immutable';

import { EMOJI_MUTES_APPLY } from 'mastodon/actions/emoji_mutes';
import { normalizeStatus, normalizeStatusTranslation } from 'mastodon/actions/importer/normalizer';
import statusesReducer from 'mastodon/reducers/statuses';

import emojify from '../emoji';
import {
  buildReplaceInTextIndex,
  emojiMuteTextParseCount,
  emojiMutedPlainLabel,
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
    const translated = normalizeStatusTranslation({
      content: '<p>Bonjour :blob:</p>',
      spoiler_text: 'Alerte :blob:',
      detected_source_language: 'en',
      language: 'fr',
      provider: 'test',
    }, fromJS(first), '');
    const stored = fromJS(first).set('translation', fromJS(translated)).set('translationMode', 'translated');
    const second = normalizeStatus({ ...base, emojis: [localEmoji('11')] }, stored, '');
    const third = normalizeStatus({ ...base, emojis: [localEmoji('11')] }, fromJS(second), '');
    const legacy = normalizeStatus({ ...base, emojis: [localEmoji('11')] }, fromJS(first).set('translation', fromJS({
      contentHtml: first.contentHtml,
      spoilerHtml: first.spoilerHtml,
      language: 'fr',
    })).set('translationMode', 'translated'), '');
    const mute10 = buildReplaceInTextIndex([rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '[old]')]);
    const mute11 = buildReplaceInTextIndex([rule({ kind: 'custom', scope: 'local', custom_emoji_id: '11', shortcode: 'blob' }, '[new]')]);
    const refreshedTranslation = second.translation.contentHtml;
    const refreshedSpoiler = second.translation.spoilerHtml;

    expect(second.contentHtml).not.toBe(first.contentHtml);
    expect(second.contentHtml).toContain('data-emoji-id="11"');
    expect(second.contentHtml).not.toContain('data-emoji-id="10"');
    expect(second.spoilerHtml).toContain('data-emoji-id="11"');
    expect(refreshedTranslation).toContain('data-emoji-id="11"');
    expect(refreshedTranslation).not.toContain('data-emoji-id="10"');
    expect(refreshedSpoiler).toContain('data-emoji-id="11"');
    expect(second.translationMode).toBe('translated');
    expect(third.translation.get('contentHtml')).toBe(refreshedTranslation);
    expect(legacy.translation).toBeUndefined();
    expect(legacy.translationMode).toBeUndefined();
    expect(legacy.contentHtml).toContain('data-emoji-id="11"');

    expect(replaceEmojiInDisplayHtml(second.contentHtml, mute10)).toBe(second.contentHtml);
    expect(replaceEmojiInDisplayHtml(second.contentHtml, mute11)).not.toContain('cdn.example/11');
    expect(replaceEmojiInDisplayHtml(refreshedTranslation, mute10)).toBe(refreshedTranslation);
    expect(replaceEmojiInDisplayHtml(refreshedTranslation, mute11)).not.toContain('cdn.example/11');
    expect(replaceEmojiInDisplayHtml(first.contentHtml, mute11)).toBe(first.contentHtml);
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

describe('emojiMutedPlainLabel', () => {
  beforeEach(() => {
    resetEmojiMuteTextForTests();
  });

  it('replaces an emoji inside its link without keeping the shortcode title', () => {
    const html = '<p><a class="custom-emoji-url-link" href="https://remote.example/emoji/blob" data-shortcode="blob" data-domain="remote.example" title=":blob:" aria-label="blob at remote.example"><img draggable="false" class="emojione custom-emoji" alt=":blob:" title="blob" src="https://cdn.example/blob.svg" data-shortcode="blob" data-domain="remote.example" data-original="https://cdn.example/blob.svg"></a></p>';
    const result = show(html, [rule({ kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'blob' }, '［絵文字］')]);
    const template = document.createElement('template');
    template.innerHTML = result;
    const link = template.content.querySelector('a');

    expect(template.content.querySelector('img')).toBeNull();
    expect(link.getAttribute('title')).toBe('［絵文字］');
    expect(link.getAttribute('aria-label')).toBeNull();
    expect(link.getAttribute('href')).toBe('https://remote.example/emoji/blob');
    expect(result).not.toContain('cdn.example');
    expect(result).not.toContain('alt=');
    expect(link.getAttribute('title')).not.toContain('blob');
    expect(link.getAttribute('title')).not.toContain('remote.example');
  });

  it('scrubs only the muted emoji when another image remains in the link', () => {
    const html = '<p><a class="custom-emoji-url-link" href="https://remote.example/emoji/blob" data-shortcode="blob" data-domain="remote.example" title=":blob:" aria-label="blob"><img draggable="false" class="emojione custom-emoji" alt=":blob:" title="blob" src="https://cdn.example/blob.svg" data-shortcode="blob" data-domain="remote.example"><img draggable="false" class="emojione custom-emoji" alt=":other:" title="other" src="https://cdn.example/other.svg" data-shortcode="other" data-domain="other.example"></a></p>';
    const result = show(html, [rule({ kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'blob' }, '[safe]')]);
    const template = document.createElement('template');
    template.innerHTML = result;
    const link = template.content.querySelector('a');
    const kept = template.content.querySelector('img');

    expect(template.content.querySelectorAll('img')).toHaveLength(1);
    expect(kept.getAttribute('data-shortcode')).toBe('other');
    expect(kept.getAttribute('src')).toBe('https://cdn.example/other.svg');
    expect(link.getAttribute('title')).toBe('[safe]');
    expect(link.getAttribute('aria-label')).toBeNull();
    expect(link.getAttribute('href')).toBe('https://remote.example/emoji/blob');
    expect(link.getAttribute('data-shortcode')).toBe('blob');
    expect(link.getAttribute('data-domain')).toBe('remote.example');
  });

  it('keeps an unrelated label and the other emoji when only one local id is muted', () => {
    const html = '<p><a class="custom-emoji-url-link" href="https://example.test/emoji/cat" data-shortcode="cat" title="category" aria-label="See the category"><img draggable="false" class="emojione custom-emoji" alt=":cat:" title="cat" src="https://cdn.example/4.svg" data-shortcode="cat" data-domain="" data-emoji-id="4"><img draggable="false" class="emojione custom-emoji" alt=":blob:" title="blob" src="https://cdn.example/remote/blob.svg" data-shortcode="blob" data-domain="remote.example"></a></p>';
    const result = show(html, [rule({ kind: 'custom', scope: 'local', custom_emoji_id: '4', shortcode: 'cat' }, '[cat]')]);
    const template = document.createElement('template');
    template.innerHTML = result;
    const link = template.content.querySelector('a');

    expect(template.content.querySelector('[data-emoji-id="4"]')).toBeNull();
    expect(template.content.querySelector('[data-domain="remote.example"]')).not.toBeNull();
    expect(link.getAttribute('title')).toBe('category');
    expect(link.getAttribute('aria-label')).toBe('See the category');
    expect(link.getAttribute('href')).toBe('https://example.test/emoji/cat');
  });

  it('does not treat another local id with the same shortcode as the muted row', () => {
    const html = '<p><a class="custom-emoji-url-link" href="https://example.test/emoji/blob" data-shortcode="blob" title=":blob:" aria-label="blob"><img draggable="false" class="emojione custom-emoji" alt=":blob:" src="https://cdn.example/10.svg" data-shortcode="blob" data-domain="" data-emoji-id="10"><img draggable="false" class="emojione custom-emoji" alt=":blob:" src="https://cdn.example/11.svg" data-shortcode="blob" data-domain="" data-emoji-id="11"></a></p>';
    const muted = id => show(html, [rule({ kind: 'custom', scope: 'local', custom_emoji_id: id, shortcode: 'blob' }, '[safe]')]);
    const read = result => {
      const template = document.createElement('template');
      template.innerHTML = result;
      return template.content.querySelector('a');
    };
    const mute10 = read(muted('10'));
    const mute11 = read(muted('11'));

    expect(mute10.querySelector('[data-emoji-id="10"]')).toBeNull();
    expect(mute10.querySelector('[data-emoji-id="11"]').getAttribute('src')).toBe('https://cdn.example/11.svg');
    expect(mute10.getAttribute('title')).toBe('[safe]');
    expect(mute10.getAttribute('aria-label')).toBeNull();
    expect(mute10.getAttribute('href')).toBe('https://example.test/emoji/blob');
    expect(mute11.querySelector('[data-emoji-id="11"]')).toBeNull();
    expect(mute11.querySelector('[data-emoji-id="10"]')).not.toBeNull();
    expect(mute11.getAttribute('title')).toBe('[safe]');
  });

  it('replaces one unicode sequence inside a label and leaves a longer sequence', () => {
    const bang = '\u2757';
    const bangVs = '\u2757\uFE0F';
    const html = `<p><a href="https://example.test/react" title="reaction ${THUMBS}" aria-label="thumbs up ${THUMBS} category"><img class="emojione" alt="${THUMBS}" src="/emoji/1f44d.svg"></a><a href="https://example.test/keep" title="category" aria-label="keep ${THUMBS_LIGHT}"><img class="emojione" alt="${THUMBS_LIGHT}" src="/emoji/skin.svg"></a><a href="https://example.test/vs" title="see ${bangVs} and ${bang}"><img class="emojione" alt="${bang}" src="/emoji/2757.svg"></a><a href="https://example.test/family" title="hi ${FAMILY} and ${PERSON}"><img class="emojione" alt="${PERSON}" src="/emoji/person.svg"></a></p>`;
    const result = show(html, [unicodeRule(THUMBS, '[ok]'), unicodeRule(bang, '[one]'), unicodeRule(PERSON, '[person]')]);
    const template = document.createElement('template');
    template.innerHTML = result;
    const links = template.content.querySelectorAll('a');

    expect(links[0].querySelector('img')).toBeNull();
    expect(links[0].getAttribute('title')).toBe('reaction [ok]');
    expect(links[0].getAttribute('aria-label')).toBe('thumbs up [ok] category');
    expect(links[0].getAttribute('href')).toBe('https://example.test/react');
    expect(links[1].querySelector('img').getAttribute('alt')).toBe(THUMBS_LIGHT);
    expect(links[1].getAttribute('title')).toBe('category');
    expect(links[1].getAttribute('aria-label')).toBe(`keep ${THUMBS_LIGHT}`);
    expect(links[2].getAttribute('title')).toBe(`see ${bangVs} and [one]`);
    expect(links[3].getAttribute('title')).toBe(`hi ${FAMILY} and [person]`);
  });

  it('keeps the original plain text when nothing was replaced', () => {
    const plain = `Hello ${THUMBS} :blob:`;
    const html = `<p>Hello ${img({ alt: THUMBS, src: '/emoji/1f44d.svg' })}</p>`;

    expect(emojiMutedPlainLabel(plain, html, buildReplaceInTextIndex([]))).toBe(plain);
    expect(emojiMutedPlainLabel(plain, html, buildReplaceInTextIndex([
      unicodeRule(FAMILY, '[family]'),
    ]))).toBe(plain);
  });

  it('drops a muted glyph, shortcode, and image URL from the label', () => {
    const plain = `Mood ${THUMBS} :blob:`;
    const html = `<p>Mood ${img({ alt: THUMBS, src: '/emoji/1f44d.svg' })} ${img({
      alt: ':blob:',
      src: 'https://cdn.example/10.svg',
      extra: ' data-shortcode="blob" data-domain="" data-emoji-id="10" data-original="https://cdn.example/10.svg"',
      custom: true,
    })}</p>`;
    const index = buildReplaceInTextIndex([
      unicodeRule(THUMBS, '<img src=x>'),
      rule({ kind: 'custom', scope: 'local', custom_emoji_id: '10', shortcode: 'blob' }, '［絵文字］'),
    ]);
    const label = emojiMutedPlainLabel(plain, html, index);

    expect(label).toBe('Mood <img src=x> ［絵文字］');
    expect(label).not.toContain(THUMBS);
    expect(label).not.toContain(':blob:');
    expect(label).not.toContain('cdn.example');
    expect(emojiMutedPlainLabel(plain, html, index)).toBe(label);
  });
});
