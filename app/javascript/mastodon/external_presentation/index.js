// @ts-check

import { messages } from './messages';

/**
 * Display identity of a private external projection (RSS/Atom today).
 *
 * The Status keeps its real local Account. This module only reads the
 * owner-only `fedibird_external.presentation` view, so the WebUI can name the
 * external source instead of showing the owner's own face and name. Nothing
 * here writes accounts, builds an account, or links to a profile.
 */

export const EXTERNAL_SOURCE_KIND = 'external_source';

const NAME_LIMIT = 120;
const BYLINE_LIMIT = 120;
const SUBTITLE_LIMIT = 40;
const URL_LIMIT = 2048;

const CONTROL_CHARACTERS = /[\u0000-\u001F\u007F-\u009F\u2028\u2029]/g;
const DIRECTION_CONTROLS = /[\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/g;

const PROTOCOL_ICONS = Object.freeze({ rss: 'rss', atom: 'rss' });
const PROTOCOL_LABELS = Object.freeze({ rss: 'RSS', atom: 'Atom' });

/**
 * Plain text only. The result is rendered as a React text child, never as HTML.
 *
 * @param {any} value
 * @param {number} limit
 * @return {string|null}
 */
export const cleanText = (value, limit) => {
  if (typeof value !== 'string') {
    return null;
  }

  const text = value.replace(DIRECTION_CONTROLS, '').replace(CONTROL_CHARACTERS, ' ').replace(/\s+/g, ' ').trim();

  if (text.length === 0) {
    return null;
  }

  return text.length > limit ? `${text.slice(0, limit - 1)}…` : text;
};

const parseUrl = value => {
  if (typeof value !== 'string' || value.length === 0 || value.length > URL_LIMIT) {
    return null;
  }

  try {
    return new URL(value, window.location.origin);
  } catch (e) {
    return null;
  }
};

/**
 * A site or profile page that opens in a new tab. http(s) only, no
 * credentials, absolute only.
 *
 * @param {any} value
 * @return {string|null}
 */
export const safeLinkUrl = value => {
  if (typeof value !== 'string' || !/^https?:\/\//i.test(value)) {
    return null;
  }

  const url = parseUrl(value);

  if (!url || !/^https?:$/.test(url.protocol) || url.username || url.password || !url.hostname) {
    return null;
  }

  return url.href;
};

/**
 * An image the browser may load. In P1 the server always sends null, so this
 * is a guard for the future: only an image served from this page's own origin
 * is accepted. Any other origin (including https), data: and javascript:
 * fall back to the local protocol icon, and the page CSP still limits
 * img-src.
 *
 * @param {any} value
 * @return {string|null}
 */
export const safeIconUrl = value => {
  if (typeof value !== 'string' || value.startsWith('//')) {
    return null;
  }

  const url = parseUrl(value);

  if (!url || url.username || url.password || !url.hostname) {
    return null;
  }

  return url.origin === window.location.origin ? url.href : null;
};

const read = (map, key) => (map && typeof map.get === 'function' ? map.get(key) : undefined);

/**
 * The identity to draw for a status, or null for every ordinary status.
 *
 * It applies to one status at a time: either the status is the external
 * visibility, or the server sent the owner-only presentation for it (a legacy
 * personal projection). A missing or malformed presentation on an external
 * status still never falls back to the Account; it draws the generic external
 * identity from whatever safe source fields exist.
 *
 * @param {any} status Immutable status
 * @return {{name: string|null, subtitle: string|null, sourceUrl: string|null, articleUrl: string|null, iconUrl: string|null, thumbnailUrl: string|null, bylineName: string|null, protocol: string|null, iconId: string}|null}
 */
export const externalIdentityOf = status => {
  if (!status || typeof status.get !== 'function') {
    return null;
  }

  const external = status.get('fedibird_external');
  const presentation = read(external, 'presentation');
  const validPresentation = !!presentation && typeof presentation.get === 'function' && presentation.get('kind') === EXTERNAL_SOURCE_KIND;

  if (status.get('visibility') !== 'external' && !validPresentation) {
    return null;
  }

  const rawProtocol = read(external, 'protocol');
  const protocol = typeof rawProtocol === 'string' && Object.prototype.hasOwnProperty.call(PROTOCOL_LABELS, rawProtocol) ? rawProtocol : null;
  const protocolLabel = protocol ? PROTOCOL_LABELS[protocol] : null;

  // The article itself. It is not the source site and is never the owner's
  // status page, which a private projection does not have.
  const articleUrl = safeLinkUrl(read(external, 'canonical_url'));

  if (validPresentation) {
    return {
      name: cleanText(presentation.get('name'), NAME_LIMIT),
      subtitle: cleanText(presentation.get('subtitle'), SUBTITLE_LIMIT) || protocolLabel,
      sourceUrl: safeLinkUrl(presentation.get('source_url')),
      articleUrl,
      iconUrl: safeIconUrl(presentation.get('icon_url')),
      thumbnailUrl: safeIconUrl(presentation.get('thumbnail_url')),
      bylineName: cleanText(presentation.get('byline_name'), BYLINE_LIMIT),
      protocol,
      iconId: (protocol && PROTOCOL_ICONS[protocol]) || 'external-link',
    };
  }

  return {
    name: cleanText(read(external, 'source_title'), NAME_LIMIT) || protocolLabel,
    subtitle: protocolLabel,
    sourceUrl: null,
    articleUrl,
    iconUrl: null,
    thumbnailUrl: null,
    bylineName: cleanText(read(external, 'byline_name'), BYLINE_LIMIT),
    protocol,
    iconId: (protocol && PROTOCOL_ICONS[protocol]) || 'external-link',
  };
};

/**
 * @param {any} intl
 * @param {{name: string|null}} identity
 * @return {string}
 */
export const externalIdentityName = (intl, identity) => identity.name || intl.formatMessage(messages.genericName);

/**
 * What a screen reader says for a status header. It names the source and
 * says the item is the owner's own private copy; it does not read the
 * owner's account name or handle as the author.
 *
 * @param {any} intl
 * @param {{name: string|null, subtitle: string|null, bylineName: string|null}} identity
 * @return {string}
 */
export const externalIdentityReaderText = (intl, identity) => {
  const values = {
    name: externalIdentityName(intl, identity),
    service: identity.subtitle || intl.formatMessage(messages.genericName),
    author: identity.bylineName,
  };

  return intl.formatMessage(identity.bylineName ? messages.readerWithByline : messages.reader, values);
};
