const deferred = () => {
  const box = {};

  box.promise = new Promise((resolve, reject) => {
    box.resolve = resolve;
    box.reject = reject;
  });

  return box;
};

const documentFor = (revision, size = 22) => ({
  revision,
  picker_emoji_size: size,
  stock: { categories: [{ id: 'one', name: `Category ${revision}`, heading: { text: 'C' }, items: [] }] },
});

describe('personal emoji stock source', () => {
  let source;
  let get;
  let unsubscribers;

  beforeEach(() => {
    jest.resetModules();
    get = jest.fn();
    unsubscribers = [];
    jest.doMock('mastodon/api', () => ({ __esModule: true, default: () => ({ get }) }));
    jest.doMock('mastodon/initial_state_data', () => ({
      __esModule: true,
      default: { meta: { access_token: 'test-token', me: 'account-1', picker_emoji_size: 22 } },
    }));
    source = require('../emoji_stock_source');
  });

  afterEach(() => {
    unsubscribers.forEach(unsubscribe => unsubscribe());
    localStorage.clear();
    jest.dontMock('mastodon/api');
    jest.dontMock('mastodon/initial_state_data');
  });

  it('requests only registered stock and revalidates with an ETag on each open', async () => {
    const document = documentFor(1);

    get.mockResolvedValueOnce({ status: 200, data: document, headers: { etag: 'resolved-v1' } });
    expect(source.getCachedPersonalEmojiStock()).toBeNull();
    expect(await source.loadPersonalEmojiStock()).toEqual({ status: 'ready', stock: document.stock });
    expect(source.getCachedPersonalEmojiStock()).toEqual({ status: 'ready', stock: document.stock });
    expect(get).toHaveBeenCalledWith('/api/v1/emoji_sets/personal/stock', expect.objectContaining({
      headers: { Authorization: 'Bearer test-token' },
    }));

    get.mockResolvedValueOnce({ status: 304, headers: {} });
    expect((await source.loadPersonalEmojiStock()).stock).toBe(document.stock);
    expect(get).toHaveBeenLastCalledWith('/api/v1/emoji_sets/personal/stock', expect.objectContaining({
      headers: { Authorization: 'Bearer test-token', 'If-None-Match': 'resolved-v1' },
    }));

    const changedAsset = documentFor(1);

    changedAsset.stock.categories[0].heading.image = { src: '/new-custom-image.png' };
    get.mockResolvedValueOnce({ status: 200, data: changedAsset, headers: { etag: 'resolved-v2' } });
    expect((await source.loadPersonalEmojiStock()).stock).toBe(changedAsset.stock);
  });

  it('shares simultaneous reads and refuses a late pre-save response', async () => {
    const pending = deferred();
    const changed = jest.fn();
    const sizeChanged = jest.fn();

    get.mockReturnValueOnce(pending.promise);
    unsubscribers.push(source.subscribePersonalEmojiStock(changed), source.subscribePickerEmojiSize(sizeChanged));

    const first = source.loadPersonalEmojiStock();
    const second = source.loadPersonalEmojiStock();

    expect(first).toBe(second);
    expect(get).toHaveBeenCalledTimes(1);

    const saved = documentFor(2, 48);

    source.notifySavedPersonalEmojiSet(saved);
    pending.resolve({ status: 200, data: documentFor(1), headers: { etag: 'old' } });
    expect(await first).toEqual({ status: 'ready', stock: saved.stock });
    expect(changed).toHaveBeenCalledWith({ status: 'ready', stock: saved.stock });
    expect(sizeChanged).toHaveBeenCalledWith(48);
    expect(source.getPickerEmojiSize()).toBe(48);
    expect(localStorage.getItem('mastodon:personal-emoji-set:account-1')).not.toContain('test-token');
    expect(localStorage.getItem('mastodon:personal-emoji-set:account-1')).not.toContain('Category');
  });

  it('invalidates other tabs and fetches trusted stock and size again', async () => {
    const changed = jest.fn();
    const sizeChanged = jest.fn();

    unsubscribers.push(source.subscribePersonalEmojiStock(changed), source.subscribePickerEmojiSize(sizeChanged));
    source.notifySavedPersonalEmojiSet(documentFor(1));
    changed.mockClear();
    get.mockResolvedValueOnce({ status: 200, data: documentFor(2, 40), headers: { etag: 'new' } });

    window.dispatchEvent(new StorageEvent('storage', { key: 'mastodon:personal-emoji-set:someone-else' }));
    expect(changed).not.toHaveBeenCalled();
    window.dispatchEvent(new StorageEvent('storage', { key: 'mastodon:personal-emoji-set:account-1', newValue: 'untrusted-marker' }));
    expect(changed).toHaveBeenCalledWith(null);
    expect(source.getCachedPersonalEmojiStock()).toBeNull();
    await source.loadPersonalEmojiStock();
    expect(sizeChanged).toHaveBeenCalledWith(40);
    expect(get).toHaveBeenCalledTimes(1);
    expect(get.mock.calls[0][1].headers['If-None-Match']).toBeUndefined();
  });

  it('allows retries after failed or malformed responses', async () => {
    get.mockRejectedValueOnce(new Error('offline'));
    await expect(source.loadPersonalEmojiStock()).rejects.toThrow('offline');
    get.mockResolvedValueOnce({ status: 200, data: {}, headers: {} });
    await expect(source.loadPersonalEmojiStock()).rejects.toThrow('Invalid personal emoji stock');
    get.mockResolvedValueOnce({ status: 200, data: documentFor(1), headers: {} });
    await expect(source.loadPersonalEmojiStock()).resolves.toHaveProperty('status', 'ready');
  });

  it('refreshes the size after a save in another tab while all dropdowns were closed', async () => {
    localStorage.setItem('mastodon:personal-emoji-set:account-1', 'another-tab-saved');
    get.mockResolvedValueOnce({ status: 200, data: documentFor(5, 46), headers: {} });

    const sizeChanged = jest.fn();

    unsubscribers.push(source.subscribePickerEmojiSize(sizeChanged));
    await source.loadPersonalEmojiStock();
    expect(sizeChanged).toHaveBeenCalledWith(46);
    expect(get).toHaveBeenCalledTimes(1);
  });

  it('does not retry automatically when a newer read superseding an old one fails', async () => {
    const old = deferred();
    const current = deferred();

    get.mockReturnValueOnce(old.promise).mockReturnValueOnce(current.promise);
    unsubscribers.push(source.subscribePersonalEmojiStock(() => {}));
    const first = source.loadPersonalEmojiStock();

    window.dispatchEvent(new StorageEvent('storage', { key: 'mastodon:personal-emoji-set:account-1', newValue: 'changed' }));
    const second = source.loadPersonalEmojiStock();
    const firstResult = expect(first).rejects.toThrow('offline');
    const secondResult = expect(second).rejects.toThrow('offline');

    old.resolve({ status: 200, data: documentFor(1), headers: {} });
    current.reject(new Error('offline'));
    await Promise.all([firstResult, secondResult]);
    expect(get).toHaveBeenCalledTimes(2);
  });

  it('keeps a newer failed outcome when the superseded read finishes last', async () => {
    const old = deferred();
    const current = deferred();

    get.mockReturnValueOnce(old.promise).mockReturnValueOnce(current.promise);
    unsubscribers.push(source.subscribePersonalEmojiStock(() => {}));
    const first = source.loadPersonalEmojiStock();
    const firstResult = expect(first).rejects.toThrow('newer offline');

    window.dispatchEvent(new StorageEvent('storage', { key: 'mastodon:personal-emoji-set:account-1', newValue: 'changed' }));
    const second = source.loadPersonalEmojiStock();
    const secondResult = expect(second).rejects.toThrow('newer offline');

    current.reject(new Error('newer offline'));
    await secondResult;
    old.resolve({ status: 200, data: documentFor(1), headers: {} });
    await firstResult;
    expect(get).toHaveBeenCalledTimes(2);
  });
});
