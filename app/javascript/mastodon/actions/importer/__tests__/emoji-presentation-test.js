import { fromJS } from 'immutable';

import { computeStatusHashtagBadges } from 'mastodon/utils/status_hashtags';

import { normalizeStatus, normalizeStatusTranslation } from '../normalizer';

const mention = '<span class="h-card"><a href="https://example.com/@user" class="u-url mention">@<span>user</span></a></span>';
const hashtag = '<a href="https://example.com/tags/fedibird" class="mention hashtag" rel="tag">#<span>fedibird</span></a>';
const url = '<a href="https://example.com/path"><span class="invisible">https://</span><span class="ellipsis">example.com/path</span><span class="invisible"></span></a>';

const buildStatus = (content, overrides = {}) => ({
  id: '1',
  account: { id: 'a', acct: 'alice' },
  content,
  spoiler_text: '',
  emojis: [],
  media_attachments: [],
  mentions: [],
  tags: [],
  visibility: 'public',
  sensitive: false,
  language: 'ja',
  url: 'https://example.com/1',
  uri: 'https://example.com/1',
  updated_at: '2020-01-01T00:00:00.000Z',
  quote: null,
  ...overrides,
});

const presentations = (html) => {
  const doc = new DOMParser().parseFromString(html, 'text/html');
  const nodes = doc.querySelectorAll('[class*="emoji-"]');
  const found = [];

  for (let i = 0; i < nodes.length; i += 1) {
    const element = nodes[i];
    const presentation = (element.getAttribute('class') || '').split(/\s+/).find(className => className.indexOf('emoji-') === 0);
    if (presentation) found.push(`${element.tagName.toLowerCase()}.${presentation}`);
  }

  return found;
};

const normalizeHtml = (content, overrides) => normalizeStatus(buildStatus(content, overrides), null, '').contentHtml;

