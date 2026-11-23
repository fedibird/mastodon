export function createThemePreview(document) {
  let applied = [];
  let pending = [];

  return (theme) => {
    pending.forEach(({ link }) => link.remove());
    const previews = Array.from(document.querySelectorAll('link[data-theme-preview]'))
      .filter(link => link.dataset.themePreview === theme);

    const request = previews.map((preview) => {
      const link = preview.cloneNode(false);
      link.removeAttribute('data-theme-preview');
      link.removeAttribute('as');
      link.rel = 'stylesheet';
      // Fetch the CSS without applying it until the whole preview is ready.
      link.media = 'not all';
      return { preview, link, loaded: false };
    });
    pending = request;

    request.forEach((entry) => {
      const { preview, link } = entry;

      link.addEventListener('load', () => {
        if (pending !== request) {
          return;
        }

        entry.loaded = true;
        // System mode must be ready for either OS appearance, including a
        // change that occurs immediately after applying the preview.
        if (request.every(item => item.loaded)) {
          request.forEach(item => { item.link.media = item.preview.media; });
          applied.forEach(item => item.link.remove());
          document.querySelectorAll('link[data-active-theme]').forEach((active) => {
            active.disabled = true;
          });
          applied = request;
          pending = [];
        }
      }, { once: true });

      link.addEventListener('error', () => {
        if (pending === request) {
          pending = [];
          request.forEach(item => item.link.remove());
        }
      }, { once: true });

      preview.after(link);
    });
  };
}
