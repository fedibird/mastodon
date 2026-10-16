import ready from '../mastodon/ready';
import { isFilterSettingsUrl } from '../mastodon/features/embedded_rails_settings/registry';

ready(() => {
  // Existing Rails UJS/cocoon handlers still own confirmation and nested fields.
  // Keep content links out of the frame, including same-origin profile links.
  document.addEventListener('click', event => {
    const link = event.target.closest('a[href]');
    if (!link || link.getAttribute('href').startsWith('#')) return;

    const url = new URL(link.href, window.location.href);
    if (isFilterSettingsUrl(url, window.location.origin)) return;

    link.target = '_blank';
    link.rel = 'noopener noreferrer';
  }, true);
});
