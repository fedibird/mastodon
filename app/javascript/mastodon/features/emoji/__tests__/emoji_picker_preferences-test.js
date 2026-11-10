import { loadPersonalEmojiStock } from '../emoji_stock_source';
import { preloadEmojiPickersIfNeeded } from '../emoji_picker_preferences';
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

  it('does not fetch either picker when lazy loading is enabled', async () => {
    await expect(preloadEmojiPickersIfNeeded(true)).resolves.toEqual([null, null]);

    expect(loadStandardEmojiPicker).not.toHaveBeenCalled();
    expect(loadPersonalEmojiStock).not.toHaveBeenCalled();
  });

  it('starts standard module and personal stock loading together when disabled', async () => {
    const calls = [];

    loadStandardEmojiPicker.mockImplementation(() => {
      calls.push('standard');
      return Promise.resolve({ Picker: () => null, Emoji: () => null });
    });
    loadPersonalEmojiStock.mockImplementation(() => {
      calls.push('personal');
      return Promise.resolve({ status: 'ready', stock: { categories: [] } });
    });

    await preloadEmojiPickersIfNeeded(false);

    expect(calls).toEqual(['standard', 'personal']);
    expect(loadStandardEmojiPicker).toHaveBeenCalledTimes(1);
    expect(loadPersonalEmojiStock).toHaveBeenCalledTimes(1);
  });

  it('does not reject startup when either preload fails', async () => {
    loadStandardEmojiPicker.mockRejectedValue(new Error('module unavailable'));
    loadPersonalEmojiStock.mockRejectedValue(new Error('stock offline'));

    await expect(preloadEmojiPickersIfNeeded(false)).resolves.toEqual([null, null]);
    expect(loadStandardEmojiPicker).toHaveBeenCalledTimes(1);
    expect(loadPersonalEmojiStock).toHaveBeenCalledTimes(1);
  });
});
