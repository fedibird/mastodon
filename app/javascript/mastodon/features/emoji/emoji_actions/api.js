import initialState from 'mastodon/initial_state_data';
import { DEFAULT_MUTE_EFFECTS, DEFAULT_MUTE_REPLACEMENT, normalizeReference } from './reference';

const mutesEndpoint = '/api/v1/fedibird/emoji_mutes';
const resolveEndpoint = '/api/v1/fedibird/emojis/resolve';
const personalEndpoint = '/api/v1/emoji_sets/personal';

function authHeaders(extra = {}) {
  const headers = { Accept: 'application/json', ...extra };
  const token = initialState?.meta?.access_token;

  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  return headers;
}

export async function emojiActionsRequest(url, options = {}) {
  const headers = authHeaders(options.body ? { 'Content-Type': 'application/json' } : {});

  if (options.headers) {
    Object.assign(headers, options.headers);
  }

  const response = await fetch(url, {
    credentials: 'same-origin',
    ...options,
    headers,
  });

  let body = null;

  try {
    body = await response.json();
  } catch (error) {
    body = null;
  }

  if (!response.ok) {
    const error = new Error((body && body.error) || 'Request failed');
    error.status = response.status;
    error.code = body && body.code;
    error.errors = body && body.errors;
    error.body = body;
    throw error;
  }

  return body;
}

export function resolveEmojiReference(emoji, context) {
  const reference = normalizeReference(emoji);
  const payload = { emoji: reference };

  if (context && (context.status_id || context.account_id)) {
    payload.context = {};

    if (context.status_id) {
      payload.context.status_id = String(context.status_id);
    }

    if (context.account_id) {
      payload.context.account_id = String(context.account_id);
    }
  }

  return emojiActionsRequest(resolveEndpoint, {
    method: 'POST',
    body: JSON.stringify(payload),
  });
}

export function loadEmojiMutesDocument() {
  return emojiActionsRequest(mutesEndpoint);
}

export function createEmojiMute(emoji, options = {}) {
  const reference = normalizeReference(emoji);
  const body = {
    emoji: reference,
    effects: options.effects || { ...DEFAULT_MUTE_EFFECTS },
    replacement: options.replacement === undefined ? DEFAULT_MUTE_REPLACEMENT : options.replacement,
  };

  return emojiActionsRequest(mutesEndpoint, {
    method: 'POST',
    body: JSON.stringify(body),
  });
}

export function updateEmojiMute(id, { expectedRevision, effects, replacement }) {
  const body = { expected_revision: String(expectedRevision) };

  if (effects) {
    body.effects = effects;
  }

  if (replacement !== undefined) {
    body.replacement = replacement;
  }

  return emojiActionsRequest(`${mutesEndpoint}/${encodeURIComponent(id)}`, {
    method: 'PATCH',
    body: JSON.stringify(body),
    headers: {
      'If-Match': `"${id}-${expectedRevision}"`,
    },
  });
}

export function deleteEmojiMute(id, expectedRevision) {
  const options = { method: 'DELETE' };

  if (expectedRevision !== null && expectedRevision !== undefined && expectedRevision !== '') {
    options.body = JSON.stringify({ expected_revision: String(expectedRevision) });
    options.headers = { 'If-Match': `"${id}-${expectedRevision}"` };
  }

  return emojiActionsRequest(`${mutesEndpoint}/${encodeURIComponent(id)}`, options);
}

export function loadPersonalEmojiSetDocument() {
  return emojiActionsRequest(personalEndpoint);
}

export function appendPersonalCategoryItem(categoryId, emoji, expectedRevision) {
  const reference = normalizeReference(emoji);

  return emojiActionsRequest(`${personalEndpoint}/categories/${encodeURIComponent(categoryId)}/items`, {
    method: 'POST',
    body: JSON.stringify({
      expected_revision: expectedRevision,
      emoji: reference,
    }),
  });
}
