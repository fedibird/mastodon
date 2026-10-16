// Only developer-owned identifiers can select an embedded Rails screen.
export const FILTER_SETTINGS_ROUTE = '/settings/filters';

const screens = Object.freeze({
  filters: Object.freeze({ path: '/filters', embeddedPath: '/filters?embedded=1' }),
});

export const getEmbeddedScreen = name => Object.prototype.hasOwnProperty.call(screens, name) ? screens[name] : null;

export const isFilterSettingsUrl = (url, origin) => url.origin === origin && /^\/filters(?:\/new|\/\d+(?:\/edit|\/statuses(?:\/batch)?)?)?$/.test(url.pathname);
