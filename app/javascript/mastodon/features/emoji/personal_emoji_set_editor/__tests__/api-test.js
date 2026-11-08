import { loadPersonalEmojiSet, resolvePersonalEmoji, savePersonalEmojiSet } from '../api';

jest.mock('mastodon/initial_state_data', () => ({ __esModule: true, default: { meta: { access_token: 'editor-test-token' } } }));

const originalFetch = global.fetch;

afterEach(() => {
  global.fetch = originalFetch;
});

it('uses the authenticated personal endpoint and preserves both optimistic concurrency guards', async () => {
  global.fetch = jest.fn().mockResolvedValue({ ok: true, json: () => Promise.resolve({ revision: 5 }) });
  const document = { expected_revision: 4, expected_picker_emoji_size: 22, picker_emoji_size: 48, categories: [] };
  await loadPersonalEmojiSet();
  await savePersonalEmojiSet(document);
  expect(global.fetch.mock.calls[0][0]).toBe('/api/v1/emoji_sets/personal');
  const [url, request] = global.fetch.mock.calls[1];
  expect(url).toBe('/api/v1/emoji_sets/personal');
  expect(request.method).toBe('PUT');
  expect(request.headers.Authorization).toBe('Bearer editor-test-token');
  expect(JSON.parse(request.body)).toEqual(document);
});

it('resolves only the chosen emoji and exposes structured validation or conflict information', async () => {
  global.fetch = jest.fn().mockResolvedValue({ ok: false, status: 422, json: () => Promise.resolve({ error: 'Unavailable', code: 'unavailable', errors: [{ path: 'shortcode', code: 'unavailable_custom' }] }) });
  const request = { kind: 'custom', shortcode: 'banner' };
  await expect(resolvePersonalEmoji(request)).rejects.toMatchObject({ status: 422, code: 'unavailable', errors: [{ path: 'shortcode', code: 'unavailable_custom' }] });
  expect(global.fetch.mock.calls[0][0]).toBe('/api/v1/emoji_sets/personal/resolve');
  expect(JSON.parse(global.fetch.mock.calls[0][1].body)).toEqual(request);
});
