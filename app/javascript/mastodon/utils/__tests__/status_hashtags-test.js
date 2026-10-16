import { fromJS } from 'immutable';

import { collectCopyHashtags, collectStatusHashtags, computeStatusHashtagBadges, isHashtagMenuLink, localeAwareInclude, splitTrailingHashtags, stripMatchingTrailingHashtags, trailingHashtagsEqual, uniqueHashtagsWithCaseHandling } from '../status_hashtags';

function anchor(name, { href, rel = 'tag', classes = 'mention hashtag' } = {}) {
  const url = href || `https://example.com/tags/${encodeURIComponent(name)}`;
  return `<a href="${url}" class="${classes}" rel="${rel}">#<span>${name}</span></a>`;
}

function names(result) {
  return result.hashtags.map(hashtag => hashtag.name);
}

describe('splitTrailingHashtags', () => {
  it.each([
    `<p>Hello ${anchor('one')} ${anchor('two')}</p>`,
    `<p>Hello<br>${anchor('one')} ${anchor('two')}</p>`,
    `<p>Hello\r\n${anchor('one')}</p>`,
    `<p>Hello<br>\r\n  ${anchor('one')}</p>`,
    `<p>Hello\n\n  <small>${anchor('one')}</small></p>`,
    `<p>Hello <small>\n  ${anchor('one')}\n</small></p>`,
    `<p>Hello</p>\n\n<small>${anchor('one')}</small>`,
    `<p>${anchor('one')} ${anchor('two')}</p>`,
    `<p>${anchor('one')}<br>${anchor('two')}</p>`,
    `<p>Hello ${anchor('inline')} text ${anchor('end')}</p>`,
    `<p>Hello<span class="quote-inline"><br>QT: link</span><br>${anchor('one')}</p>`,
  ])('preserves HTML without an explicit blank-line boundary: %s', html => {
    expect(splitTrailingHashtags(html)).toEqual({ html, hashtags: [] });
  });

  it.each(['<br><br>', '<br> \r\n<br>', '<br><br><br>'])('splits after explicit breaks: %s', separator => {
    const html = `<p>本文${separator}${anchor('one')} <small>${anchor('Two')}<br>${anchor('日本語')}</small> \t</p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe('<p>本文</p>');
    expect(names(result)).toEqual(['one', 'Two', '日本語']);
  });

  it('starts the run after the boundary while keeping an earlier terminal inline tag', () => {
    const html = `<p>Hello ${anchor('inline')}<br><br>${anchor('tail')}</p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe(`<p>Hello ${anchor('inline')}</p>`);
    expect(names(result)).toEqual(['tail']);
  });

  it.each([
    `<p>Hello<small><br><br>${anchor('one')}</small></p>`,
    `<p>Hello<br><small><br>${anchor('one')}</small></p>`,
    `<p>Hello<br><br><small>${anchor('one')}</small></p>`,
    `<p>Hello</p>\n  <p><small>${anchor('one')}</small></p>`,
  ])('recognizes explicit boundaries across tag-only wrappers: %s', html => {
    const result = splitTrailingHashtags(html);
    expect(result.html).toBe('<p>Hello</p>');
    expect(names(result)).toEqual(['one']);
  });

  it('drops a hashtag-only final paragraph', () => {
    const html = `<p>Hello</p><p>${anchor('one')} ${anchor('two')}</p>`;

    expect(splitTrailingHashtags(html).html).toBe('<p>Hello</p>');
    expect(names(splitTrailingHashtags(html))).toEqual(['one', 'two']);
  });

  it('keeps an inline hashtag that is followed by ordinary text', () => {
    const html = `<p>${anchor('one')} ordinary</p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe(html);
    expect(result.hashtags).toEqual([]);
  });

  it('keeps a hashtag that is followed by a URL', () => {
    const html = `<p>${anchor('one')} <a href="https://example.com/">https://example.com/</a></p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe(html);
    expect(result.hashtags).toEqual([]);
  });

  it('keeps a hashtag that is followed by a mention', () => {
    const html = `<p>${anchor('one')} <a href="https://example.com/@alice" class="u-url mention">@<span>alice</span></a></p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe(html);
    expect(result.hashtags).toEqual([]);
  });

  it('keeps a hashtag that is followed by punctuation', () => {
    const html = `<p>${anchor('one')} ,</p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe(html);
    expect(result.hashtags).toEqual([]);
  });

  it('keeps synthetic suffixes and extracts only the hashtags after them', () => {
    const html = [
      '<p>Hello',
      '<span class="quote-inline"><br>QT: <a href="https://example.com/q">https://example.com/q</a></span>',
      '<span class="original-media-link"> <a href="https://example.com/m">[Attached: 5 images]</a></span>',
      '<span class="reference-link-inline"> <a href="https://example.com/r">[Ref.]</a></span>',
      `<br><br>${anchor('one')} ${anchor('two')}`,
      '</p>',
    ].join('');
    const result = splitTrailingHashtags(html);
    const template = document.createElement('template');
    template.innerHTML = result.html;

    expect(names(result)).toEqual(['one', 'two']);
    expect(template.content.querySelector('.quote-inline')).not.toBeNull();
    expect(template.content.querySelector('.original-media-link')).not.toBeNull();
    expect(template.content.querySelector('.reference-link-inline')).not.toBeNull();
    expect(template.content.querySelector('.quote-inline br')).not.toBeNull();
    expect(template.content.querySelector('a.mention.hashtag')).toBeNull();
    expect(template.content.querySelector('p').textContent).toContain('Hello');
  });

  it('does not treat a hashtag inside a blockquote as trailing', () => {
    const html = `<blockquote><p>${anchor('one')}</p></blockquote>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe(html);
    expect(result.hashtags).toEqual([]);
  });

  it('does not treat a hashtag inside a list as trailing', () => {
    const html = `<ul><li>${anchor('one')}</li></ul>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe(html);
    expect(result.hashtags).toEqual([]);
  });

  it('does not treat a hashtag inside preformatted text as trailing', () => {
    const html = `<pre>${anchor('one')}</pre>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe(html);
    expect(result.hashtags).toEqual([]);
  });

  it('recognizes a remote hashtag whose rel was rewritten by the sanitizer', () => {
    const html = `<p>Hello<br><br>${anchor('one', { rel: 'nofollow noopener noreferrer', href: 'https://remote.test/tags/one' })}</p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe('<p>Hello</p>');
    expect(result.hashtags).toEqual([
      { name: 'one', text: '#one', href: 'https://remote.test/tags/one' },
    ]);
  });

  it('keeps duplicate trailing hashtags in order', () => {
    const html = `<p>Body<br><br>${anchor('one', { href: 'https://example.com/tags/one' })} ${anchor('one', { href: 'https://example.com/tags/one?repeat=1' })}</p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe('<p>Body</p>');
    expect(result.hashtags).toEqual([
      { name: 'one', text: '#one', href: 'https://example.com/tags/one' },
      { name: 'one', text: '#one', href: 'https://example.com/tags/one?repeat=1' },
    ]);
  });

  it('does not crash on malformed or empty HTML', () => {
    expect(splitTrailingHashtags(null)).toEqual({ html: '', hashtags: [] });
    expect(splitTrailingHashtags(undefined)).toEqual({ html: '', hashtags: [] });
    expect(splitTrailingHashtags('')).toEqual({ html: '', hashtags: [] });
    expect(() => splitTrailingHashtags('<p><a class="mention hashtag" href="')).not.toThrow();
    expect(splitTrailingHashtags('<p><a class="mention hashtag" href="').hashtags).toEqual(expect.any(Array));
  });

  it('does not execute scripts or event handlers while parsing', () => {
    window.__statusHashtagProbe = jest.fn();
    const html = `<p>Hello<br><br>${anchor('one')}<script>window.__statusHashtagProbe()</script></p><img src="x" onerror="window.__statusHashtagProbe()">`;

    expect(() => splitTrailingHashtags(html)).not.toThrow();
    expect(window.__statusHashtagProbe).not.toHaveBeenCalled();
    delete window.__statusHashtagProbe;
  });

  it('returns the original string when no hashtag class is present', () => {
    const html = '<p>Hello #one<br />#two</p>';
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe(html);
    expect(result.hashtags).toEqual([]);
  });

  it('returns the original string without reserializing when nothing is trailing', () => {
    const html = `<p>${anchor('one')} ordinary<br /></p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe(html);
    expect(result.hashtags).toEqual([]);
  });

  it('leaves an earlier inline hashtag in the body', () => {
    const html = `<p>Hello ${anchor('inline')} there<br><br>${anchor('end')}</p>`;
    const result = splitTrailingHashtags(html);
    const template = document.createElement('template');
    template.innerHTML = result.html;

    expect(names(result)).toEqual(['end']);
    expect(template.content.querySelector('a.mention.hashtag').textContent).toBe('#inline');
    expect(template.content.textContent).toBe('Hello #inline there');
  });

  it('requires both mention and hashtag classes', () => {
    const html = '<p>Hello <a href="https://example.com/tags/one" class="hashtag" rel="tag">#<span>one</span></a></p>';
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe(html);
    expect(result.hashtags).toEqual([]);
  });

  it('splits a sanitized Misskey trailing hashtag group', () => {
    const html = [
      '<p>Hello<br><br><small>',
      '  <a href="https://misskey.example/tags/one" rel="nofollow noopener noreferrer" class="mention hashtag" target="_blank">#one</a>',
      '  <a href="https://misskey.example/tags/two" rel="nofollow noopener noreferrer" class="mention hashtag" target="_blank">#two</a>',
      '</small></p>',
    ].join('\n');
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe('<p>Hello</p>');
    expect(names(result)).toEqual(['one', 'two']);
    expect(result.hashtags.map(hashtag => hashtag.text)).toEqual(['#one', '#two']);
    expect(result.hashtags.map(hashtag => hashtag.href)).toEqual([
      'https://misskey.example/tags/one',
      'https://misskey.example/tags/two',
    ]);
  });

  it('splits hashtags wrapped in an inline element', () => {
    const html = `<p>Hello<br><br><small>${anchor('one')} ${anchor('two')}</small></p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe('<p>Hello</p>');
    expect(names(result)).toEqual(['one', 'two']);
  });

  it('splits hashtags in nested inline wrappers', () => {
    const html = `<p>Hello<br><br><small>
  <span>${anchor('one')}</span> <span>${anchor('two')}</span>
</small></p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe('<p>Hello</p>');
    expect(names(result)).toEqual(['one', 'two']);
  });

  it('does not split a wrapper that also contains ordinary text', () => {
    const html = `<p>Hello<br><br><small>tags: ${anchor('one')} ${anchor('two')}</small></p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe(html);
    expect(result.hashtags).toEqual([]);
  });

  it('keeps a wrapper after a paragraph without a separate tag paragraph', () => {
    const html = `<p>Hello</p><small>${anchor('one')} ${anchor('two')}</small>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe(html);
    expect(names(result)).toEqual([]);
  });

  it('does not split a wrapped hashtag inside a blockquote', () => {
    const html = `<blockquote><small>${anchor('one')}</small></blockquote>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe(html);
    expect(result.hashtags).toEqual([]);
  });

  it('does not split a wrapper that contains an image', () => {
    const html = `<p>Hello<br><br><small><img src="https://example.com/a.png">${anchor('one')}</small></p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe(html);
    expect(result.hashtags).toEqual([]);
  });

  it('splits a Pixelfed trailing hashtag after nl2br newlines were removed', () => {
    const html = [
      'たぶんナラタケモドキ。<br><br>',
      'ジメジメとした天気が続いていたある日…<br><br>',
      '<a href="https://fedisnap.com/discover/tags/fedibird?src=hash" class="u-url hashtag mention" rel="nofollow noopener noreferrer" target="_blank">#fedibird</a>',
    ].join('');
    const result = splitTrailingHashtags(html);

    expect(result.hashtags).toEqual([
      {
        name: 'fedibird',
        text: '#fedibird',
        href: 'https://fedisnap.com/discover/tags/fedibird?src=hash',
      },
    ]);
    expect(result.html).toBe('たぶんナラタケモドキ。<br><br>ジメジメとした天気が続いていたある日…');
  });

  it('splits a sanitized Pixelfed trailing hashtag and keeps its href', () => {
    const html = [
      'たぶんナラタケモドキ。<br> <br>',
      'ジメジメとした天気が続いていたある日…<br> <br>',
      '<a href="https://fedisnap.com/discover/tags/fedibird?src=hash" class="u-url hashtag mention" rel="nofollow noopener noreferrer" target="_blank">#fedibird</a>',
    ].join('\n');
    const result = splitTrailingHashtags(html);

    expect(result.hashtags).toEqual([
      {
        name: 'fedibird',
        text: '#fedibird',
        href: 'https://fedisnap.com/discover/tags/fedibird?src=hash',
      },
    ]);
    expect(result.html).toBe('たぶんナラタケモドキ。<br> <br>\nジメジメとした天気が続いていたある日…');
    expect(result.html).not.toContain('<a');
    expect(result.html.match(/<br>/g)).toHaveLength(2);
  });
});

