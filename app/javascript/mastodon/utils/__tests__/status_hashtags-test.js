import { splitTrailingHashtags, stripMatchingTrailingHashtags, trailingHashtagsEqual } from '../status_hashtags';

function anchor(name, { href, rel = 'tag', classes = 'mention hashtag' } = {}) {
  const url = href || `https://example.com/tags/${encodeURIComponent(name)}`;
  return `<a href="${url}" class="${classes}" rel="${rel}">#<span>${name}</span></a>`;
}

function names(result) {
  return result.hashtags.map(hashtag => hashtag.name);
}

describe('splitTrailingHashtags', () => {
  it('splits same-line trailing hashtags and drops the separating space', () => {
    const html = `<p>Hello ${anchor('one')} ${anchor('two')}</p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe('<p>Hello</p>');
    expect(names(result)).toEqual(['one', 'two']);
    expect(result.hashtags.map(hashtag => hashtag.text)).toEqual(['#one', '#two']);
    expect(result.hashtags.map(hashtag => hashtag.href)).toEqual([
      'https://example.com/tags/one',
      'https://example.com/tags/two',
    ]);
  });

  it('splits a trailing hashtag line after one newline', () => {
    const html = `<p>Hello<br>${anchor('one')} ${anchor('two')}</p>`;

    expect(splitTrailingHashtags(html)).toEqual({
      html: '<p>Hello</p>',
      hashtags: [
        { name: 'one', text: '#one', href: 'https://example.com/tags/one' },
        { name: 'two', text: '#two', href: 'https://example.com/tags/two' },
      ],
    });
  });

  it('drops a hashtag-only final paragraph', () => {
    const html = `<p>Hello</p><p>${anchor('one')} ${anchor('two')}</p>`;

    expect(splitTrailingHashtags(html).html).toBe('<p>Hello</p>');
    expect(names(splitTrailingHashtags(html))).toEqual(['one', 'two']);
  });

  it('returns an empty body for a hashtag-only post', () => {
    const html = `<p>${anchor('one')} ${anchor('two')}</p>`;

    expect(splitTrailingHashtags(html)).toEqual({
      html: '',
      hashtags: [
        { name: 'one', text: '#one', href: 'https://example.com/tags/one' },
        { name: 'two', text: '#two', href: 'https://example.com/tags/two' },
      ],
    });
  });

  it('treats hashtags on separate lines as one trailing run', () => {
    const html = `<p>${anchor('one')}<br>${anchor('two')}</p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe('');
    expect(names(result)).toEqual(['one', 'two']);
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
      `<br>${anchor('one')} ${anchor('two')}`,
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
    const html = `<p>Hello ${anchor('one', { rel: 'nofollow noopener noreferrer', href: 'https://remote.test/tags/one' })}</p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe('<p>Hello</p>');
    expect(result.hashtags).toEqual([
      { name: 'one', text: '#one', href: 'https://remote.test/tags/one' },
    ]);
  });

  it('keeps duplicate trailing hashtags in order', () => {
    const html = `<p>${anchor('one', { href: 'https://example.com/tags/one' })} ${anchor('one', { href: 'https://example.com/tags/one?repeat=1' })}</p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe('');
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
    const html = `<p>Hello ${anchor('one')}<script>window.__statusHashtagProbe()</script></p><img src="x" onerror="window.__statusHashtagProbe()">`;

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
    const html = `<p>Hello ${anchor('inline')} there ${anchor('end')}</p>`;
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

  it('splits hashtags wrapped in an inline element', () => {
    const html = `<p>Hello <small>${anchor('one')} ${anchor('two')}</small></p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe('<p>Hello</p>');
    expect(names(result)).toEqual(['one', 'two']);
  });

  it('splits hashtags in nested inline wrappers', () => {
    const html = `<p>Hello <small>
  <span>${anchor('one')}</span> <span>${anchor('two')}</span>
</small></p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe('<p>Hello</p>');
    expect(names(result)).toEqual(['one', 'two']);
  });

  it('does not split a wrapper that also contains ordinary text', () => {
    const html = `<p>Hello <small>tags: ${anchor('one')} ${anchor('two')}</small></p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe(html);
    expect(result.hashtags).toEqual([]);
  });

  it('splits a wrapped hashtag run that follows a paragraph', () => {
    const html = `<p>Hello</p><small>${anchor('one')} ${anchor('two')}</small>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe('<p>Hello</p>');
    expect(names(result)).toEqual(['one', 'two']);
  });

  it('does not split a wrapped hashtag inside a blockquote', () => {
    const html = `<blockquote><small>${anchor('one')}</small></blockquote>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe(html);
    expect(result.hashtags).toEqual([]);
  });

  it('does not split a wrapper that contains an image', () => {
    const html = `<p>Hello <small><img src="https://example.com/a.png">${anchor('one')}</small></p>`;
    const result = splitTrailingHashtags(html);

    expect(result.html).toBe(html);
    expect(result.hashtags).toEqual([]);
  });
});

describe('trailing hashtag translation matching', () => {
  const source = `<p>Hello ${anchor('one')} ${anchor('two')}</p>`;
  const matchingTarget = `<p>こんにちは ${anchor('one')} ${anchor('two')}</p>`;

  it('removes a target run that matches the source run', () => {
    const sourceParts = splitTrailingHashtags(source);
    const targetHtml = stripMatchingTrailingHashtags(sourceParts.hashtags, matchingTarget);

    expect(trailingHashtagsEqual(sourceParts.hashtags, splitTrailingHashtags(matchingTarget).hashtags)).toBe(true);
    expect(targetHtml).toBe('<p>こんにちは</p>');
  });

  it('matches hashtag names case-insensitively', () => {
    const sourceParts = splitTrailingHashtags(`<p>${anchor('One')}</p>`);
    const target = `<p>${anchor('one')}</p>`;

    expect(trailingHashtagsEqual(sourceParts.hashtags, splitTrailingHashtags(target).hashtags)).toBe(true);
    expect(stripMatchingTrailingHashtags(sourceParts.hashtags, target)).toBe('');
  });

  it('matches hashtag names after NFKC normalization', () => {
    const sourceParts = splitTrailingHashtags(`<p>${anchor('Ａ')}</p>`);
    const target = `<p>${anchor('A')}</p>`;

    expect(trailingHashtagsEqual(sourceParts.hashtags, splitTrailingHashtags(target).hashtags)).toBe(true);
  });

  it('does not rewrite target HTML when the trailing run differs', () => {
    const sourceParts = splitTrailingHashtags(source);
    const target = `<p>こんにちは ${anchor('one')} ${anchor('different')}</p>`;
    const result = stripMatchingTrailingHashtags(sourceParts.hashtags, target);

    expect(trailingHashtagsEqual(sourceParts.hashtags, splitTrailingHashtags(target).hashtags)).toBe(false);
    expect(result).toBe(target);
  });

  it('strips matching trailing hashtags when both runs are wrapped', () => {
    const source = `<p>Hello <small>${anchor('one')} ${anchor('two')}</small></p>`;
    const target = `<p>こんにちは <span><span>${anchor('one')}</span> <span>${anchor('two')}</span></span></p>`;
    const sourceParts = splitTrailingHashtags(source);

    expect(names(sourceParts)).toEqual(['one', 'two']);
    expect(stripMatchingTrailingHashtags(sourceParts.hashtags, target)).toBe('<p>こんにちは</p>');
  });

  it('does not split a target run when the source has no badges', () => {
    const sourceParts = splitTrailingHashtags('<p>Hello</p>');
    const target = `<p>こんにちは ${anchor('one')}</p>`;

    expect(sourceParts.hashtags).toEqual([]);
    expect(stripMatchingTrailingHashtags(sourceParts.hashtags, target)).toBe(target);
  });
});
