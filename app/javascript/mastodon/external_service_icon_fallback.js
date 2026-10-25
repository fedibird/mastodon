const SELECTOR = 'img.external-service-feed__icon-image';

const dropBroken = (img) => {
  if (img.parentNode) {
    img.parentNode.removeChild(img);
  }
};

export function initExternalServiceIconFallback(doc = document) {
  doc.addEventListener('error', ({ target }) => {
    if (target && target.matches && target.matches(SELECTOR)) {
      dropBroken(target);
    }
  }, true);

  const sweep = () => {
    doc.querySelectorAll(SELECTOR).forEach((img) => {
      if (img.complete && img.naturalWidth === 0) {
        dropBroken(img);
      }
    });
  };

  if (doc.readyState === 'loading') {
    doc.addEventListener('DOMContentLoaded', sweep);
  } else {
    sweep();
  }
}
