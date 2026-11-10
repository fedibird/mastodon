import React from 'react';
import { act, render, screen, waitFor } from '@testing-library/react';
import EmojiPickerShell from '../emoji_picker_shell';
import { getCachedPersonalEmojiStock, loadPersonalEmojiStock, subscribePersonalEmojiStock } from '../emoji_stock_source';

jest.mock('react-intl', () => {
  const intl = { formatMessage: descriptor => descriptor.defaultMessage };

  return {
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
  };
});

jest.mock('../emoji_stock_source', () => ({
  getCachedPersonalEmojiStock: jest.fn(),
  loadPersonalEmojiStock: jest.fn(),
  subscribePersonalEmojiStock: jest.fn(() => () => {}),
}));

function stockFor(label) {
  return {
    categories: [{
      id: 'favorite',
      name: 'Favorite',
      items: [{
        key: `item-${label}`,
        label,
        image: { src: '/test.svg', alt: label },
        search: [label],
        selection: { id: label, native: label, custom: false },
      }],
    }],
  };
}

function deferred() {
  const pending = {};

  pending.promise = new Promise((resolve, reject) => {
    pending.resolve = resolve;
    pending.reject = reject;
  });
  return pending;
}

describe('personal picker warm stock', () => {
  beforeEach(() => {
    getCachedPersonalEmojiStock.mockReset();
    loadPersonalEmojiStock.mockReset();
    subscribePersonalEmojiStock.mockClear();
  });

  it('renders preloaded stock immediately and replaces it after a background refresh', async () => {
    const pending = deferred();

    getCachedPersonalEmojiStock.mockReturnValue({ status: 'ready', stock: stockFor('Warm emoji') });
    loadPersonalEmojiStock.mockReturnValue(pending.promise);

    render(<EmojiPickerShell initialMode='personal' onPick={jest.fn()} />);

    expect(screen.getByRole('button', { name: 'Warm emoji' })).toBeInTheDocument();
    expect(screen.queryByText('Loading emojis')).not.toBeInTheDocument();
    await waitFor(() => expect(loadPersonalEmojiStock).toHaveBeenCalledTimes(1));

    await act(async () => {
      pending.resolve({ status: 'ready', stock: stockFor('Updated emoji') });
      await pending.promise;
    });

    expect(screen.getByRole('button', { name: 'Updated emoji' })).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Warm emoji' })).not.toBeInTheDocument();
  });

  it('keeps preloaded stock when background revalidation fails', async () => {
    const pending = deferred();

    getCachedPersonalEmojiStock.mockReturnValue({ status: 'ready', stock: stockFor('Offline emoji') });
    loadPersonalEmojiStock.mockReturnValue(pending.promise);

    render(<EmojiPickerShell initialMode='personal' onPick={jest.fn()} />);

    expect(screen.getByRole('button', { name: 'Offline emoji' })).toBeInTheDocument();
    await waitFor(() => expect(loadPersonalEmojiStock).toHaveBeenCalledTimes(1));

    await act(async () => {
      pending.reject(new Error('offline'));
      await pending.promise.catch(() => {});
    });

    expect(screen.getByRole('button', { name: 'Offline emoji' })).toBeInTheDocument();
    expect(screen.queryByText('Could not load emojis')).not.toBeInTheDocument();
  });

  it('still shows loading and errors when no cache is available', async () => {
    getCachedPersonalEmojiStock.mockReturnValue(null);
    loadPersonalEmojiStock.mockRejectedValue(new Error('offline'));

    render(<EmojiPickerShell initialMode='personal' onPick={jest.fn()} />);

    expect(await screen.findByText('Could not load emojis')).toBeInTheDocument();
    expect(screen.queryByRole('button', { name: 'Offline emoji' })).not.toBeInTheDocument();
  });
});
