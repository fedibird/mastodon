import { fetchFilters } from 'mastodon/actions/filters';
import { invalidateUserPostingContextAssignments } from 'mastodon/actions/user_posting_context_assignments';
import { fetchUserPostingStyles } from 'mastodon/actions/user_posting_styles';
import { isEmbeddedSettingsUrl } from './registry';

export const refreshEmbeddedSettings = (screen, dispatch) => {
  if (screen === 'filters') return dispatch(fetchFilters());
  if (screen === 'postingStyles') return dispatch(fetchUserPostingStyles({ force: true }));
  return Promise.resolve();
};

const saves = new WeakMap();
export const pendingSettingsSave = (screen, dispatch) => screen === 'postingStyles' ? saves.get(dispatch) : null;

export const settingsFormMethod = body => String(body.get('_method') || 'POST').toUpperCase();

// The parent-window fetch outlives the iframe/column. Never abort
// a submitted mutation when React navigates away or a rendering timeout fires.
export const submitEmbeddedSettings = (screen, url, body, dispatch) => {
  if (!isEmbeddedSettingsUrl(screen, url, window.location.origin, settingsFormMethod(body)) || url.searchParams.get('embedded') !== '1') return Promise.reject(new Error('Invalid embedded settings URL'));

  if (pendingSettingsSave(screen, dispatch)) return Promise.reject(new Error('Settings save already pending'));
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
      if (screen === 'postingStyles') dispatch(invalidateUserPostingContextAssignments());
    }
  })();
  if (screen === 'postingStyles') {
    saves.set(dispatch, request);
    request.finally(() => {
      if (saves.get(dispatch) === request) saves.delete(dispatch);
    }).catch(() => {});
  }
  return request;
};

export const bindEmbeddedSettingsNavigation = (screen, frame, { onNavigate, onSubmit, onReject }) => {
  const doc = frame.contentDocument;
  const origin = window.location.origin;
  const allowedUrl = (value, method = 'GET') => {
    const url = new URL(value, frame.contentWindow.location.href);
    return isEmbeddedSettingsUrl(screen, url, origin, method) && url.searchParams.get('embedded') === '1' ? url : null;
  };
  const submit = event => {
    const form = event.target;
    const method = (form.getAttribute('method') || 'get').toUpperCase();
    const body = new FormData(form);
    const url = allowedUrl(form.action, method === 'GET' ? method : settingsFormMethod(body));
    if (!url) {
      if (screen === 'postingStyles') {
        event.preventDefault(); event.stopImmediatePropagation(); onReject?.();
      }
      return;
    }
    event.preventDefault();
    event.stopImmediatePropagation();
    const button = event.submitter || form.querySelector('button[type="submit"], input[type="submit"]');
    if (button?.name) body.append(button.name, button.value);
    if (method === 'GET') {
      body.forEach((value, name) => url.searchParams.set(name, value));
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

// Existing filter consumers keep their fixed-screen API.
export const submitFilterSettings = (url, body, dispatch) => submitEmbeddedSettings('filters', url, body, dispatch);
export const bindFilterSettingsNavigation = (frame, handlers) => bindEmbeddedSettingsNavigation('filters', frame, handlers);
