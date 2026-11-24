/**
 * @jest-environment jsdom
 */
/* eslint-disable react/prop-types */

import React from 'react';
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import {
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
    expect(notifySavedPersonalEmojiSet).toHaveBeenCalledWith(removedDocument, 0);
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

    expect(notifySavedPersonalEmojiSet).toHaveBeenCalledWith(removedDocument, 0);
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

  it('drops a delayed removal that is older than a newer stock generation', async () => {
    personalEmojiStockGeneration.mockReturnValueOnce(1).mockReturnValue(2);
    removePersonalCategoryItem.mockResolvedValue(removedDocument);
    const { anchor } = renderMenu();

    fireEvent.click(await screen.findByRole('button', { name: 'Remove from Favorites' }));
    await waitFor(() => expect(removePersonalCategoryItem).toHaveBeenCalledTimes(1));

    expect(notifySavedPersonalEmojiSet).not.toHaveBeenCalled();
    expect(screen.getByRole('button', { name: 'Remove from Favorites' })).toBeInTheDocument();
    expect(screen.queryByText('Removed from Favorites')).not.toBeInTheDocument();
    anchor.remove();
  });
});
