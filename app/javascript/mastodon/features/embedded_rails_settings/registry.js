// Only developer-owned identifiers can select an embedded Rails screen.
export const FILTER_SETTINGS_ROUTE = '/settings/filters';
export const POSTING_STYLES_SETTINGS_ROUTE = '/settings/posting-styles';
export const isEmbeddedSettingsRoute = path => [FILTER_SETTINGS_ROUTE, POSTING_STYLES_SETTINGS_ROUTE].includes(path);

const positiveId = /^[1-9]\d{0,18}$/;
const postingQueryAllowed = url => {
  const seen = new Set();
  for (const [key, value] of url.searchParams) {
    if (seen.has(key)) return false;
    seen.add(key);
    if (key === 'embedded' ? value !== '1' : !['page', 'user_posting_context_id'].includes(key) || !positiveId.test(value)) return false;
  }
  return !url.hash && !url.username && !url.password;
};

// These reflect config/routes.rb. preview is JSON/AJAX only, never a frame GET.
const postingPathAllowed = (path, method) => {
  const contexts = '/settings/user_posting_contexts';
  const assignments = '/settings/user_posting_context_assignments';
  if (method === 'GET') return path === contexts || path === `${contexts}/new` || /^\/settings\/user_posting_contexts\/[1-9]\d{0,18}\/(edit|confirm_destroy)$/.test(path) || path === assignments;
  if (method === 'POST') return path === contexts || path === `${contexts}/update_usual` || /^\/settings\/user_posting_contexts\/[1-9]\d{0,18}\/duplicate$/.test(path) || /^\/settings\/user_posting_context_assignments\/[1-9]\d{0,18}\/(release|decline)$/.test(path);
  return ['PATCH', 'PUT', 'DELETE'].includes(method) && /^\/settings\/user_posting_contexts\/[1-9]\d{0,18}$/.test(path);
};

export const isFilterSettingsUrl = (url, origin) => url.origin === origin && /^\/filters(?:\/new|\/\d+(?:\/edit|\/statuses(?:\/batch)?)?)?$/.test(url.pathname);
export const isPostingStylesSettingsUrl = (url, origin, method = 'GET') => url.origin === origin && postingQueryAllowed(url) && postingPathAllowed(url.pathname, method);

const screens = Object.freeze({
  filters: Object.freeze({ path: '/filters', embeddedPath: '/filters?embedded=1', allows: isFilterSettingsUrl }),
  postingStyles: Object.freeze({ path: '/settings/user_posting_contexts', embeddedPath: '/settings/user_posting_contexts?embedded=1', allows: isPostingStylesSettingsUrl }),
});

export const getEmbeddedScreen = name => Object.prototype.hasOwnProperty.call(screens, name) ? screens[name] : null;
export const isEmbeddedSettingsUrl = (screen, url, origin, method = 'GET') => Boolean(getEmbeddedScreen(screen)?.allows(url, origin, method)) && url.searchParams.get('embedded') === '1';
