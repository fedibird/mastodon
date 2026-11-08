import { EmojiPicker } from 'mastodon/features/ui/util/async-components';
import { loadStandardEmojiPicker, resetStandardEmojiPickerLoaderForTests } from '../standard_emoji_loader';

jest.mock('mastodon/features/ui/util/async-components', () => ({
  EmojiPicker: jest.fn(),
}));

const Picker = () => null;
const Emoji = () => null;

describe('standard emoji loader', () => {
  beforeEach(() => {
    resetStandardEmojiPickerLoaderForTests();
    EmojiPicker.mockReset();
  });

  it('shares one in-flight import and then reuses the module', async () => {
    let resolveModule;
    const pending = new Promise(resolve => {
      resolveModule = resolve;
    });

    EmojiPicker.mockReturnValue(pending);

    const first = loadStandardEmojiPicker();
    const second = loadStandardEmojiPicker();

    expect(EmojiPicker).toHaveBeenCalledTimes(1);

    resolveModule({ Picker, Emoji, extra: true });

    const [loadedFirst, loadedSecond] = await Promise.all([first, second]);
    const third = await loadStandardEmojiPicker();

    expect(loadedFirst).toBe(loadedSecond);
    expect(loadedFirst).toBe(third);
    expect(loadedFirst).toEqual({ Picker, Emoji });
    expect(EmojiPicker).toHaveBeenCalledTimes(1);
  });

  it('drops a rejected import so the next request can try again', async () => {
    EmojiPicker.mockImplementationOnce(() => Promise.reject(new Error('offline')));

    await expect(loadStandardEmojiPicker()).rejects.toThrow('offline');

    EmojiPicker.mockImplementationOnce(() => Promise.resolve({ Picker, Emoji }));

    await expect(loadStandardEmojiPicker()).resolves.toEqual({ Picker, Emoji });
    expect(EmojiPicker).toHaveBeenCalledTimes(2);
    await expect(loadStandardEmojiPicker()).resolves.toEqual({ Picker, Emoji });
    expect(EmojiPicker).toHaveBeenCalledTimes(2);
  });

  it('does not cache a module that is missing the picker exports', async () => {
    EmojiPicker.mockImplementationOnce(() => Promise.resolve({ Picker }));
    await expect(loadStandardEmojiPicker()).rejects.toThrow(/Picker or Emoji/);

    EmojiPicker.mockImplementationOnce(() => Promise.resolve({ Picker, Emoji }));
    await expect(loadStandardEmojiPicker()).resolves.toEqual({ Picker, Emoji });
    expect(EmojiPicker).toHaveBeenCalledTimes(2);
  });
});
