import { materializeManagedHashtags, normalizeManagedHashtagName, textContainsHashtag } from '../managed_hashtags';

const foo = { name: 'foo', normalizedName: 'foo' };

describe('managed hashtag normalization', () => {
  it('treats case and width differences as the same hashtag', () => {
    expect(normalizeManagedHashtagName('#Fedibird')).toEqual('fedibird');
    expect(normalizeManagedHashtagName('＃Ｆｅｄｉｂｉｒｄ')).toEqual('fedibird');
    expect(textContainsHashtag('Hello #Fedibird', 'fedibird')).toBe(true);
    expect(textContainsHashtag('＃Ｆｅｄｉｂｉｒｄ', 'fedibird')).toBe(true);
    expect(textContainsHashtag('#fedibirdExtra', 'fedibird')).toBe(false);
  });

  it('matches the representative Tag::HASHTAG_RE cases', () => {
    expect(textContainsHashtag('#test_', 'test_')).toBe(true);
    expect(textContainsHashtag('#_test', '_test')).toBe(true);
    expect(textContainsHashtag('#3d', '3d')).toBe(true);
    expect(textContainsHashtag('#one_two_three', 'one_two_three')).toBe(true);
    expect(textContainsHashtag('#one·two·three', 'one·two·three')).toBe(true);
    expect(textContainsHashtag('#one·two·three·', 'one·two·three')).toBe(true);
    expect(textContainsHashtag('#0123456', '0123456')).toBe(false);
    expect(textContainsHashtag('hello #l33ts35k', 'l33ts35k')).toBe(true);
    expect(textContainsHashtag('hello #world2016', 'world2016')).toBe(true);
    expect(textContainsHashtag('hello #ａｅｓｔｈｅｔｉｃ', 'aesthetic')).toBe(true);
    expect(textContainsHashtag('hello ＃Ｓｙｎｔｈｗａｖｅ', 'synthwave')).toBe(true);
    expect(textContainsHashtag('hello #·one·two·three', 'one·two·three')).toBe(false);
    expect(textContainsHashtag('just add #نرم‌افزار and', 'نرم‌افزار')).toBe(true);
  });

  it('does not treat a URL fragment as a hashtag', () => {
    expect(textContainsHashtag('https://en.wikipedia.org/wiki/Ghostbusters_(song)#Lawsuit', 'lawsuit')).toBe(false);
    expect(textContainsHashtag('https://example.com/foo#fedibird', 'fedibird')).toBe(false);
    expect(textContainsHashtag('Check this out https://medium.com/@alice/some-article#.abcdef123', 'abcdef123')).toBe(false);
  });
});

