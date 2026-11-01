// Public page for one account's posts with a hashtag.
// Each pattern is confirmed from that software's own routes for the NodeInfo
// software.name and version it reports. A fork name, an upstream guess, or a
// version this table does not list returns null.

const HOST_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$/;
const USERNAME_RE = /^[A-Za-z0-9_]{1,30}$/;
// Mastodon hashtag names: letters, numbers, and the separators in Tag::HASHTAG_SEPARATORS.
const TAG_RE = /^(?=.*\p{L})[\p{L}\p{N}_\u00B7\u30FB\u200C]{1,255}$/u;
const MASTODON_VERSION_RE = /^(\d+)\.(\d+)\.(\d+)(?:[-+][0-9A-Za-z.-]+|[A-Za-z][0-9A-Za-z.-]*)?$/;

// Mastodon v2.8.0rc1, v2.8.0, and current main: GET /@:username/tagged/:tag
// (accounts#show). v2.7.4 does not have this route. Usernames Mastodon issues
// match [A-Za-z0-9_]{1,30}; current routes also reject ".", "@", and "/".
// https://github.com/mastodon/mastodon/blob/v2.8.0/config/routes.rb
function mastodonTaggedPath(username, tag) {
  return `/@${encodeURIComponent(username)}/tagged/${encodeURIComponent(tag)}`;
}

// Fedibird reports NodeInfo software.name "fedibird" and software.version "0.1"
// (Mastodon::Version.fedibird_verson). The same public route is in this tree.
function fedibirdTaggedPath(username, tag) {
  return `/@${encodeURIComponent(username)}/tagged/${encodeURIComponent(tag)}`;
}

function mastodonVersionCoversTaggedRoute(version) {
  const match = MASTODON_VERSION_RE.exec(version.trim());

  if (!match) {
    return false;
  }

  const major = Number(match[1]);
  const minor = Number(match[2]);
  const patch = Number(match[3]);

  if (major !== 2) {
    return major > 2;
  }

  if (minor !== 8) {
    return minor > 8;
  }

  return patch >= 0;
}

const PATTERNS = [
  {
    name: 'mastodon',
    matches: mastodonVersionCoversTaggedRoute,
    path: mastodonTaggedPath,
  },
  {
    name: 'fedibird',
    matches(version) {
      return version.trim() === '0.1';
    },
    path: fedibirdTaggedPath,
  },
];

function absoluteHttps(domain, path) {
  if (typeof domain !== 'string' || typeof path !== 'string' || path.charAt(0) !== '/') {
    return null;
  }

  const host = domain.trim().toLowerCase();

  if (!HOST_RE.test(host) || /[\\?#\s]/.test(path) || path.includes('//') || path.endsWith('/')) {
    return null;
  }

  let url;

  try {
    url = new URL(path, `https://${host}`);
  } catch (e) {
    return null;
  }

  if (url.origin !== `https://${host}` || url.pathname !== path) {
    return null;
  }

  if (url.search !== '' || url.hash !== '' || url.username !== '' || url.password !== '') {
    return null;
  }

  return url.href;
}

// Returns an https URL on the NodeInfo host, or null when the software,
// version, host, username, or tag is not a confirmed pattern.
export function accountTagPageUrl(input) {
  if (!input || typeof input !== 'object') {
    return null;
  }

  const { softwareName, softwareVersion, domain, username, tag } = input;

  if (typeof softwareName !== 'string' || typeof softwareVersion !== 'string') {
    return null;
  }

  if (typeof username !== 'string' || !USERNAME_RE.test(username)) {
    return null;
  }

  if (typeof tag !== 'string' || !TAG_RE.test(tag)) {
    return null;
  }

  const name = softwareName.trim().toLowerCase();
  const pattern = PATTERNS.find(entry => entry.name === name && entry.matches(softwareVersion));

  if (!pattern) {
    return null;
  }

  return absoluteHttps(domain, pattern.path(username, tag));
}
