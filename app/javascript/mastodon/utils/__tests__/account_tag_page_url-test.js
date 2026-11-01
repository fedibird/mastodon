import { accountTagPageUrl } from '../account_tag_page_url';

const mastodon = {
  softwareName: 'mastodon',
  softwareVersion: '4.2.1',
  domain: 'remote.example',
  username: 'bob',
  tag: 'rails',
};

const mastodonUrl = 'https://remote.example/@bob/tagged/rails';

function row(title, overrides, expected) {
  return [title, { ...mastodon, ...overrides }, expected];
}

describe('accountTagPageUrl', () => {
  const japanese = 'ハッシュ';
  const japaneseUrl = `https://remote.example/@bob/tagged/${encodeURIComponent(japanese)}`;

  it.each([
    row('mastodon 4.2.1', {}, mastodonUrl),
    row('mastodon name is case-insensitive', { softwareName: 'Mastodon' }, mastodonUrl),
    row('mastodon name is trimmed', { softwareName: ' mastodon ' }, mastodonUrl),
    row('mastodon 2.8.0 is the first stable release with the route', { softwareVersion: '2.8.0' }, mastodonUrl),
    row('mastodon 2.8.0rc1 already had the route', { softwareVersion: '2.8.0rc1' }, mastodonUrl),
    row('mastodon 2.8.0-rc1', { softwareVersion: '2.8.0-rc1' }, mastodonUrl),
    row('mastodon 3.5.3', { softwareVersion: '3.5.3' }, mastodonUrl),
    row('mastodon nightly after 2.8', { softwareVersion: '4.3.0-nightly.2024-05-01' }, mastodonUrl),
    row('mastodon build metadata does not change the name', { softwareVersion: '4.2.10+glitch' }, mastodonUrl),
    row('unicode tag is encoded once', { tag: japanese }, japaneseUrl),
    row('separator tag', { tag: 'hello_world' }, 'https://remote.example/@bob/tagged/hello_world'),
    row('fedibird 0.1', {
      softwareName: 'fedibird',
      softwareVersion: '0.1',
      domain: 'bird.example',
      username: 'alice',
    }, 'https://bird.example/@alice/tagged/rails'),
    row('fedibird name is case-insensitive', {
      softwareName: 'FediBird',
      softwareVersion: '0.1',
    }, 'https://remote.example/@bob/tagged/rails'),
    row('host is the nodeinfo domain, not another host stuffed into the input', {
      domain: 'remote.example',
      url: 'https://evil.example/@bob',
    }, mastodonUrl),
    row('uppercase host is normalized', { domain: 'Remote.Example' }, 'https://remote.example/@bob/tagged/rails'),
  ])('%s', (_title, input, expected) => {
    expect(accountTagPageUrl(input)).toBe(expected);
  });

  it.each([
    row('mastodon 2.7.4 has no tagged profile route', { softwareVersion: '2.7.4' }, null),
    row('mastodon 2.8 is not a full version', { softwareVersion: '2.8' }, null),
    row('mastodon 2.8.0.1 is not a known version', { softwareVersion: '2.8.0.1' }, null),
    row('mastodon dev', { softwareVersion: 'dev' }, null),
    row('mastodon blank version', { softwareVersion: ' ' }, null),
    row('fedibird 0.1.0 is not the published nodeinfo version', { softwareName: 'fedibird', softwareVersion: '0.1.0' }, null),
    row('fedibird reporting a mastodon version', { softwareName: 'fedibird', softwareVersion: '4.2.13' }, null),
    row('fedibird blank version', { softwareName: 'fedibird', softwareVersion: '' }, null),
    row('glitch is not assumed to be mastodon', { softwareName: 'glitch', softwareVersion: '4.2.10+glitch' }, null),
    row('hometown is not assumed to be mastodon', { softwareName: 'hometown', softwareVersion: '4.0.0' }, null),
    row('pleroma', { softwareName: 'pleroma', softwareVersion: '2.5.0' }, null),
    row('akkoma', { softwareName: 'akkoma', softwareVersion: '3.10.0' }, null),
    row('pixelfed', { softwareName: 'pixelfed', softwareVersion: '0.12.3' }, null),
    row('misskey', { softwareName: 'misskey', softwareVersion: '2024.11.0' }, null),
    row('sharkey', { softwareName: 'sharkey', softwareVersion: '2024.9.0' }, null),
    row('firefish', { softwareName: 'firefish', softwareVersion: '1.0.5' }, null),
    row('calckey', { softwareName: 'calckey', softwareVersion: '14.0.0' }, null),
    row('iceshrimp', { softwareName: 'iceshrimp', softwareVersion: '2023.12.0' }, null),
    row('gotosocial', { softwareName: 'gotosocial', softwareVersion: '0.16.0' }, null),
    row('friendica', { softwareName: 'friendica', softwareVersion: '2024.09' }, null),
    row('unknown software', { softwareName: 'example', softwareVersion: '1.0.0' }, null),
    row('missing software name', { softwareName: '' }, null),
    row('non-string version', { softwareVersion: 4.2 }, null),
    row('dotted username is outside the confirmed route', { username: 'bob.smith' }, null),
    row('username with a slash', { username: 'bob/admin' }, null),
    row('username that is an acct', { username: 'bob@remote.example' }, null),
    row('empty username', { username: '' }, null),
    row('tag with a slash stays off the url', { tag: 'a/b' }, null),
    row('tag with a query', { tag: 'a?x=1' }, null),
    row('tag with a fragment', { tag: 'a#b' }, null),
    row('tag with a percent sign is not decoded or double-encoded', { tag: '100%' }, null),
    row('tag that is a traversal segment', { tag: '..' }, null),
    row('hash still attached', { tag: '#rails' }, null),
    row('blank tag', { tag: ' ' }, null),
    row('numeric tag', { tag: '123' }, null),
    row('domain with a scheme', { domain: 'https://remote.example' }, null),
    row('domain with a path', { domain: 'remote.example/tagged' }, null),
    row('domain with a port', { domain: 'remote.example:443' }, null),
    row('domain with userinfo', { domain: 'bob@remote.example' }, null),
    row('domain with a backslash', { domain: 'remote.example\\evil.test' }, null),
    row('single-label host', { domain: 'localhost' }, null),
    row('empty domain', { domain: '' }, null),
  ])('%s', (_title, input, expected) => {
    expect(accountTagPageUrl(input)).toBe(expected);
  });

  it('encodes a unicode tag once and does not add a query, fragment, or trailing slash', () => {
    const href = accountTagPageUrl({ ...mastodon, tag: japanese });
    const segment = href.split('/tagged/')[1];

    expect(href).toBe(japaneseUrl);
    expect(segment).toBe(encodeURIComponent(japanese));
    expect(decodeURIComponent(segment)).toBe(japanese);
    expect(segment).not.toContain('%25');
    expect(href.endsWith('/')).toBe(false);
    expect(new URL(href).search).toBe('');
    expect(new URL(href).hash).toBe('');
    expect(new URL(href).protocol).toBe('https:');
    expect(new URL(href).hostname).toBe('remote.example');
  });

  it('returns null when the arguments are missing', () => {
    expect(accountTagPageUrl()).toBeNull();
    expect(accountTagPageUrl(null)).toBeNull();
  });
});
