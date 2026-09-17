const { JSDOM } = require('jsdom');

const INLINE_EXCLUDE_SELECTORS = [
  '.quote-inline',
  '.reference-link-inline',
  '.original-media-link',
];

// Must match FanOutOnWriteService::STREAMING_SEARCHABLE_TEXT_KEY
const STREAMING_SEARCHABLE_TEXT_KEY = '_fedibird_searchable_text';

const searchContentFromStatus = (status) => {
  const spoilerText = status.spoiler_text || '';
  const pollTitles = (status.poll && status.poll.options) ? status.poll.options.map(option => option.title) : [];
  const mediaDescriptions = (status.media_attachments || []).map(att => att.description);

  return [spoilerText, status.content].concat(pollTitles).concat(mediaDescriptions)
    .join('\n\n')
    .replace(/<br\s*\/?>/g, '\n')
    .replace(/<\/p><p>/g, '\n\n');
};

const legacySearchIndexFromSerializedStatus = (status) => {
  const fragment = JSDOM.fragment(searchContentFromStatus(status));

  INLINE_EXCLUDE_SELECTORS.forEach(selector => {
    fragment.querySelectorAll(selector).forEach(node => node.remove());
  });

  return fragment.textContent;
};

const searchIndexFromStatus = (status) => {
  if (status && typeof status[STREAMING_SEARCHABLE_TEXT_KEY] === 'string') {
    return status[STREAMING_SEARCHABLE_TEXT_KEY];
  }

  return legacySearchIndexFromSerializedStatus(status);
};

const stripStreamingSearchableText = (payload) => {
  if (!payload || typeof payload !== 'object') {
    return payload;
  }

  delete payload[STREAMING_SEARCHABLE_TEXT_KEY];

  if (payload.reblog && typeof payload.reblog === 'object') {
    delete payload.reblog[STREAMING_SEARCHABLE_TEXT_KEY];
  }

  if (payload.status && typeof payload.status === 'object') {
    delete payload.status[STREAMING_SEARCHABLE_TEXT_KEY];

    if (payload.status.reblog && typeof payload.status.reblog === 'object') {
      delete payload.status.reblog[STREAMING_SEARCHABLE_TEXT_KEY];
    }
  }

  return payload;
};

const compileKeywordRegexp = (keywords) => {
  const parts = (keywords || []).filter(([keyword]) => keyword).map(([keyword, whole_word]) => {
    let expr = String(keyword).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

    if (whole_word) {
      if (/^[\w]/.test(expr)) {
        expr = `\\b${expr}`;
      }

      if (/[\w]$/.test(expr)) {
        expr = `${expr}\\b`;
      }
    }

    return expr;
  });

  if (parts.length === 0) {
    return null;
  }

  return new RegExp(parts.join('|'), 'i');
};

const filterReprFromRow = (row) => ({
  id: row.id,
  title: row.title,
  context: row.context,
  expires_at: row.expires_at,
  filter_action: ['warn', 'hide'][row.filter_action],
});

const ensureCachedFilter = (cache, row) => {
  if (!cache[row.id]) {
    cache[row.id] = {
      keywords: [],
      statusIds: [],
      expires_at: row.expires_at,
      repr: filterReprFromRow(row),
    };
  }

  return cache[row.id];
};

const buildCachedFilters = (keywordRows, statusRows) => {
  const cache = {};

  (keywordRows || []).forEach((row) => {
    const cached = ensureCachedFilter(cache, row);

    if (row.keyword !== null && row.keyword !== undefined) {
      cached.keywords.push([row.keyword, row.whole_word]);
    }
  });

  (statusRows || []).forEach((row) => {
    const cached = ensureCachedFilter(cache, row);
    cached.statusIds.push(String(row.status_id));
  });

  Object.keys(cache).forEach((key) => {
    cache[key].regexp = compileKeywordRegexp(cache[key].keywords);
  });

  return cache;
};

const candidateStatusIds = (status) => {
  const ids = [status.id];

  if (status.reblog_of_id) {
    ids.push(status.reblog_of_id);
  }

  if (status.reblog && status.reblog.id) {
    ids.push(status.reblog.id);
  }

  return ids.map(id => String(id));
};

const filteredResultsForStatus = (status, cachedFilters, now = new Date()) => {
  const searchIndex = searchIndexFromStatus(status);
  const statusIds = candidateStatusIds(status);
  const filtered = [];

  Object.values(cachedFilters).forEach((cachedFilter) => {
    if (!(cachedFilter.expires_at === null || cachedFilter.expires_at > now)) {
      return;
    }

    const keyword_matches = cachedFilter.regexp ? searchIndex.match(cachedFilter.regexp) : null;
    const status_matches = (cachedFilter.statusIds || []).filter(id => statusIds.includes(String(id)));

    if (!keyword_matches && status_matches.length === 0) {
      return;
    }

    filtered.push({
      filter: cachedFilter.repr,
      keyword_matches: keyword_matches || null,
      status_matches: status_matches.length > 0 ? status_matches : null,
    });
  });

  return filtered;
};

module.exports = {
  INLINE_EXCLUDE_SELECTORS,
  STREAMING_SEARCHABLE_TEXT_KEY,
  searchContentFromStatus,
  searchIndexFromStatus,
  stripStreamingSearchableText,
  compileKeywordRegexp,
  buildCachedFilters,
  filteredResultsForStatus,
};
