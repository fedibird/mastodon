/**
 * @jest-environment jsdom
 */
/* eslint-disable react/prop-types */

import React from 'react';
import { act, render, screen, waitFor } from '@testing-library/react';
import {
  appendPersonalCategoryItem,
  loadPersonalEmojiSetDocument,
  resolveEmojiReference,
} from 'mastodon/features/emoji/emoji_actions/api';
import { openEmojiActions, resetEmojiActionsBusForTests } from 'mastodon/features/emoji/emoji_actions/bus';
import { currentEmojiMutes } from 'mastodon/features/emoji/emoji_mute_store';
import { EmojiActionsMenuController } from '../emoji_actions_menu_controller';

jest.mock('mastodon/initial_state', () => ({
  emojiPickerDisablePersonal: true,
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

describe('emoji actions with personal sets disabled', () => {
  beforeEach(() => {
    resetEmojiActionsBusForTests();
    resolveEmojiReference.mockReset();
    loadPersonalEmojiSetDocument.mockClear();
    appendPersonalCategoryItem.mockClear();
    currentEmojiMutes.mockReturnValue([]);

    resolveEmojiReference.mockImplementation(reference => Promise.resolve({
      reference,
      actions: {
        mute: { allowed: true },
        add_to_personal_category: { allowed: true },
      },
    }));
  });

  afterEach(() => {
    resetEmojiActionsBusForTests();
  });

  it('keeps detail and mute available without loading or adding to personal sets', async () => {
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
      openEmojiActions({ kind: 'unicode', native: '😀' }, { anchor, source: 'standard_picker' });
    });

    expect(await screen.findByRole('button', { name: 'Mute emoji' })).toBeInTheDocument();
    expect(screen.getByRole('button', { name: 'Emoji details' })).toBeInTheDocument();
    await waitFor(() => expect(resolveEmojiReference).toHaveBeenCalledTimes(1));
    expect(loadPersonalEmojiSetDocument).not.toHaveBeenCalled();
    expect(screen.queryByText('Add to Favorites')).not.toBeInTheDocument();
    expect(screen.queryByText('No personal categories yet')).not.toBeInTheDocument();

    act(() => {
      controller.current.handleAddToCategory({ id: 'cat-1', name: 'Favorites' });
    });
    expect(appendPersonalCategoryItem).not.toHaveBeenCalled();
    anchor.remove();
  });
});
