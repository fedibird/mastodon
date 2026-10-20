import { getEmbeddedScreen, isEmbeddedSettingsUrl, isPostingStylesSettingsUrl } from '../registry';

const origin = 'http://localhost';
const allowed = (path, method = 'GET') => isPostingStylesSettingsUrl(new URL(path, origin), origin, method);

it.each([
  ['/settings/user_posting_contexts', 'GET'],
  ['/settings/user_posting_contexts/new', 'GET'],
  ['/settings/user_posting_contexts/12/edit', 'GET'],
  ['/settings/user_posting_contexts/12/confirm_destroy', 'GET'],
  ['/settings/user_posting_contexts', 'POST'],
  ['/settings/user_posting_contexts/update_usual', 'POST'],
  ['/settings/user_posting_contexts/12', 'PATCH'],
  ['/settings/user_posting_contexts/12', 'PUT'],
  ['/settings/user_posting_contexts/12', 'DELETE'],
  ['/settings/user_posting_contexts/12/duplicate', 'POST'],
  ['/settings/user_posting_context_assignments?page=2&user_posting_context_id=12', 'GET'],
  ['/settings/user_posting_context_assignments/12/release', 'POST'],
  ['/settings/user_posting_context_assignments/12/decline', 'POST'],
])('allows the real route %s via %s', (path, method = 'GET') => expect(allowed(path, method)).toBe(true));

it.each([
  ['/filters'], ['/auth/sign_in'], ['/settings/preferences'],
  ['https://evil.test/settings/user_posting_contexts'],
  ['/settings/user_posting_contexts/0/edit'], ['/settings/user_posting_contexts/-1/edit'],
  ['/settings/user_posting_contexts/1'], ['/settings/user_posting_contexts/1/duplicate'],
  ['/settings/user_posting_contexts/preview'], ['/settings/user_posting_contexts/preview', 'POST'],
  ['/settings/user_posting_contexts/1/preview'],
  ['/settings/user_posting_context_assignments/1'], ['/settings/user_posting_context_assignments/1/release'],
  ['/settings/user_posting_contexts?return_to=/filters'], ['/settings/user_posting_contexts?embedded=0'],
  ['/settings/user_posting_contexts?embedded=1&embedded=1'],
  ['/settings/user_posting_context_assignments?page=-1'], ['/settings/user_posting_context_assignments?page=2&page=3'],
  ['/settings/user_posting_context_assignments?user_posting_context_id=https://evil.test'],
  ['/settings/user_posting_contexts#anything'], ['/settings/user_posting_contexts/1/edit', 'POST'],
].map(([path, method]) => [path, method || 'GET']))('rejects an unexpected route/method/query %s %s', (path, method = 'GET') => expect(allowed(path, method)).toBe(false));

it('keeps screens separate and requires literal embedded mode', () => {
  expect(getEmbeddedScreen('postingStyles').embeddedPath).toBe('/settings/user_posting_contexts?embedded=1');
  expect(isEmbeddedSettingsUrl('postingStyles', new URL('/filters?embedded=1', origin), origin)).toBe(false);
  expect(isEmbeddedSettingsUrl('filters', new URL('/settings/user_posting_contexts?embedded=1', origin), origin)).toBe(false);
  expect(isEmbeddedSettingsUrl('postingStyles', new URL('/settings/user_posting_contexts', origin), origin)).toBe(false);
});
