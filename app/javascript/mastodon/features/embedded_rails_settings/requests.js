import { fetchFilters } from 'mastodon/actions/filters';
import { fetchUserPostingStyles } from 'mastodon/actions/user_posting_styles';
import { isEmbeddedSettingsUrl } from './registry';

export const refreshEmbeddedSettings = (screen, dispatch) => {
  if (screen === 'filters') return dispatch(fetchFilters());
  if (screen === 'postingStyles') return dispatch(fetchUserPostingStyles({ force: true }));
  return Promise.reject(new Error('Unknown settings screen'));
};

const pendingRequests = new Map();
export const pendingEmbeddedSettingsRequest = screen => pendingRequests.get(screen);

// The parent-window fetch outlives the iframe/column. Never abort
// a submitted mutation when React navigates away or a rendering timeout fires.
export const submitEmbeddedSettings = (screen, url, body, dispatch) => {
  const method = String(body.get('_method') || 'POST').toUpperCase();
  if (!isEmbeddedSettingsUrl(screen, url, window.location.origin, method)) return Promise.reject(new Error('Invalid settings URL'));

  if (pendingRequests.has(screen)) return Promise.reject(new Error('Settings save already pending'));

  const request = (async () => {
    try {
      return await window.fetch(url.href, {
        method: 'POST', body, credentials: 'same-origin',
        headers: { Accept: 'text/html' },
      });
    } finally {
      // A response (including the redirected GET) follows the Rails action's
      // commit. On ambiguous network failures, do one bounded reconciliation.
      await refreshEmbeddedSettings(screen, dispatch);
    }
  })().finally(() => pendingRequests.delete(screen));
  pendingRequests.set(screen, request);
  return request;
};

export const bindEmbeddedSettingsNavigation = (screen, frame, { onNavigate, onSubmit, onInvalid }) => {
  const doc = frame.contentDocument;
  const origin = window.location.origin;
  const allowedUrl = (value, method = 'GET') => {
    const url = new URL(value, frame.contentWindow.location.href);
    return isEmbeddedSettingsUrl(screen, url, origin, method) ? url : null;
  };
  const submit = event => {
    const form = event.target;
    const method = (form.getAttribute('method') || 'get').toUpperCase();
    const effectiveMethod = method === 'POST' ? String(new FormData(form).get('_method') || method).toUpperCase() : method;
    const url = allowedUrl(form.action, effectiveMethod);
    if (!url) {
      event.preventDefault();
      event.stopImmediatePropagation();
      onInvalid?.();
      return;
    }
    event.preventDefault();
    event.stopImmediatePropagation();
    const body = new FormData(form);
    const button = event.submitter || form.querySelector('button[type="submit"], input[type="submit"]');
    if (button?.name) body.append(button.name, button.value);
    if ((form.getAttribute('method') || 'get').toLowerCase() === 'get') {
      body.forEach((value, name) => url.searchParams.append(name, value));
      onNavigate(url);
    } else {
      onSubmit(url, body);
    }
  };
  const click = event => {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    const link = event.target.closest('a[href]');
    if (!link || link.hasAttribute('download') || (link.target && link.target !== '_self') || link.getAttribute('href').startsWith('#')) return;
    const url = allowedUrl(link.href, (link.dataset.method || 'GET').toUpperCase());
    if (!url) return;
    event.preventDefault();
    event.stopImmediatePropagation();
    if (link.dataset.confirm && !frame.contentWindow.confirm(link.dataset.confirm)) return;
    if (link.dataset.method) {
      const body = new FormData();
      body.append('_method', link.dataset.method);
      body.append('authenticity_token', doc.querySelector('meta[name="csrf-token"]').content);
      onSubmit(url, body);
    } else {
      onNavigate(url);
    }
  };
  doc.addEventListener('click', click, true);
  doc.addEventListener('submit', submit, true);
  return () => {
    doc.removeEventListener('click', click, true);
    doc.removeEventListener('submit', submit, true);
  };
};

// Existing filter callers retain their fixed screen.
export const submitFilterSettings = (url, body, dispatch) => submitEmbeddedSettings('filters', url, body, dispatch);
export const bindFilterSettingsNavigation = (frame, callbacks) => bindEmbeddedSettingsNavigation('filters', frame, callbacks);
