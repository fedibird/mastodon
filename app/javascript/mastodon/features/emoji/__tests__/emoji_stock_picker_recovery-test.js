import React from 'react';
import { fireEvent, render, screen, waitFor } from '@testing-library/react';

jest.mock('react-intl', () => {
  const intl = { formatMessage: descriptor => descriptor.defaultMessage };

  return {
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
  };
});

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

describe('open personal picker after a stale stock read', () => {
  let get;
  let source;
  let view;

  beforeEach(() => {
    jest.resetModules();
    get = jest.fn();
    jest.doMock('mastodon/api', () => ({ __esModule: true, default: () => ({ get }) }));
    jest.doMock('mastodon/initial_state_data', () => ({
      __esModule: true,
      default: { meta: { access_token: 'test-token', me: 'account-1', picker_emoji_size: 22 } },
    }));
    source = require('../emoji_stock_source');
    require('../emoji_mute_store').installEmojiMutesForTests({ revision: '1', emoji_mutes: [] });
    const EmojiPickerShell = require('../emoji_picker_shell').default;
    const pending = deferred();

    get.mockReturnValueOnce(pending.promise);
    view = render(<EmojiPickerShell initialMode='personal' onPick={jest.fn()} />);
    pending.resolve({ status: 200, data: documentFor(4, 28), headers: { etag: 'rev4' } });
  });

  afterEach(() => {
    view.unmount();
    localStorage.clear();
    jest.dontMock('mastodon/api');
    jest.dontMock('mastodon/initial_state_data');
  });

  it('shows the committed stock after one follow-up read', async () => {
    const changeKey = 'mastodon:personal-emoji-set:account-1';
    const stale = deferred();
    const followUp = deferred();

    expect(await screen.findByRole('button', { name: 'Category 4' })).toBeInTheDocument();

    get.mockReturnValueOnce(stale.promise);
    localStorage.setItem(changeKey, 'tab-b-rev5');
    window.dispatchEvent(new StorageEvent('storage', { key: changeKey, newValue: 'tab-b-rev5' }));
    expect(source.notifySavedPersonalEmojiSet(documentFor(6, 40))).toBe(false);
    expect(source.getPickerEmojiSize()).toBe(28);

    get.mockReturnValueOnce(followUp.promise);
    stale.resolve({ status: 200, data: documentFor(5, 22), headers: { etag: 'rev5' } });
    await Promise.resolve();
    expect(screen.queryByRole('button', { name: 'Category 5' })).not.toBeInTheDocument();
    expect(screen.queryByText('Could not load emojis')).not.toBeInTheDocument();
    expect(source.getPickerEmojiSize()).toBe(28);

    followUp.resolve({ status: 200, data: documentFor(6, 44), headers: { etag: 'rev6' } });

    expect(await screen.findByRole('button', { name: 'Category 6' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Category 5' })).not.toBeInTheDocument();
    expect(screen.queryByText('Could not load emojis')).not.toBeInTheDocument();
    expect(source.getPickerEmojiSize()).toBe(44);
    const marker = localStorage.getItem(changeKey);
    expect(marker).not.toBe('tab-b-rev5');
    expect(marker).not.toContain('Category');
    expect(localStorage.getItem(changeKey)).toBe(marker);
  });

  it('shows an error and can retry when that follow-up read fails', async () => {
    const changeKey = 'mastodon:personal-emoji-set:account-1';
    const stale = deferred();

    expect(await screen.findByRole('button', { name: 'Category 4' })).toBeInTheDocument();

    get.mockReturnValueOnce(stale.promise);
    localStorage.setItem(changeKey, 'tab-b-rev5');
    window.dispatchEvent(new StorageEvent('storage', { key: changeKey, newValue: 'tab-b-rev5' }));
    expect(source.notifySavedPersonalEmojiSet(documentFor(6, 40))).toBe(false);

    get.mockRejectedValueOnce(new Error('offline'));
    stale.resolve({ status: 200, data: documentFor(5, 22), headers: { etag: 'rev5' } });

    expect(await screen.findByText('Could not load emojis')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Category 6' })).not.toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Category 5' })).not.toBeInTheDocument();
    expect(source.getPickerEmojiSize()).toBe(28);

    get.mockResolvedValueOnce({ status: 200, data: documentFor(6, 44), headers: { etag: 'rev6' } });
    fireEvent.click(screen.getByRole('button', { name: 'Try again' }));

    expect(await screen.findByRole('button', { name: 'Category 6' })).toBeInTheDocument();
    await waitFor(() => expect(source.getPickerEmojiSize()).toBe(44));
    expect(screen.queryByText('Could not load emojis')).not.toBeInTheDocument();
  });
});
