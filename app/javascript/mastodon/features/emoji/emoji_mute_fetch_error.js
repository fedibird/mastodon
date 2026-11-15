// 401 means the session must be renewed. 403 means this token cannot read
// the document. Neither is fixed by repeating the GET. Everything else,
// including a timeout, can be retried by the viewer.
export function classifyEmojiMuteFetchError(error) {
  const status = error && error.response ? Number(error.response.status) : NaN;

  if (status === 401) {
    return 'unauthorized';
  }

  if (status === 403) {
    return 'forbidden';
  }

  return 'unavailable';
}
