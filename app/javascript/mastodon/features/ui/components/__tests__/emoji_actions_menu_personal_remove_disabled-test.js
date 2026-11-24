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
import { EmojiActionsMenuController } from '../emoji_actions_menu_controller';

jest.mock('mastodon/initial_state', () => ({
  emojiActionsDisablePersonalRemove: true,
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

describe('personal set removal disabled in the emoji action menu', () => {
  beforeEach(() => {
    resetEmojiActionsBusForTests();
    resolveEmojiReference.mockReset();
    loadPersonalEmojiSetDocument.mockReset();
    removePersonalCategoryItem.mockReset();
    resolveEmojiReference.mockImplementation(reference => Promise.resolve({
      reference,
      actions: {
        mute: { allowed: false },
        add_to_personal_category: { allowed: true },
      },
    }));
    loadPersonalEmojiSetDocument.mockResolvedValue({
      revision: 2,
      categories: [
        { id: 'favorites', name: 'Favorites', items: [{ kind: 'unicode', native: '😀' }] },
        { id: 'empty', name: 'Empty', items: [] },
      ],
    });
  });

  afterEach(() => {
    resetEmojiActionsBusForTests();
  });

  it('keeps a registered category checked and disabled without calling removal', async () => {
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

    const registered = await screen.findByRole('button', { name: 'Already in Favorites' });
    expect(registered).toHaveAttribute('aria-disabled', 'true');
    fireEvent.click(registered);
    expect(screen.getByRole('button', { name: 'Add to Empty' })).not.toHaveAttribute('aria-disabled', 'true');

    act(() => {
      controller.current.handleRemoveFromCategory({ id: 'favorites', name: 'Favorites' });
    });
    await waitFor(() => expect(loadPersonalEmojiSetDocument).toHaveBeenCalledTimes(1));
    expect(removePersonalCategoryItem).not.toHaveBeenCalled();
    anchor.remove();
  });
});
