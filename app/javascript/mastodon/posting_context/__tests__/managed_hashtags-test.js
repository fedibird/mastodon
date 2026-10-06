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

  it('still appends a hashtag that is only a prefix of another tag', () => {
    expect(materializeManagedHashtags('#foobar', [foo])).toEqual('#foobar\n\n#foo');
  });
});