describe('emoji presentation paragraphs', () => {
  it('gives a lone emoji the single size, including surrounding whitespace', () => {
    expect(presentations(normalizeHtml('<p>😀</p>'))).toEqual(['p.emoji-single']);
    expect(presentations(normalizeHtml('<p> 😀 </p>'))).toEqual(['p.emoji-single']);
    expect(presentations(normalizeHtml('<p>\n😀\n</p>'))).toEqual(['p.emoji-single']);
    expect(presentations(normalizeHtml('<p>😀<br>\n</p>'))).toEqual(['p.emoji-single']);
    expect(presentations(normalizeHtml('<p>&nbsp;😀</p>'))).toEqual(['p.emoji-single']);
    expect(presentations(normalizeHtml('<p>\u3000😀</p>'))).toEqual(['p.emoji-single']);
    expect(presentations(normalizeHtml('<p>\u200B😀</p>'))).toEqual(['p.emoji-single']);
  });

  it('keeps a 3x3 emoji grid on the multi size across spaces, breaks, and newline text', () => {
    const grid = '<p>😀 😀 😀<br>😀 😀 😀<br>😀 😀 😀</p>';
    const gridWithPixelfedNewlines = '<p>😀 😀 😀<br>\n😀 😀 😀<br>\n😀 😀 😀</p>';
    const gridWithNewlineText = '<p>😀 😀 😀\n😀 😀 😀\n😀 😀 😀</p>';

    expect(presentations(normalizeHtml(grid))).toEqual(['p.emoji-multi']);
    expect(presentations(normalizeHtml(gridWithPixelfedNewlines))).toEqual(['p.emoji-multi']);
    expect(presentations(normalizeHtml(gridWithNewlineText))).toEqual(['p.emoji-multi']);
    expect(presentations(normalizeHtml('<p>😀 😀</p>'))).toEqual(['p.emoji-multi']);
    expect(presentations(normalizeHtml('<p>😀<br>😀<br>😀</p>'))).toEqual(['p.emoji-multi']);
  });

  it('does not enlarge emoji that share a paragraph with a sentence', () => {
    expect(presentations(normalizeHtml('<p>hello 😀</p>'))).toEqual(['p.emoji-other']);
    expect(presentations(normalizeHtml('<p>hello<br>😀</p>'))).toEqual(['p.emoji-other']);
    expect(presentations(normalizeHtml('<p>hello<br>\n😀</p>'))).toEqual(['p.emoji-other']);
    expect(presentations(normalizeHtml('<p><span>hello</span> 😀</p>'))).toEqual(['p.emoji-other']);
  });

  it('keeps a mention and the emoji on the next line in one mixed paragraph', () => {
    expect(presentations(normalizeHtml(`<p>${mention} 😀</p>`))).toEqual(['p.emoji-mix']);
    expect(presentations(normalizeHtml(`<p>${mention}<br>😀</p>`))).toEqual(['p.emoji-mix']);
    // The newline Pixelfed nl2br leaves after <br> used to count as prose.
    const withNewline = normalizeHtml(`<p>${mention}<br>\n😀</p>`);
    const host = document.createElement('div');
    host.className = 'status__content__text';
    host.innerHTML = withNewline;

    expect(presentations(withNewline)).toEqual(['p.emoji-mix']);
    expect(host.querySelector('p').classList.contains('emoji-mix')).toBe(true);
    expect(host.querySelector('.emoji-single')).toBeNull();
    expect(host.querySelector('a.mention').getAttribute('href')).toBe('https://example.com/@user');
    expect(presentations(normalizeHtml(`<p>${mention}\n😀</p>`))).toEqual(['p.emoji-mix']);
  });

  it('does not merge a mention into the emoji paragraph after a blank line or a new p', () => {
    expect(presentations(normalizeHtml(`<p>${mention}</p><p>😀</p>`))).toEqual(['p.emoji-single']);
    expect(presentations(normalizeHtml(`<p>${mention}<br><br>😀</p>`))).toEqual(['span.emoji-single']);
    expect(presentations(normalizeHtml(`<p>${mention}<br>\n<br>\n😀</p>`))).toEqual(['span.emoji-single']);
    expect(presentations(normalizeHtml(`<p>${mention}\n\n😀</p>`))).toEqual(['span.emoji-single']);

    const separated = new DOMParser().parseFromString(normalizeHtml(`<p>${mention}<br><br>😀</p>`), 'text/html');
    const emoji = separated.querySelector('.emoji-single');

    expect(emoji.querySelector('img.emojione').getAttribute('alt')).toBe('😀');
    expect(emoji.querySelector('a')).toBeNull();
    expect(separated.querySelector('a.mention')).not.toBeNull();
  });

  it('uses the mix size for emoji beside a hashtag or a URL in the same paragraph', () => {
    expect(presentations(normalizeHtml(`<p>😀 ${hashtag}</p>`))).toEqual(['p.emoji-mix']);
    expect(presentations(normalizeHtml(`<p>😀<br>${hashtag}</p>`))).toEqual(['p.emoji-mix']);
    expect(presentations(normalizeHtml(`<p>😀<br>\n${hashtag}</p>`))).toEqual(['p.emoji-mix']);
    expect(presentations(normalizeHtml(`<p>😀 ${url}</p>`))).toEqual(['p.emoji-mix']);
    expect(presentations(normalizeHtml(`<p>${url}<br>😀</p>`))).toEqual(['p.emoji-mix']);
  });

  it('classifies Pixelfed HTML that has no paragraphs the same way before and after nl2br cleanup', () => {
    const before = `${mention}<br>\n😀`;
    const after = `${mention}<br>😀`;

    expect(presentations(normalizeHtml(before))).toEqual(['span.emoji-mix']);
    expect(presentations(normalizeHtml(after))).toEqual(['span.emoji-mix']);
    expect(presentations(normalizeHtml('😀'))).toEqual(['span.emoji-single']);
    expect(presentations(normalizeHtml('😀<br>😀<br>😀'))).toEqual(['span.emoji-multi']);
    expect(presentations(normalizeHtml('😀<br>\n😀<br>\n😀'))).toEqual(['span.emoji-multi']);
    expect(presentations(normalizeHtml(`${mention}<br><br>😀`))).toEqual(['span.emoji-single']);
    expect(presentations(normalizeHtml('hello 😀'))).toEqual(['span.emoji-other']);
    expect(presentations(normalizeHtml(`hello<br><br>😀 ${hashtag}`))).toEqual(['span.emoji-mix']);
  });

  it('counts an emoji wrapped in picture and keeps anchors intact', () => {
    const html = normalizeHtml('<p><picture><img class="emojione" alt="😀" src="/emoji/1f600.svg"></picture></p>');
    const doc = new DOMParser().parseFromString(html, 'text/html');

    expect(presentations(html)).toEqual(['p.emoji-single']);
    expect(doc.querySelector('picture img.emojione')).not.toBeNull();
  });

  it('leaves sentences without emoji unmarked and does not rewrite mention hrefs', () => {
    const html = normalizeHtml(`<p>${mention}<br>hello</p>`);
    const doc = new DOMParser().parseFromString(html, 'text/html');

    expect(presentations(html)).toEqual([]);
    expect(doc.querySelector('a.mention').getAttribute('href')).toBe('https://example.com/@user');
    expect(doc.body.textContent).toContain('@user');
    expect(doc.body.textContent).toContain('hello');
  });

  it('still splits a trailing hashtag after a blank line when the emoji line is classified', () => {
    const html = normalizeHtml(`<p>たぶんナラタケモドキ。<br><br>😀<br><br>${hashtag}</p>`);
    const split = computeStatusHashtagBadges(html, []);

    expect(presentations(html)).toEqual(['span.emoji-single']);
    expect(split.hashtags.map(tag => tag.name)).toEqual(['fedibird']);
    expect(split.html).toContain('emoji-single');
    expect(split.html).toContain('たぶんナラタケモドキ。');
    expect(split.html).not.toContain('fedibird');
  });

  it('classifies a CW-only post from the spoiler that is shown as the body', () => {
    const html = normalizeHtml('', { spoiler_text: '😀' });

    expect(presentations(html)).toEqual(['span.emoji-single']);
  });

  it('classifies translated HTML with the same paragraph rules', () => {
    const status = fromJS({ emojis: [], spoiler_text: '' });
    const single = normalizeStatusTranslation({ content: '<p>😀</p>', spoiler_text: '' }, status);
    const mixed = normalizeStatusTranslation({ content: `<p>${mention}<br>\n😀</p>`, spoiler_text: '' }, status);
    const separate = normalizeStatusTranslation({ content: `<p>${mention}</p><p>😀</p>`, spoiler_text: '' }, status);

    expect(presentations(single.contentHtml)).toEqual(['p.emoji-single']);
    expect(presentations(mixed.contentHtml)).toEqual(['p.emoji-mix']);
    expect(presentations(separate.contentHtml)).toEqual(['p.emoji-single']);
  });
});