describe('collectStatusHashtags', () => {
  it('collects mention hashtags in document order and drops later duplicates', () => {
    const html = [
      `<p>Hello ${anchor('test')} and ${anchor('mastodon')} ${anchor('Test')}</p>`,
      `<p>${anchor('fedibird')} ${anchor('Ａ')} ${anchor('A')}</p>`,
    ].join('');

    expect(collectStatusHashtags(html).map(hashtag => hashtag.text)).toEqual([
      '#test',
      '#mastodon',
      '#fedibird',
      '#Ａ',
    ]);
  });

  it('keeps the first spelling after NFKC case-insensitive comparison', () => {
    const html = `<p>${anchor('Test')} ${anchor('test')} ${anchor('TEST')}</p>`;

    expect(collectStatusHashtags(html)).toEqual([
      expect.objectContaining({ name: 'Test', text: '#Test' }),
    ]);
  });

  it('collects the same links that open the hashtag menu', () => {
    const html = [
      '<p>',
      '<a class="hashtag" href="https://example.com/tags/one">#one</a> ',
      '<a href="https://example.com/tags/two">＃two</a> ',
      '#<a href="https://example.com/tags/three">three</a> ',
      '<a href="https://example.com/">link</a>',
      '</p>',
    ].join('');

    expect(collectStatusHashtags(html).map(hashtag => hashtag.text)).toEqual([
      '#one',
      '#two',
      '#three',
    ]);
  });

  it('ignores ordinary links', () => {
    const html = '<p>See <a href="https://example.com/">the docs</a> today</p>';

    expect(collectStatusHashtags(html)).toEqual([]);
    expect(isHashtagMenuLink(null)).toBe(false);
  });

  it('does not execute scripts while collecting hashtags', () => {
    window.__statusHashtagProbe = jest.fn();
    const html = `<p>${anchor('one')}<script>window.__statusHashtagProbe()</script></p>`;

    expect(collectStatusHashtags(html).map(hashtag => hashtag.text)).toEqual(['#one']);
    expect(window.__statusHashtagProbe).not.toHaveBeenCalled();
    delete window.__statusHashtagProbe;
  });
});

