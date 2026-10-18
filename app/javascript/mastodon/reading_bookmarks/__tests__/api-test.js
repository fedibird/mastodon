import {
  createReadingBookmark,
  deleteReadingBookmark,
  fetchReadingBookmarkCapabilities,
  fetchReadingBookmarks,
  updateReadingBookmark,
} from '../api';

const serverRow = {
  id: '4',
  name: 'Morning',
  source: 'home',
  source_timeline_id: 'home',
  context: {},
  anchor: {
    version: 1,
    status_id: '15',
    offset_px: 3,
    alignment: 'top',
  },
  source_label: null,
  availability: { source: 'available', resume: 'manual' },
  lock_version: 0,
  text: 'not-returned',
};

const anchor = {
  version: 1,
  statusId: '15',
  offsetPx: 3,
  alignment: 'top',
};

describe('reading bookmark api', () => {
  it('lists, creates, updates, and deletes owner rows', async () => {
    const client = {
      get: jest.fn(() => Promise.resolve({ data: [serverRow] })),
      post: jest.fn(() => Promise.resolve({ data: serverRow })),
      patch: jest.fn(() => Promise.resolve({ data: { ...serverRow, name: 'Later', lock_version: 1 } })),
      delete: jest.fn(() => Promise.resolve({ data: {} })),
    };

    const listed = await fetchReadingBookmarks(client);
    expect(client.get).toHaveBeenCalledWith('/api/v1/fedibird/reading_bookmarks');
    expect(listed[0].text).toBeUndefined();
    expect(listed[0].anchor.statusId).toBe('15');

    await createReadingBookmark(client, {
      name: 'Morning',
      contract: { source: 'home', params: {} },
      anchor,
    });
    expect(client.post.mock.calls[0][0]).toBe('/api/v1/fedibird/reading_bookmarks');
    expect(client.post.mock.calls[0][1].source).toBe('home');
    expect(client.post.mock.calls[0][1].view).toBeUndefined();

    await updateReadingBookmark(client, '4', {
      name: 'Later',
      contract: { source: 'home', params: {} },
      anchor,
      lockVersion: 0,
    });
    expect(client.patch.mock.calls[0][0]).toBe('/api/v1/fedibird/reading_bookmarks/4');
    expect(client.patch.mock.calls[0][1].lock_version).toBe(0);

    await deleteReadingBookmark(client, '4');
    expect(client.delete).toHaveBeenCalledWith('/api/v1/fedibird/reading_bookmarks/4');
  });

  it('does not post a payload that failed the contract', async () => {
    const client = { post: jest.fn() };

    await expect(createReadingBookmark(client, {
      name: 'Find',
      contract: { source: 'home', params: { query: 'hidden-query-zz' } },
      anchor,
    })).rejects.toMatchObject({ reason: 'search_or_content_not_accepted' });

    expect(client.post).not.toHaveBeenCalled();
  });

  it('reads the capability map from its own path', async () => {
    const client = {
      get: jest.fn(() => Promise.resolve({ data: { per_user_limit: 50 } })),
    };

    const body = await fetchReadingBookmarkCapabilities(client);

    expect(client.get).toHaveBeenCalledWith('/api/v1/fedibird/reading_bookmarks/capabilities');
    expect(body.per_user_limit).toBe(50);
  });
});
