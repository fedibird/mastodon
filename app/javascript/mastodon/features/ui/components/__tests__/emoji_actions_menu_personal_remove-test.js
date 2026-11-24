/**
 * @jest-environment jsdom
 */
/* eslint-disable react/prop-types */

import React from 'react';
import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react';
import {
  appendPersonalCategoryItem,
  loadPersonalEmojiSetDocument,
  removePersonalCategoryItem,
  resolveEmojiReference,
} from 'mastodon/features/emoji/emoji_actions/api';
import { openEmojiActions, resetEmojiActionsBusForTests } from 'mastodon/features/emoji/emoji_actions/bus';
import { notifySavedPersonalEmojiSet, personalEmojiStockGeneration } from 'mastodon/features/emoji/emoji_stock_source';
import { EmojiActionsMenuController } from '../emoji_actions_menu_controller';

jest.mock('mastodon/initial_state', () => ({
  emojiActionsDisablePersonalRemove: false,
  emojiPickerDisablePersonal: false,
  me: 'signed-in-user',
}));

jest.mock('react-overlays/Overlay', () => {
  return function MockOverlay({ show, children }) {
    if (!show) {
      return null;
    }

    return typeof children === 'function'
      ? children({ props: {}, arrowProps: {}, placement: 'bottom' })
      : children;
  };
});

jest.mock('mastodon/features/emoji/emoji_actions/api', () => ({
  resolveEmojiReference: jest.fn(),
  loadPersonalEmojiSetDocument: jest.fn(),
  appendPersonalCategoryItem: jest.fn(),
  removePersonalCategoryItem: jest.fn(),
  createEmojiMute: jest.fn(),
  deleteEmojiMute: jest.fn(),
}));

jest.mock('mastodon/features/emoji/emoji_stock_source', () => ({
  notifySavedPersonalEmojiSet: jest.fn(),
  personalEmojiStockGeneration: jest.fn(() => 0),
}));

jest.mock('mastodon/features/emoji/emoji_mute_store', () => ({
  currentEmojiMutes: jest.fn(() => []),
}));

const intl = {
  formatMessage: (message, values = {}) => {
    let result = message.defaultMessage || message.id;

    Object.keys(values).forEach(key => {
      result = result.replace(`{${key}}`, values[key]);
    });
    return result;
  },
};

const presentDocument = {
  revision: 4,
  categories: [
    {
      id: 'favorites',
      name: 'Favorites',
      items: [{ id: 'smile', kind: 'unicode', native: '😀' }],
    },
    {
      id: 'other',
      name: 'Other',
      items: [{ id: 'smile-2', kind: 'unicode', native: '😀' }],
    },
  ],
};

const removedDocument = {
  revision: 5,
  picker_emoji_size: 32,
  categories: [
    { id: 'favorites', name: 'Favorites', items: [] },
    presentDocument.categories[1],
  ],
  stock: { categories: [] },
  operation: { removed: true, category_id: 'favorites', item_ids: ['smile'] },
};