describe('trailing hashtag translation matching', () => {
  const source = `<p>Hello<br><br>${anchor('one')} ${anchor('two')}</p>`;
  const matchingTarget = `<p>こんにちは<br><br>${anchor('one')} ${anchor('two')}</p>`;

  it('removes a target run that matches the source run', () => {
    const sourceParts = splitTrailingHashtags(source);
    const targetHtml = stripMatchingTrailingHashtags(sourceParts.hashtags, matchingTarget);

    expect(trailingHashtagsEqual(sourceParts.hashtags, splitTrailingHashtags(matchingTarget).hashtags)).toBe(true);
    expect(targetHtml).toBe('<p>こんにちは</p>');
  });

  it('matches hashtag names case-insensitively', () => {
    const sourceParts = splitTrailingHashtags(`<p>Body<br><br>${anchor('One')}</p>`);
    const target = `<p>訳<br><br>${anchor('one')}</p>`;

    expect(trailingHashtagsEqual(sourceParts.hashtags, splitTrailingHashtags(target).hashtags)).toBe(true);
    expect(stripMatchingTrailingHashtags(sourceParts.hashtags, target)).toBe('<p>訳</p>');
  });

  it('matches hashtag names after NFKC normalization', () => {
    const sourceParts = splitTrailingHashtags(`<p>Body<br><br>${anchor('Ａ')}</p>`);
    const target = `<p>訳<br><br>${anchor('A')}</p>`;

    expect(trailingHashtagsEqual(sourceParts.hashtags, splitTrailingHashtags(target).hashtags)).toBe(true);
  });

  it('does not rewrite target HTML when the trailing run differs', () => {
    const sourceParts = splitTrailingHashtags(source);
    const target = `<p>こんにちは<br><br>${anchor('one')} ${anchor('different')}</p>`;
    const result = stripMatchingTrailingHashtags(sourceParts.hashtags, target);

    expect(trailingHashtagsEqual(sourceParts.hashtags, splitTrailingHashtags(target).hashtags)).toBe(false);
    expect(result).toBe(target);
  });

  it('strips matching trailing hashtags when both runs are wrapped', () => {
    const source = `<p>Hello<br><br><small>${anchor('one')} ${anchor('two')}</small></p>`;
    const target = `<p>こんにちは<br><br><span><span>${anchor('one')}</span> <span>${anchor('two')}</span></span></p>`;
    const sourceParts = splitTrailingHashtags(source);

    expect(names(sourceParts)).toEqual(['one', 'two']);
    expect(stripMatchingTrailingHashtags(sourceParts.hashtags, target)).toBe('<p>こんにちは</p>');
  });

  it('does not split a target run when the source has no badges', () => {
    const sourceParts = splitTrailingHashtags('<p>Hello</p>');
    const target = `<p>こんにちは<br><br>${anchor('one')}</p>`;

    expect(sourceParts.hashtags).toEqual([]);
    expect(stripMatchingTrailingHashtags(sourceParts.hashtags, target)).toBe(target);
  });
});

