import uuid from '../uuid';
import { normalizeSource, sourceKey } from './source';

export const MIX_DEFINITION_VERSION = 1;
export const MIN_MIX_SOURCES = 2;
export const MAX_MIX_SOURCES = 8;
const MAX_TITLE_LENGTH = 100;

const fail = (errors) => ({ ok: false, errors });

export const normalizeMixTitle = (value) => String(value === undefined || value === null ? '' : value).trim().replace(/\s+/g, ' ');

export const prepareMix = (input, options = {}) => {
  const draft = input || {};
  const title = normalizeMixTitle(draft.title);
  const errors = [];

  if (!title) {
    errors.push('title_blank');
  } else if (title.length > MAX_TITLE_LENGTH) {
    errors.push('title_too_long');
  }

  const requestedVersion = draft.version === undefined ? MIX_DEFINITION_VERSION : draft.version;

  if (requestedVersion !== MIX_DEFINITION_VERSION) {
    errors.push('version_unsupported');
  }

  const rawSources = Array.isArray(draft.sources) ? draft.sources : [];

  if (rawSources.length < MIN_MIX_SOURCES) {
    errors.push('sources_too_few');
  }

  if (rawSources.length > MAX_MIX_SOURCES) {
    errors.push('sources_too_many');
  }

  const sources = [];
  const seen = new Set();

  rawSources.forEach(raw => {
    const normalized = normalizeSource(raw);

    if (!normalized.ok) {
      errors.push(normalized.error || 'source_invalid');
      return;
    }

    const key = sourceKey(normalized.source);

    if (seen.has(key)) {
      errors.push('source_duplicate');
      return;
    }

    seen.add(key);
    sources.push(normalized.source);
  });

  if (options.idMode === 'update' && !options.id) {
    errors.push('id_blank');
  }

  if (errors.length) {
    return fail(Array.from(new Set(errors)));
  }

  // Create never keeps an id supplied by the draft. Update keeps the id of
  // the mix that is already stored, which the caller passes in options.id.
  let id = uuid();

  if (options.idMode === 'update') {
    id = String(options.id);
  } else if (options.createId) {
    id = options.createId();
  }

  return {
    ok: true,
    mix: {
      id: String(id),
      version: MIX_DEFINITION_VERSION,
      title,
      sources,
    },
  };
};

export const emptyMixDraft = () => ({
  title: '',
  sources: [],
});

export const plainMix = (mix) => {
  if (!mix) {
    return null;
  }

  const plain = typeof mix.toJS === 'function' ? mix.toJS() : mix;

  return {
    id: plain.id ? String(plain.id) : undefined,
    version: plain.version,
    title: plain.title || '',
    sources: Array.isArray(plain.sources) ? plain.sources : [],
  };
};

export const addDraftSource = (draft, raw) => {
  const current = draft || emptyMixDraft();
  const sources = current.sources.slice();

  if (sources.length >= MAX_MIX_SOURCES) {
    return { ok: false, error: 'sources_too_many', draft: current };
  }

  const normalized = normalizeSource(raw);

  if (!normalized.ok) {
    return { ok: false, error: normalized.error || 'source_invalid', draft: current };
  }

  const key = sourceKey(normalized.source);

  if (sources.some(source => sourceKey(source) === key)) {
    return { ok: false, error: 'source_duplicate', draft: current };
  }

  sources.push(normalized.source);

  return {
    ok: true,
    draft: {
      title: current.title,
      sources,
    },
  };
};

export const removeDraftSource = (draft, index) => {
  const current = draft || emptyMixDraft();
  const sources = current.sources.filter((_, sourceIndex) => sourceIndex !== index);

  return {
    title: current.title,
    sources,
  };
};

export const moveDraftSource = (draft, index, direction) => {
  const current = draft || emptyMixDraft();
  const sources = current.sources.slice();
  const nextIndex = index + direction;

  if (index < 0 || index >= sources.length || nextIndex < 0 || nextIndex >= sources.length) {
    return current;
  }

  const moved = sources[index];
  sources[index] = sources[nextIndex];
  sources[nextIndex] = moved;

  return {
    title: current.title,
    sources,
  };
};

export const retitleDraft = (draft, title) => ({
  title,
  sources: (draft && draft.sources) || [],
});
