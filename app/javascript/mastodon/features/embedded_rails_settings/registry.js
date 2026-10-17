// Only developer-owned identifiers can select an embedded Rails screen.
export const FILTER_SETTINGS_ROUTE = '/settings/filters';
export const POSTING_STYLES_SETTINGS_ROUTE = '/settings/posting-styles';

const screens = Object.freeze({
  filters: Object.freeze({ path: '/filters', embeddedPath: '/filters?embedded=1', icon: 'filter' }),
  postingStyles: Object.freeze({ path: '/settings/user_posting_contexts', embeddedPath: '/settings/user_posting_contexts?embedded=1', icon: 'pencil' }),
});

export const getEmbeddedScreen = name => Object.prototype.hasOwnProperty.call(screens, name) ? screens[name] : null;
export const isEmbeddedSettingsRoute = path => path === FILTER_SETTINGS_ROUTE || path === POSTING_STYLES_SETTINGS_ROUTE;
export const isFilterSettingsUrl = (url, origin) => url.origin === origin && /^\/filters(?:\/new|\/\d+(?:\/edit|\/statuses(?:\/batch)?)?)?$/.test(url.pathname);
const idPattern = '[1-9][0-9]{0,18}';
const positiveId = value => new RegExp(`^${idPattern}$`).test(value) && (value.length < 19 || value <= '9223372036854775807');

export const isPostingStylesSettingsUrl = (url, origin, method = 'GET', preview = false) => {
  if (url.origin !== origin || url.username || url.password || url.hash) return false;
  const contexts = '/settings/user_posting_contexts';
  const assignments = '/settings/user_posting_context_assignments';
  const routes = {
    GET: [`${contexts}`, `${contexts}/new`, `${contexts}/${idPattern}/(?:edit|confirm_destroy)`, assignments],
    POST: [contexts, `${contexts}/${idPattern}/duplicate`, `${assignments}/${idPattern}/(?:release|decline)`, ...(preview ? [`${contexts}/preview`] : [])],
    PATCH: [`${contexts}/${idPattern}`],
    DELETE: [`${contexts}/${idPattern}`],
  };
  if (!(routes[method.toUpperCase()] || []).some(path => new RegExp(`^${path}$`).test(url.pathname))) return false;
  const segment = url.pathname.split('/')[3];
  if (/^\d+$/.test(segment || '') && !positiveId(segment)) return false;
  const seen = new Set();
  for (const [key, value] of url.searchParams) {
    if (seen.has(key)) return false;
    seen.add(key);
    if (key === 'embedded' && value === '1') continue;
    if (url.pathname === assignments && key === 'page' && /^[1-9][0-9]{0,9}$/.test(value) && Number(value) <= 2147483647) continue;
    if (url.pathname === assignments && key === 'user_posting_context_id' && positiveId(value)) continue;
    return false;
  }
  return true;
};

export const isEmbeddedSettingsUrl = (screen, url, origin, method = 'GET', preview = false) => screen === 'filters' ? isFilterSettingsUrl(url, origin) : screen === 'postingStyles' && isPostingStylesSettingsUrl(url, origin, method, preview);