describe('hashtag comparison', () => {
  it('matches case and NFKC with a base collator', () => {
    expect(localeAwareInclude(['FediBird'], 'fedibird')).toBe(true);
    expect(localeAwareInclude(['Ａ'], 'a')).toBe(true);
    expect(localeAwareInclude(['foo'], 'bar')).toBe(false);
    expect(localeAwareInclude([], 'foo')).toBe(false);
  });

  it('keeps the mixed-case spelling when several casings are grouped', () => {
    expect(uniqueHashtagsWithCaseHandling(['foo', 'Foo', 'FOO'])).toEqual(['Foo']);
    expect(uniqueHashtagsWithCaseHandling(['alpha', 'beta'])).toEqual(['alpha', 'beta']);
  });
});

function textOf(html) {
  const template = document.createElement('template');
  template.innerHTML = html;

  return template.content.textContent;
}

describe('computeStatusHashtagBadges', () => {
  const tags = (...names) => names.map(name => ({
    name,
    url: `https://example.com/tags/${encodeURIComponent(name)}`,
  }));

  it.each([' ', '<br>', '\r\n', '<br>\n\n'])('keeps terminal inline tags and only badges out-of-band tags: %s', separator => {
    const html = `<p>Hello${separator}${anchor('One')} ${anchor('Ａ')}</p>`;
    const result = computeStatusHashtagBadges(html, tags('one', 'a', 'hidden'));
    const target = `<p>訳<br><br>${anchor('One')} ${anchor('Ａ')}</p>`;

    expect(result.html).toBe(html);
    expect(result.trailing).toEqual([]);
    expect(result.hashtags.map(hashtag => hashtag.name)).toEqual(['hidden']);
    expect(stripMatchingTrailingHashtags(result.trailing, target)).toBe(target);
  });

  it('keeps a mid-body hashtag and badges only the out-of-band tag', () => {
    const html = `<p>Simple text ${anchor('hashtag')} continues</p>`;
    const result = computeStatusHashtagBadges(html, tags('hashtag', 'test'));

    expect(result.html).toBe(html);
    expect(result.hashtags).toEqual([
      { name: 'test', text: '#test', href: 'https://example.com/tags/test' },
    ]);
    expect(result.trailing).toEqual([]);
  });

  it('lifts an explicitly separated trailing hashtag and still badges the out-of-band tag first', () => {
    const result = computeStatusHashtagBadges(
      `<p>Simple text<br><br>${anchor('hashtag')}</p>`,
      tags('hashtag', 'test'),
    );

    expect(result.html).toBe('<p>Simple text</p>');
    expect(result.hashtags.map(hashtag => hashtag.text)).toEqual(['#test', '#hashtag']);
    expect(result.hashtags[1].href).toBe('https://example.com/tags/hashtag');
  });

  it('does not badge a tag that remains visible in the body', () => {
    const html = `<p>本文 ${anchor('foo')} です</p>`;
    const result = computeStatusHashtagBadges(html, tags('foo'));

    expect(result.html).toBe(html);
    expect(result.hashtags).toEqual([]);
  });

  it('removes a repeated trailing tag and does not badge it when the body still shows it', () => {
    const html = `<p>本文 ${anchor('foo')} です<br><br>${anchor('foo')}</p>`;
    const result = computeStatusHashtagBadges(html, tags('foo'));

    expect(result.html).toBe(`<p>本文 ${anchor('foo')} です</p>`);
    expect(result.hashtags).toEqual([]);
    expect(result.trailing.map(hashtag => hashtag.name)).toEqual(['foo']);
    expect(stripMatchingTrailingHashtags(result.trailing, `<p>訳<br><br>${anchor('foo')}</p>`)).toBe('<p>訳</p>');
  });

  it('orders out-of-band tags before a trailing tag that is not still in the body', () => {
    const html = `<p>${anchor('body')} を含む<br><br>${anchor('tail')}</p>`;
    const result = computeStatusHashtagBadges(html, tags('body', 'tail', 'hidden'));

    expect(textOf(result.html)).toContain('#body');
    expect(textOf(result.html)).not.toContain('#tail');
    expect(result.hashtags.map(hashtag => hashtag.text)).toEqual(['#hidden', '#tail']);
    expect(result.hashtags[0].href).toBe('https://example.com/tags/hidden');
    expect(result.hashtags[1].href).toBe('https://example.com/tags/tail');
  });

  it('still badges a Misskey trailing hashtag that status.tags does not list', () => {
    const html = [
      '<p>Hello<br><br><small>',
      '  <a href="https://misskey.example/tags/one" rel="nofollow noopener noreferrer" class="mention hashtag" target="_blank">#one</a>',
      '</small></p>',
    ].join('\n');
    const result = computeStatusHashtagBadges(html, tags('other'));

    expect(result.html).toBe('<p>Hello</p>');
    expect(result.hashtags.map(hashtag => hashtag.text)).toEqual(['#other', '#one']);
    expect(result.hashtags[1].href).toBe('https://misskey.example/tags/one');
  });

  it('still badges a Pixelfed trailing hashtag that status.tags does not list', () => {
    const html = [
      'たぶんナラタケモドキ。<br><br>',
      '<a href="https://fedisnap.com/discover/tags/fedibird?src=hash" class="u-url hashtag mention" rel="nofollow noopener noreferrer" target="_blank">#fedibird</a>',
    ].join('');
    const result = computeStatusHashtagBadges(html, []);

    expect(result.hashtags).toEqual([
      {
        name: 'fedibird',
        text: '#fedibird',
        href: 'https://fedisnap.com/discover/tags/fedibird?src=hash',
      },
    ]);
  });

  it('does not duplicate a tag that differs only by case or NFKC', () => {
    const trailing = computeStatusHashtagBadges(`<p>Hello<br><br>${anchor('FediBird')}</p>`, tags('fedibird'));
    const fullwidth = computeStatusHashtagBadges(`<p>${anchor('Ａ')} text</p>`, tags('a', 'extra'));
    const repeated = computeStatusHashtagBadges(
      `<p>この話は ${anchor('FediBird')} についてです<br><br>${anchor('fedibird')}</p>`,
      fromJS(tags('FEDIBIRD')),
    );

    expect(trailing.hashtags.map(hashtag => hashtag.text)).toEqual(['#FediBird']);
    expect(textOf(fullwidth.html)).toContain('#Ａ');
    expect(fullwidth.hashtags.map(hashtag => hashtag.text)).toEqual(['#extra']);
    expect(textOf(repeated.html)).toBe('この話は #FediBird についてです');
    expect(repeated.hashtags).toEqual([]);
  });

  it('badges a fullwidth trailing hash once when status.tags lists the same name', () => {
    const href = 'https://remote.example/tags/foo';
    const html = `<p>本文<br><br><a href="${href}" class="mention hashtag" rel="tag">＃foo</a></p>`;
    const result = computeStatusHashtagBadges(html, [
      { name: 'foo', url: 'https://example.com/tags/foo' },
    ]);

    expect(result.html).toBe('<p>本文</p>');
    expect(result.hashtags).toEqual([
      { name: 'foo', text: '＃foo', href },
    ]);
  });

  it('keeps the mixed-case trailing spelling and its href when casings repeat', () => {
    const html = `<p>Hello<br><br>${anchor('foo', { href: 'https://example.com/tags/foo' })} ${anchor('Foo', { href: 'https://example.com/tags/Foo' })} ${anchor('FOO', { href: 'https://example.com/tags/FOO' })}</p>`;
    const result = computeStatusHashtagBadges(html, [
      { name: 'foo', url: 'https://api.example/tags/foo' },
    ]);

    expect(result.html).toBe('<p>Hello</p>');
    expect(result.hashtags).toEqual([
      { name: 'Foo', text: '#Foo', href: 'https://example.com/tags/Foo' },
    ]);
    expect(result.trailing).toHaveLength(3);
  });

  it('picks the mixed-case accented spelling Mastodon keeps for the bar', () => {
    const html = `<p>Body<br><br>${anchor('éaa', { href: 'https://example.com/tags/lower' })} ${anchor('Éaa', { href: 'https://example.com/tags/mixed' })}</p>`;
    const result = computeStatusHashtagBadges(html, [
      { name: 'éaa', url: 'https://api.example/tags/eaa' },
    ]);

    expect(result.hashtags).toEqual([
      { name: 'Éaa', text: '#Éaa', href: 'https://example.com/tags/mixed' },
    ]);
  });

  it('does not badge a trailing casing when the body already shows that tag', () => {
    const html = `<p>See ${anchor('test')} today<br><br>${anchor('mastodon')} ${anchor('Test')} ${anchor('fedibird')}</p>`;
    const result = computeStatusHashtagBadges(html, []);

    expect(textOf(result.html)).toBe('See #test today');
    expect(result.hashtags.map(hashtag => hashtag.text)).toEqual(['#mastodon', '#fedibird']);
  });

  it('reads Immutable status tags and ignores a missing tag list', () => {
    const html = `<p>Hello<br><br>${anchor('one')}</p>`;

    expect(computeStatusHashtagBadges(html, fromJS([
      { name: '#hidden', url: 'https://example.com/tags/hidden' },
    ])).hashtags.map(hashtag => hashtag.text)).toEqual(['#hidden', '#one']);
    expect(computeStatusHashtagBadges(html).hashtags.map(hashtag => hashtag.text)).toEqual(['#one']);
    expect(computeStatusHashtagBadges(null, tags('only'))).toEqual({
      html: '',
      hashtags: [{ name: 'only', text: '#only', href: 'https://example.com/tags/only' }],
      trailing: [],
    });
  });
});

describe('collectCopyHashtags', () => {
  it('appends status tags that are not already visible, in API order', () => {
    const html = `<p>${anchor('foo')}</p>`;

    expect(collectCopyHashtags(html, [
      { name: 'foo', url: 'https://example.com/tags/foo' },
      { name: 'bar', url: 'https://example.com/tags/bar' },
    ]).map(hashtag => hashtag.text)).toEqual(['#foo', '#bar']);
  });

  it('keeps the visible spelling when the API name differs only by case or NFKC', () => {
    const html = `<p>${anchor('FediBird')} ${anchor('Ａ')}</p>`;

    expect(collectCopyHashtags(html, fromJS([
      { name: 'fedibird', url: 'https://example.com/tags/fedibird' },
      { name: 'a', url: 'https://example.com/tags/a' },
      { name: 'bar', url: 'https://example.com/tags/bar' },
    ])).map(hashtag => hashtag.text)).toEqual(['#FediBird', '#Ａ', '#bar']);
  });
});
