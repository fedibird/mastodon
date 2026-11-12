import { loadPersonalEmojiStock } from '../emoji_stock_source';
import {
  emojiPickerInitialMode,
  preloadCustomEmojiCatalogIfNeeded,
  preloadEmojiPickersIfNeeded,
} from '../emoji_picker_preferences';
import { loadStandardEmojiPicker } from '../standard_emoji_loader';

jest.mock('../emoji_stock_source', () => ({
  loadPersonalEmojiStock: jest.fn(),
}));

jest.mock('../standard_emoji_loader', () => ({
  loadStandardEmojiPicker: jest.fn(),
}));

describe('emoji picker startup preload', () => {
  beforeEach(() => {
    loadPersonalEmojiStock.mockReset();
    loadStandardEmojiPicker.mockReset();
  });

  it('does not fetch any picker data or the custom catalog with lazy loading enabled', async () => {
    const preloadCatalog = jest.fn();

    await expect(preloadEmojiPickersIfNeeded(true, false, preloadCatalog)).resolves.toEqual([null, null, null]);

    expect(loadStandardEmojiPicker).not.toHaveBeenCalled();
    expect(loadPersonalEmojiStock).not.toHaveBeenCalled();
    expect(preloadCatalog).not.toHaveBeenCalled();
  });

  it('starts standard module, personal stock and custom catalog in parallel when disabled', async () => {
    const calls = [];
    const module = { Picker: () => null, Emoji: () => null };
    const stock = { status: 'ready', stock: { categories: [] } };
    let completeCatalog;
    const pendingCatalog = new Promise(resolve => {
      completeCatalog = resolve;
    });

    loadStandardEmojiPicker.mockImplementation(() => {
      calls.push('standard');
      return Promise.resolve(module);
    });
    loadPersonalEmojiStock.mockImplementation(() => {
      calls.push('personal');
      return Promise.resolve(stock);
    });
    const preloadCatalog = jest.fn(() => {
      calls.push('catalog');
      return pendingCatalog;
    });

    const loading = preloadEmojiPickersIfNeeded(false, false, preloadCatalog);

    // All three have started before the catalog response arrives.
    await Promise.resolve();
    expect(calls).toEqual(['standard', 'personal', 'catalog']);
    expect(preloadCatalog).toHaveBeenCalledTimes(1);
    expect(loadStandardEmojiPicker).toHaveBeenCalledTimes(1);
    expect(loadPersonalEmojiStock).toHaveBeenCalledTimes(1);

    completeCatalog('loaded');
    await expect(loading).resolves.toEqual([module, stock, 'loaded']);
  });

  it('forces standard mode and skips only private stock when personal sets are disabled', async () => {
    const module = { Picker: () => null, Emoji: () => null };
    const preloadCatalog = jest.fn().mockResolvedValue(['custom']);
    loadStandardEmojiPicker.mockResolvedValue(module);

    expect(emojiPickerInitialMode(true, true)).toBe('standard');
    expect(emojiPickerInitialMode(false, true)).toBe('standard');
    expect(emojiPickerInitialMode(true, false)).toBe('personal');

    await expect(preloadEmojiPickersIfNeeded(false, true, preloadCatalog)).resolves.toEqual([
      module,
      null,
      ['custom'],
    ]);
    expect(loadStandardEmojiPicker).toHaveBeenCalledTimes(1);
    expect(loadPersonalEmojiStock).not.toHaveBeenCalled();
    expect(preloadCatalog).toHaveBeenCalledTimes(1);
  });

  it('does not reject application startup when any preload fails', async () => {
    loadStandardEmojiPicker.mockRejectedValue(new Error('module unavailable'));
    loadPersonalEmojiStock.mockRejectedValue(new Error('stock offline'));
    const preloadCatalog = jest.fn().mockRejectedValue(new Error('catalog offline'));

    await expect(preloadEmojiPickersIfNeeded(false, false, preloadCatalog)).resolves.toEqual([null, null, null]);

    expect(loadStandardEmojiPicker).toHaveBeenCalledTimes(1);
    expect(loadPersonalEmojiStock).toHaveBeenCalledTimes(1);
    expect(preloadCatalog).toHaveBeenCalledTimes(1);
  });

  it('catches a synchronous catalog dispatch error and skips missing dispatch callbacks', async () => {
    const dispatch = jest.fn(() => {
      throw new Error('store unavailable');
    });

    const pending = preloadCustomEmojiCatalogIfNeeded(dispatch, false);
    expect(dispatch).not.toHaveBeenCalled();
    await expect(pending).resolves.toBeNull();
    expect(dispatch).toHaveBeenCalledTimes(1);

    await expect(preloadCustomEmojiCatalogIfNeeded(null, false)).resolves.toBeNull();
    await expect(preloadCustomEmojiCatalogIfNeeded(dispatch, true)).resolves.toBeNull();
    expect(dispatch).toHaveBeenCalledTimes(1);
  });
});
