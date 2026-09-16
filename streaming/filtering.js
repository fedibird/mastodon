const { JSDOM } = require('jsdom');

const INLINE_EXCLUDE_SELECTORS = [
  '.quote-inline',
  '.reference-link-inline',
  '.original-media-link',
];

const searchContentFromStatus = (status) => {
  const spoilerText = status.spoiler_text || '';
  const pollTitles = (status.poll && status.poll.options) ? status.poll.options.map(option => option.title) : [];
  const mediaDescriptions = (status.media_attachments || []).map(att => att.description);

  return [spoilerText, status.content].concat(pollTitles).concat(mediaDescriptions)
    .join('\n\n')
    .replace(/<br\s*\/?>/g, '\n')
    .replace(/<\/p><p>/g, '\n\n');
};

const searchIndexFromStatus = (status) => {
  const fragment = JSDOM.fragment(searchContentFromStatus(status));

  INLINE_EXCLUDE_SELECTORS.forEach(selector => {
    fragment.querySelectorAll(selector).forEach(node => node.remove());
  });

  return fragment.textContent;
};

const filteredResultsForStatus = (status, cachedFilters, now = new Date()) => {
  const searchIndex = searchIndexFromStatus(status);
  const filtered = [];

  Object.values(cachedFilters).forEach((cachedFilter) => {
    if (cachedFilter.expires_at === null || cachedFilter.expires_at > now) {
      const keyword_matches = searchIndex.match(cachedFilter.regexp);
      if (keyword_matches) {
        filtered.push({
          filter: cachedFilter.repr,
          keyword_matches,
          status_matches: null,
        });
      }
    }
  });

  return filtered;
};

module.exports = {
  INLINE_EXCLUDE_SELECTORS,
  searchContentFromStatus,
  searchIndexFromStatus,
  filteredResultsForStatus,
};