describe('personal set removal from the emoji action menu', () => {
  beforeEach(() => {
    resetEmojiActionsBusForTests();
    resolveEmojiReference.mockReset();
    loadPersonalEmojiSetDocument.mockReset();
    appendPersonalCategoryItem.mockReset();
    removePersonalCategoryItem.mockReset();
    notifySavedPersonalEmojiSet.mockReset();
    personalEmojiStockGeneration.mockReset();
    personalEmojiStockGeneration.mockReturnValue(0);
    resolveEmojiReference.mockImplementation(reference => Promise.resolve({
      reference,
      actions: {
        mute: { allowed: false },
        add_to_personal_category: { allowed: true },
      },
    }));
    loadPersonalEmojiSetDocument.mockResolvedValue(presentDocument);
  });

  afterEach(() => {
    cleanup();
    resetEmojiActionsBusForTests();
  });

  function renderMenu() {
    const controller = React.createRef();
    const anchor = document.createElement('button');
    document.body.appendChild(anchor);
    render(
      <EmojiActionsMenuController
        ref={controller}
        intl={intl}
        signedIn
        onSyncMutes={jest.fn(() => Promise.resolve())}
      />,
    );
    act(() => {
      openEmojiActions({ kind: 'unicode', native: '😀' }, { anchor, source: 'inline_status' });
    });
    return { controller, anchor };
  }

  it('removes one category, notifies saved stock, and leaves the other category registered', async () => {
    removePersonalCategoryItem.mockResolvedValue(removedDocument);
    const { anchor } = renderMenu();

    fireEvent.click(await screen.findByRole('button', { name: 'Remove from Favorites' }));

    await waitFor(() => expect(removePersonalCategoryItem).toHaveBeenCalledWith(
      'favorites',
      expect.objectContaining({ kind: 'unicode', native: '😀' }),
      4,
    ));
    expect(notifySavedPersonalEmojiSet).toHaveBeenCalledWith(removedDocument);
    expect(await screen.findByRole('button', { name: 'Add to Favorites' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Remove from Other' })).toBeInTheDocument();
    expect(screen.getByText('Removed from Favorites')).toBeInTheDocument();
    anchor.remove();
  });

  it('notifies a committed removal after the menu closes without painting that result', async () => {
    let resolveRemove;
    removePersonalCategoryItem.mockImplementation(() => new Promise(resolve => {
      resolveRemove = resolve;
    }));
    const { controller, anchor } = renderMenu();

    fireEvent.click(await screen.findByRole('button', { name: 'Remove from Favorites' }));
    await waitFor(() => expect(removePersonalCategoryItem).toHaveBeenCalledTimes(1));
    act(() => controller.current.handleClose());
    await act(async () => {
      resolveRemove(removedDocument);
    });

    expect(notifySavedPersonalEmojiSet).toHaveBeenCalledWith(removedDocument);
    expect(screen.queryByText('Removed from Favorites')).not.toBeInTheDocument();
    anchor.remove();
  });

  it('reloads the latest categories after a conflict and does not retry the removal', async () => {
    const error = new Error('Personal emoji set changed');
    error.code = 'conflict';
    removePersonalCategoryItem.mockRejectedValue(error);
    loadPersonalEmojiSetDocument
      .mockResolvedValueOnce(presentDocument)
      .mockResolvedValueOnce({
        revision: 8,
        categories: [
          { id: 'favorites', name: 'Favorites', items: [] },
          presentDocument.categories[1],
        ],
      });
    const { anchor } = renderMenu();

    fireEvent.click(await screen.findByRole('button', { name: 'Remove from Favorites' }));

    expect(await screen.findByText('Personal set changed. Try again.')).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Add to Favorites' })).toBeInTheDocument();
    expect(removePersonalCategoryItem).toHaveBeenCalledTimes(1);
    expect(notifySavedPersonalEmojiSet).not.toHaveBeenCalled();
    anchor.remove();
  });

  it('reloads after a deferred removal when stock generation moves, then retries with that revision', async () => {
    let resolveRemove;
    removePersonalCategoryItem.mockImplementation(() => new Promise(resolve => {
      resolveRemove = resolve;
    }));
    personalEmojiStockGeneration.mockReturnValueOnce(1).mockReturnValue(4);
    loadPersonalEmojiSetDocument
      .mockResolvedValueOnce(presentDocument)
      .mockResolvedValueOnce({
        revision: 9,
        categories: [
          { id: 'favorites', name: 'Favorites', items: [] },
          { id: 'other', name: 'Other', items: [] },
        ],
      });
    const { anchor } = renderMenu();

    fireEvent.click(await screen.findByRole('button', { name: 'Remove from Favorites' }));
    await waitFor(() => expect(removePersonalCategoryItem).toHaveBeenCalledTimes(1));
    await act(async () => {
      resolveRemove(removedDocument);
    });

    const addFavorites = await screen.findByRole('button', { name: 'Add to Favorites' });
    expect(addFavorites).not.toHaveAttribute('aria-disabled', 'true');
    expect(screen.getByRole('button', { name: 'Add to Other' })).not.toHaveAttribute('aria-disabled', 'true');
    expect(notifySavedPersonalEmojiSet).toHaveBeenCalledWith(removedDocument);

    appendPersonalCategoryItem.mockResolvedValue({
      revision: 10,
      categories: presentDocument.categories,
      stock: { categories: [] },
      operation: { added: true },
    });
    fireEvent.click(addFavorites);
    await waitFor(() => expect(appendPersonalCategoryItem).toHaveBeenCalledWith(
      'favorites',
      expect.objectContaining({ kind: 'unicode', native: '😀' }),
      9,
    ));
    anchor.remove();
  });

  it('clears busy when refreshing after a removal fails, so the same row can be tried again', async () => {
    personalEmojiStockGeneration.mockReturnValueOnce(1).mockReturnValue(4);
    loadPersonalEmojiSetDocument.mockResolvedValueOnce(presentDocument).mockRejectedValueOnce(new Error('offline'));
    removePersonalCategoryItem.mockResolvedValue(removedDocument);
    const { anchor } = renderMenu();

    fireEvent.click(await screen.findByRole('button', { name: 'Remove from Favorites' }));
    expect(await screen.findByText('Could not remove this emoji')).toBeInTheDocument();
    const retry = screen.getByRole('button', { name: 'Remove from Favorites' });
    expect(retry).not.toHaveAttribute('aria-disabled', 'true');

    personalEmojiStockGeneration.mockReturnValue(4);
    removePersonalCategoryItem.mockResolvedValue({
      ...removedDocument,
      revision: 6,
    });
    fireEvent.click(retry);
    await waitFor(() => expect(removePersonalCategoryItem).toHaveBeenCalledTimes(2));
    expect(removePersonalCategoryItem).toHaveBeenLastCalledWith(
      'favorites',
      expect.objectContaining({ kind: 'unicode', native: '😀' }),
      4,
    );
    anchor.remove();
  });

  it('reloads after a deferred add when stock generation moves, then uses the reloaded revision', async () => {
    const initial = {
      revision: 4,
      categories: [
        { id: 'favorites', name: 'Favorites', items: [] },
        { id: 'other', name: 'Other', items: [{ id: 'smile-2', kind: 'unicode', native: '😀' }] },
      ],
    };
    let resolveAdd;
    appendPersonalCategoryItem.mockImplementation(() => new Promise(resolve => {
      resolveAdd = resolve;
    }));
    personalEmojiStockGeneration.mockReturnValueOnce(2).mockReturnValue(5);
    loadPersonalEmojiSetDocument.mockResolvedValueOnce(initial).mockResolvedValueOnce({
      revision: 7,
      categories: [
        { id: 'favorites', name: 'Favorites', items: [{ id: 'smile', kind: 'unicode', native: '😀' }] },
        initial.categories[1],
      ],
    });
    const { anchor } = renderMenu();

    fireEvent.click(await screen.findByRole('button', { name: 'Add to Favorites' }));
    await waitFor(() => expect(appendPersonalCategoryItem).toHaveBeenCalledTimes(1));
    await act(async () => {
      resolveAdd({
        revision: 5,
        categories: initial.categories,
        stock: { categories: [] },
        operation: { added: true, category_id: 'favorites', item_id: 'smile' },
      });
    });

    const removeFavorites = await screen.findByRole('button', { name: 'Remove from Favorites' });
    expect(removeFavorites).not.toHaveAttribute('aria-disabled', 'true');
    expect(notifySavedPersonalEmojiSet).toHaveBeenCalledWith(expect.objectContaining({
      revision: 5,
      operation: expect.objectContaining({ added: true }),
    }));

    removePersonalCategoryItem.mockResolvedValue({
      revision: 8,
      categories: initial.categories,
      stock: { categories: [] },
      operation: { removed: true },
    });
    fireEvent.click(removeFavorites);
    await waitFor(() => expect(removePersonalCategoryItem).toHaveBeenCalledWith(
      'favorites',
      expect.objectContaining({ kind: 'unicode', native: '😀' }),
      7,
    ));
    anchor.remove();
  });
});
