import { copyText } from '../clipboard';

describe('copyText', () => {
  const originalClipboard = navigator.clipboard;

  afterEach(() => {
    if (originalClipboard === undefined) {
      delete navigator.clipboard;
    } else {
      Object.defineProperty(navigator, 'clipboard', {
        configurable: true,
        value: originalClipboard,
      });
    }

    document.body.innerHTML = '';
  });

  it('uses navigator.clipboard.writeText when it is available', async () => {
    const writeText = jest.fn(() => Promise.resolve());
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { writeText },
    });
    document.execCommand = jest.fn();

    await copyText('#test');

    expect(writeText).toHaveBeenCalledWith('#test');
    expect(document.execCommand).not.toHaveBeenCalled();
  });

  it('falls back to a textarea and execCommand when clipboard is missing', async () => {
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: undefined,
    });
    let copied = '';
    document.execCommand = jest.fn(() => {
      copied = document.body.querySelector('textarea').textContent;
      return true;
    });

    await copyText('#test #mastodon');

    expect(copied).toBe('#test #mastodon');
    expect(document.execCommand).toHaveBeenCalledWith('copy');
    expect(document.body.querySelector('textarea')).toBeNull();
  });

  it('falls back when writeText rejects', async () => {
    const writeText = jest.fn(() => Promise.reject(new Error('denied')));
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { writeText },
    });
    document.execCommand = jest.fn(() => true);

    await copyText('#fedibird');

    expect(writeText).toHaveBeenCalledWith('#fedibird');
    expect(document.execCommand).toHaveBeenCalledWith('copy');
  });
});
