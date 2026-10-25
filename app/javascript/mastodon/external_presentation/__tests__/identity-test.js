import { fromJS } from 'immutable';

jest.mock('react-intl', () => ({ defineMessages: messages => messages }));

import {
  cleanText,
  externalIdentityOf,
  externalIdentityName,
  externalIdentityReaderText,
  safeIconUrl,
  safeLinkUrl,
} from '../index';

const intl = {
  formatMessage: ({ defaultMessage }, values) => {
    if (!values) return defaultMessage;
    return defaultMessage.replace(/\{(\w+)\}/g, (_, key) => values[key]);
  },
};

const presentation = (extra = {}) => ({
  kind: 'external_source',
  name: 'Blog name',
  subtitle: 'RSS',
  source_url: 'https://example.com/',
  icon_url: null,
  thumbnail_url: null,
  byline_name: 'Ada',
  ...extra,
});

const external = (overrides = {}, fedibird = {}) => fromJS({
  id: '1',
  account: 'owner',
  visibility: 'external',
  fedibird_external: { protocol: 'rss', source_title: 'Blog name', byline_name: 'Ada', canonical_url: 'https://example.com/posts/1', presentation: presentation(), ...fedibird },
  ...overrides,
});

describe('externalIdentityOf', () => {
  it('returns null for ordinary statuses, boosts, and E4 public link notes', () => {
    expect(externalIdentityOf(null)).toBeNull();
    expect(externalIdentityOf(undefined)).toBeNull();
    expect(externalIdentityOf({ visibility: 'external' })).toBeNull();
    expect(externalIdentityOf(fromJS({ id: '1', account: 'a', visibility: 'public' }))).toBeNull();
    expect(externalIdentityOf(fromJS({ id: '1', account: 'a', visibility: 'direct' }))).toBeNull();
    expect(externalIdentityOf(fromJS({ id: '2', account: 'a', visibility: 'public', reblog: '1' }))).toBeNull();
    // A link note never carries fedibird_external, so it keeps its real author.
    expect(externalIdentityOf(fromJS({ id: '3', account: 'a', visibility: 'public', fedibird_external: null }))).toBeNull();
  });

  it('reads the owner-only presentation of an external status', () => {
    expect(externalIdentityOf(external())).toEqual({
      name: 'Blog name',
      subtitle: 'RSS',
      sourceUrl: 'https://example.com/',
      articleUrl: 'https://example.com/posts/1',
      iconUrl: null,
      thumbnailUrl: null,
      bylineName: 'Ada',
      protocol: 'rss',
      iconId: 'rss',
    });
  });

  it('also applies to a legacy personal projection that carries the presentation', () => {
    const identity = externalIdentityOf(external({ visibility: 'personal' }));

    expect(identity.name).toBe('Blog name');
  });

  it('draws a generic external identity, never the account, when the presentation is missing or malformed', () => {
    const missing = externalIdentityOf(fromJS({ id: '1', account: 'owner', visibility: 'external', fedibird_external: { protocol: 'atom', source_title: 'Old API feed' } }));
    expect(missing).toMatchObject({ name: 'Old API feed', subtitle: 'Atom', sourceUrl: null, articleUrl: null, iconUrl: null, iconId: 'rss' });

    const noFields = externalIdentityOf(fromJS({ id: '1', account: 'owner', visibility: 'external' }));
    expect(noFields).toMatchObject({ name: null, subtitle: null, sourceUrl: null, iconId: 'external-link' });
    expect(externalIdentityName(intl, noFields)).toBe('External content');

    const malformed = externalIdentityOf(external({}, { presentation: { kind: 'other', name: 'Fake' } }));
    expect(malformed.name).toBe('Blog name');
    expect(malformed.sourceUrl).toBeNull();

    // A non-external status with a malformed presentation stays ordinary.
    expect(externalIdentityOf(external({ visibility: 'public' }, { presentation: { kind: 'other' } }))).toBeNull();
  });

  it('falls back to a protocol label when the name is blank', () => {
    const identity = externalIdentityOf(external({}, { presentation: presentation({ name: '   ', subtitle: null }) }));

    expect(identity.name).toBeNull();
    expect(identity.subtitle).toBe('RSS');
    expect(externalIdentityName(intl, identity)).toBe('External content');
  });

  it('drops unsafe links and images instead of using them', () => {
    const identity = externalIdentityOf(external({}, { presentation: presentation({ source_url: 'javascript:alert(1)', icon_url: 'data:image/png;base64,AAAA', thumbnail_url: 'http://tracker.example/pixel.gif' }) }));

    expect(identity.sourceUrl).toBeNull();
    expect(identity.iconUrl).toBeNull();
    expect(identity.thumbnailUrl).toBeNull();
  });

  it('keeps the stored feed icon that the server delivers from the page origin', () => {
    const url = `${window.location.origin}/external_source_icons/7/${'a'.repeat(64)}`;
    const identity = externalIdentityOf(external({}, { presentation: presentation({ icon_url: url }) }));

    expect(identity.iconUrl).toBe(url);
    expect(identity.thumbnailUrl).toBeNull();
  });

  it('keeps text as plain text and bounds its length', () => {
    const identity = externalIdentityOf(external({}, { presentation: presentation({ name: `<img src=x onerror=alert(1)>\u202Eevil\n${'a'.repeat(400)}`, byline_name: 42 }) }));

    expect(identity.name.startsWith('<img src=x onerror=alert(1)>evil ')).toBe(true);
    expect(identity.name).not.toMatch(/[\u202E\n]/);
    expect(identity.name.length).toBe(120);
    expect(identity.bylineName).toBeNull();
  });
});

describe('url and text guards', () => {
  it('accepts only absolute http(s) site links without credentials', () => {
    expect(safeLinkUrl('https://example.com/')).toBe('https://example.com/');
    expect(safeLinkUrl('http://example.com/blog')).toBe('http://example.com/blog');
    ['javascript:alert(1)', 'data:text/html,x', '//example.com/', '/accounts/1', 'ftp://example.com/', 'https://user:pw@example.com/', '', null, undefined, 5, `https://example.com/${'a'.repeat(3000)}`].forEach(value => {
      expect(safeLinkUrl(value)).toBeNull();
    });
  });

  it('accepts only images from the page origin', () => {
    expect(safeIconUrl(`${window.location.origin}/system/icon.png`)).toBe(`${window.location.origin}/system/icon.png`);
    expect(safeIconUrl('/system/icon.png')).toBe(`${window.location.origin}/system/icon.png`);
    ['https://media.example/icon.png', 'http://tracker.example/pixel.png', 'javascript:alert(1)', 'data:image/svg+xml,<svg/>', '//tracker.example/p.png', 'https://u:p@media.example/i.png', null, undefined, ''].forEach(value => {
      expect(safeIconUrl(value)).toBeNull();
    });
  });

  it('cleans control and direction characters', () => {
    expect(cleanText('  a\u0007\tb\u202Ec  ', 10)).toBe('a bc');
    expect(cleanText('', 10)).toBeNull();
    expect(cleanText(null, 10)).toBeNull();
    expect(cleanText('abcdef', 4)).toBe('abc…');
  });
});

describe('externalIdentityReaderText', () => {
  it('names the source and says the content is private to the owner', () => {
    const plain = externalIdentityOf(external({}, { presentation: presentation({ byline_name: null }) }));
    const withByline = externalIdentityOf(external());

    expect(externalIdentityReaderText(intl, plain)).toBe('External content from Blog name (RSS), only visible to you');
    expect(externalIdentityReaderText(intl, withByline)).toBe('External content from Blog name (RSS) by Ada, only visible to you');
  });
});
