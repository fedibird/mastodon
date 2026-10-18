import {
  normalizeReadingBookmark,
  readingBookmarkPayload,
  readingBookmarkPayloadFromPosition,
} from './contract';

const PATH = '/api/v1/fedibird/reading_bookmarks';

const build = (input) => (
  input && input.position ? readingBookmarkPayloadFromPosition(input) : readingBookmarkPayload(input || {})
);

const accept = (response) => normalizeReadingBookmark(response.data);

export const fetchReadingBookmarks = (client) => (
  client.get(PATH).then(response => (response.data || []).map(normalizeReadingBookmark))
);

export const fetchReadingBookmark = (client, id) => (
  client.get(`${PATH}/${id}`).then(accept)
);

export const fetchReadingBookmarkCapabilities = (client) => (
  client.get(`${PATH}/capabilities`).then(response => response.data)
);

export const createReadingBookmark = (client, input) => {
  const built = build(input);

  if (!built.ok) {
    return Promise.reject(built);
  }

  return client.post(PATH, built.payload).then(accept);
};

export const updateReadingBookmark = (client, id, input) => {
  const built = build(input);

  if (!built.ok) {
    return Promise.reject(built);
  }

  return client.patch(`${PATH}/${id}`, built.payload).then(accept);
};

export const deleteReadingBookmark = (client, id) => (
  client.delete(`${PATH}/${id}`).then(response => response.data)
);
