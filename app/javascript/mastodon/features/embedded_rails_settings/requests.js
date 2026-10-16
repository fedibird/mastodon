import { fetchFilters } from 'mastodon/actions/filters';
import { isFilterSettingsUrl } from './registry';

// The parent-window fetch outlives the iframe/column. Never abort
// a submitted mutation when React navigates away or a rendering timeout fires.
export const submitFilterSettings = (url, body, dispatch) => {
  if (!isFilterSettingsUrl(url, window.location.origin) || url.searchParams.get('embedded') !== '1') return Promise.reject(new Error('Invalid filter settings URL'));

  return (async () => {
    try {
      return await window.fetch(url.href, {
        method: 'POST', body, credentials: 'same-origin',
        headers: { Accept: 'text/html' },
      });
    } finally {
      // A response (including the redirected GET) follows the Rails action's
      // commit. On ambiguous network failures, do one bounded reconciliation.
      await dispatch(fetchFilters());
    }
  })();
};

export const bindFilterSettingsNavigation = (frame, { onNavigate, onSubmit }) => {
  const doc = frame.contentDocument;
  const origin = window.location.origin;
  const allowedUrl = value => {
    const url = new URL(value, frame.contentWindow.location.href);
    return isFilterSettingsUrl(url, origin) && url.searchParams.get('embedded') === '1' ? url : null;
  };
  const submit = event => {
    const form = event.target;
    const url = allowedUrl(form.action);
    if (!url) return;
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
    const url = allowedUrl(link.href);
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
