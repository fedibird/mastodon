import { accountUrlForHashtag, hashtagKey } from '../account_tag_url';

describe('accountUrlForHashtag', () => {
  const tags = [
    { name: 'rails', url: 'https://example.test/tags/rails', account_url: 'https://remote.example/@bob/tagged/rails' },
    { name: 'ハッシュ', url: 'https://example.test/tags/hash', account_url: 'https://remote.example/@bob/tagged/%E3%83%8F%E3%83%83%E3%82%B7%E3%83%A5' },
    { name: 'plain', url: 'https://example.test/tags/plain' },
  ];

  it.each([
    ['exact name', 'rails', 'https://remote.example/@bob/tagged/rails'],
    ['display case', 'Rails', 'https://remote.example/@bob/tagged/rails'],
    ['leading hash', '#rails', 'https://remote.example/@bob/tagged/rails'],
    ['fullwidth hash', '＃rails', 'https://remote.example/@bob/tagged/rails'],
    ['unicode tag', 'ハッシュ', 'https://remote.example/@bob/tagged/%E3%83%8F%E3%83%83%E3%82%B7%E3%83%A5'],
    ['tag without account_url', 'plain', null],
    ['html-only label', 'missing', null],
    ['blank label', '   ', null],
  ])('matches %s', (_title, label, expected) => {
    expect(accountUrlForHashtag(tags, label)).toBe(expected);
  });

  it('does not use another tag when two normalized names disagree', () => {
    const ambiguous = [
      { name: 'rails', account_url: 'https://a.example/@a/tagged/rails' },
      { name: 'RAILS', account_url: 'https://b.example/@b/tagged/rails' },
    ];

    expect(accountUrlForHashtag(ambiguous, 'rails')).toBeNull();
  });

  it('returns the shared url when duplicate names agree', () => {
    const duplicates = [
      { name: 'rails', account_url: 'https://remote.example/@bob/tagged/rails' },
      { name: 'Rails', account_url: 'https://remote.example/@bob/tagged/rails' },
    ];

    expect(accountUrlForHashtag(duplicates, 'rails')).toBe('https://remote.example/@bob/tagged/rails');
  });

  it('folds case and width before comparing', () => {
    expect(hashtagKey('＃Ｒails')).toBe(hashtagKey('rails'));
  });
});