describe('materializeManagedHashtags', () => {
  it('appends missing hashtags as a trailing run', () => {
    expect(materializeManagedHashtags('Hello', [foo])).toEqual('Hello\n\n#foo');
    expect(materializeManagedHashtags('Hello\n\n', [foo])).toEqual('Hello\n\n#foo');
    expect(materializeManagedHashtags('', [foo, { name: 'bar', normalizedName: 'bar' }])).toEqual('#foo #bar');
  });

  it('merges authored terminal tags only after an explicit blank line', () => {
    expect(materializeManagedHashtags('Hello\n\n#manual', [foo])).toEqual('Hello\n\n#manual #foo');
    expect(materializeManagedHashtags('Hello\n\n#manual #another', [foo])).toEqual('Hello\n\n#manual #another #foo');
    expect(materializeManagedHashtags('Hello\n\n#manual\n#another', [foo])).toEqual('Hello\n\n#manual #another #foo');
    expect(materializeManagedHashtags('Hello\n\n#manual\n\n#another', [foo])).toEqual('Hello\n\n#manual #another #foo');
    expect(materializeManagedHashtags('Hello\r\n\r\n#manual', [foo])).toEqual('Hello\n\n#manual #foo');
    expect(materializeManagedHashtags('Hello\n \n#manual', [foo])).toEqual('Hello\n\n#manual #foo');
  });

  it('preserves single-newline hashtags in the body rather than turning them into badges', () => {
    expect(materializeManagedHashtags('テスト\n#test', [foo])).toEqual('テスト\n#test\n\n#foo');
    expect(materializeManagedHashtags('Hello\n#manual', [foo])).toEqual('Hello\n#manual\n\n#foo');
    expect(materializeManagedHashtags('Hello\n#manual\n#another', [foo])).toEqual('Hello\n#manual\n#another\n\n#foo');
    expect(materializeManagedHashtags('Hello\r\n#manual', [foo])).toEqual('Hello\r\n#manual\n\n#foo');
    expect(materializeManagedHashtags('#manual', [foo])).toEqual('#manual\n\n#foo');
  });

  it('does not absorb body hashtags that precede a separately delimited final run', () => {
    expect(materializeManagedHashtags('Hello\n#inline\n\n#tail', [foo])).toEqual('Hello\n#inline\n\n#tail #foo');
    expect(materializeManagedHashtags('Hello\n#inline\n\n#tail\n#another', [foo])).toEqual('Hello\n#inline\n\n#tail #another #foo');
    expect(materializeManagedHashtags('Hello\n\n#first\nbody\n\n#tail', [foo])).toEqual('Hello\n\n#first\nbody\n\n#tail #foo');
  });

  it('recognizes Unicode and fullwidth separated tags without changing their spelling', () => {
    expect(materializeManagedHashtags('本文\n\n＃日本語 #Fedibird', [foo])).toEqual('本文\n\n＃日本語 #Fedibird #foo');
    expect(materializeManagedHashtags('Hello\n\n#one_two #one·two', [foo])).toEqual('Hello\n\n#one_two #one·two #foo');
    expect(materializeManagedHashtags('本文\n＃日本語 #Fedibird', [foo])).toEqual('本文\n＃日本語 #Fedibird\n\n#foo');
  });

  it('does not insert a blank line when a managed tag is already present in a body line', () => {
    expect(materializeManagedHashtags('Hello\n#Foo', [foo])).toEqual('Hello\n#Foo');
    expect(materializeManagedHashtags('Hello\n＃ＦＯＯ', [foo])).toEqual('Hello\n＃ＦＯＯ');
    expect(materializeManagedHashtags('Hello\n#other #FOO', [foo])).toEqual('Hello\n#other #FOO');
    expect(materializeManagedHashtags('Hello\n\n#foo', [foo])).toEqual('Hello\n\n#foo');
    expect(materializeManagedHashtags('Hello\n\n\n#foo', [foo])).toEqual('Hello\n\n\n#foo');
    expect(materializeManagedHashtags('Hello\r\n\r\n#foo', [foo])).toEqual('Hello\r\n\r\n#foo');
    expect(materializeManagedHashtags('Hello\n\n#other #FOO', [foo])).toEqual('Hello\n\n#other #FOO');
  });

  it('does not move inline or invalid trailing tokens out of the body', () => {
    expect(materializeManagedHashtags('Hello #inline', [foo])).toEqual('Hello #inline\n\n#foo');
    expect(materializeManagedHashtags('Hello\n#manual and more', [foo])).toEqual('Hello\n#manual and more\n\n#foo');
    expect(materializeManagedHashtags('Hello\n#manual,', [foo])).toEqual('Hello\n#manual,\n\n#foo');
    expect(materializeManagedHashtags('Hello\n#manual/next', [foo])).toEqual('Hello\n#manual/next\n\n#foo');
    expect(materializeManagedHashtags('Hello\nhttps://example.com/#manual', [foo])).toEqual('Hello\nhttps://example.com/#manual\n\n#foo');
  });

  it('does not alter drafts when there are no active managed hashtags', () => {
    expect(materializeManagedHashtags('Hello\n#manual', [])).toEqual('Hello\n#manual');
    expect(materializeManagedHashtags('Hello\n#manual', null)).toEqual('Hello\n#manual');
  });

  it('leaves text unchanged when the same hashtag is already present', () => {
    expect(materializeManagedHashtags('Hello #foo', [foo])).toEqual('Hello #foo');
    expect(materializeManagedHashtags('#Foo', [foo])).toEqual('#Foo');
    expect(materializeManagedHashtags('＃ＦＯＯ', [foo])).toEqual('＃ＦＯＯ');
  });

  it('treats a trailing underscore as part of the hashtag', () => {
    expect(materializeManagedHashtags('#test_', [{ name: 'test_', normalizedName: 'test_' }])).toEqual('#test_');
  });

  it('still appends a hashtag that is only a prefix of another tag', () => {
    expect(materializeManagedHashtags('#foobar', [foo])).toEqual('#foobar\n\n#foo');
  });
});
