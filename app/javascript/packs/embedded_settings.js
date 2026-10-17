import { bindUserPostingContextCardMenus, bindUserPostingContextPreview, disposeUserPostingContextPreview } from '../mastodon/features/user_posting_contexts/preview';
import ReactDOM from 'react-dom';
import ready from '../mastodon/ready';
import { isEmbeddedSettingsUrl } from '../mastodon/features/embedded_rails_settings/registry';

ready(() => {
  // The parent binds on DOM readiness, before slow images/fonts can delay load.
  // This is a DOM event on our actual same-origin frame, not a message/URL API.
  window.frameElement?.dispatchEvent(new Event('embedded-settings:ready'));

  document.addEventListener('embedded-settings:before-render', () => disposeUserPostingContextPreview(document));

  // A parent-owned mutation may return an invalid Rails form without redirect.
  // Reinitialize only the existing field widgets on that server-rendered main.
  document.addEventListener('embedded-settings:render', () => {
    document.querySelectorAll('.form-emoji-picker-root').forEach(root => {
      ReactDOM.unmountComponentAtNode(root);
      root.remove();
    });
    bindUserPostingContextCardMenus(document);
    bindUserPostingContextPreview(document, { renderEmoji: root => {
      import(/* webpackChunkName: "form_emoji_picker" */ '../mastodon/features/emoji/form_emoji_picker')
        .then(({ initializeFormEmojiPickers }) => initializeFormEmojiPickers({ fields: [], textNodes: Array.from(root.querySelectorAll('[data-custom-emoji-text]')) }))
        .catch(console.error);
    } });
    import(/* webpackChunkName: "form_emoji_picker" */ '../mastodon/features/emoji/form_emoji_picker')
      .then(({ initializeFormEmojiPickers }) => {
        initializeFormEmojiPickers();
      })
      .catch(console.error);
  });

  // Existing Rails UJS/cocoon handlers still own confirmation and nested fields.
  // Keep content links out of the frame, including same-origin profile links.
  document.addEventListener('click', event => {
    const link = event.target.closest('a[href]');
    if (!link || link.getAttribute('href').startsWith('#')) return;

    const url = new URL(link.href, window.location.href);
    const screen = document.querySelector('meta[name="embedded-rails-settings"]')?.content;
    if (isEmbeddedSettingsUrl(screen, url, window.location.origin, (link.dataset.method || 'GET').toUpperCase()) && url.searchParams.get('embedded') === '1') return;

    link.target = '_blank';
    link.rel = 'noopener noreferrer';
  }, true);
});
