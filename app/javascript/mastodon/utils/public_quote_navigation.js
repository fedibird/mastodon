// Clicks on media controls inside a public quote must not follow the quote.
// The concealed-audio button is not inside .audio-player until it is revealed.

const QUOTE_CLICK_IGNORE = [
  '.status__content__spoiler-link',
  '.media-gallery',
  '.video-player',
  '.audio-player',
  '.status-media-stack__audio-hidden',
];

export const quoteClickStaysInside = (target) => {
  if (!target || typeof target.closest !== 'function') {
    return false;
  }

  return QUOTE_CLICK_IGNORE.some(selector => target.closest(selector));
};

export const handlePublicQuoteClick = (event) => {
  const target = event && event.target;

  if (quoteClickStaysInside(target)) {
    return false;
  }

  const quote = target && target.closest && target.closest('.quote-status');
  if (!quote) {
    return false;
  }

  let url = quote.getAttribute('dataurl');

  if (target.closest('.status__display-name')) {
    url = target.closest('.status__display-name').getAttribute('href');
  } else if (target.closest('.detailed-status__display-name')) {
    url = target.closest('.detailed-status__display-name').getAttribute('href');
  } else if (target.closest('.status-card')) {
    url = target.closest('.status-card').getAttribute('href');
  }

  if (!url) {
    return false;
  }

  const host = url.split('/')[2];
  if (host && window.location.hostname === host.split(':')[0]) {
    window.location.href = url;
  } else {
    window.open(url, 'blank');
  }

  return false;
};
