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
