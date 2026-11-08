import initialState from 'mastodon/initial_state_data';

const endpoint = '/api/v1/emoji_sets/personal';

export async function personalEmojiRequest(url, options = {}) {
  const headers = { Accept: 'application/json' };
  const token = initialState?.meta?.access_token;

  if (token) {
    headers.Authorization = `Bearer ${token}`;
  }

  if (options.body) {
    headers['Content-Type'] = 'application/json';
  }

  const response = await fetch(url, { credentials: 'same-origin', ...options, headers });
  const body = await response.json();

  if (!response.ok) {
    const error = new Error(body.error || 'Could not load personal emoji');
    error.status = response.status;
    error.code = body.code;
    error.errors = body.errors;
    throw error;
  }

  return body;
}

export const loadPersonalEmojiSet = () => personalEmojiRequest(endpoint);
export const savePersonalEmojiSet = document => personalEmojiRequest(endpoint, { method: 'PUT', body: JSON.stringify(document) });
export const resolvePersonalEmoji = emoji => personalEmojiRequest(`${endpoint}/resolve`, { method: 'POST', body: JSON.stringify(emoji) });
