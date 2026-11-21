/**
 * @jest-environment jsdom
 */

import React from 'react';
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { createEmojiMute } from 'mastodon/features/emoji/emoji_actions/api';
import { openEmojiActions, resetEmojiActionsBusForTests } from 'mastodon/features/emoji/emoji_actions/bus';
import { noteEmojiMuteDisabledLocally, resetEmojiMuteBootForTests } from 'mastodon/features/emoji/emoji_mute_availability';

jest.mock('mastodon/initial_state_data', () => ({
  meta: {
    me: '1',
    access_token: 'token',
    emoji_mute_enabled_known: true,
    emoji_mute_enabled: false,
    emoji_mute_modal: true,
  },
}));
import { EmojiActionsMenuController } from '../emoji_actions_menu_controller';

jest.mock('mastodon/initial_state', () => ({
  emojiPickerDisablePersonal: true,
  me: 'signed-in-user',
}));

jest.mock('mastodon/features/emoji/emoji_actions/api', () => ({
  resolveEmojiReference: jest.fn(reference => Promise.resolve({
    reference,
    actions: { mute: { allowed: true } },
  })),
  loadPersonalEmojiSetDocument: jest.fn(),
  appendPersonalCategoryItem: jest.fn(),
  createEmojiMute: jest.fn(() => Promise.resolve({ mute: { id: 'm1' }, revision: '2', emoji_mute_enabled: true })),
  deleteEmojiMute: jest.fn(),
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

const intl = {
  formatMessage: message => message.defaultMessage || message.id,
};

describe('emoji mute confirmation identity', () => {
  beforeEach(() => {
    resetEmojiActionsBusForTests();
    resetEmojiMuteBootForTests();
    createEmojiMute.mockClear();
    noteEmojiMuteDisabledLocally();
  });

  it('does not mute a different emoji if the menu changes before confirm', async () => {
    let confirm = null;
    const anchor = document.createElement('button');
    function onConfirm(config) {
      confirm = config.onConfirm;
    }
    const onSyncMutes = jest.fn(() => Promise.resolve());
    document.body.appendChild(anchor);

    render(
      <EmojiActionsMenuController
        intl={intl}
        signedIn
        muteActionsEnabled
        onSyncMutes={onSyncMutes}
        onConfirm={onConfirm}
      />,
    );

    act(() => {
      openEmojiActions({ kind: 'unicode', native: '😀' }, { anchor, source: 'standard_picker' });
    });

    fireEvent.click(await screen.findByRole('button', { name: 'Mute emoji' }));
    expect(typeof confirm).toBe('function');

    act(() => {
      openEmojiActions({ kind: 'unicode', native: '🎉' }, { anchor, source: 'standard_picker' });
    });
    await screen.findByRole('button', { name: 'Mute emoji' });

    act(() => {
      confirm();
    });

    expect(createEmojiMute).not.toHaveBeenCalled();
    anchor.remove();
  });

  it('mutes the emoji that was open when the dialog was confirmed', async () => {
    let confirm = null;
    const anchor = document.createElement('button');
    function onConfirm(config) {
      confirm = config.onConfirm;
    }
    const onSyncMutes = jest.fn(() => Promise.resolve());
    document.body.appendChild(anchor);

    render(
      <EmojiActionsMenuController
        intl={intl}
        signedIn
        muteActionsEnabled
        onSyncMutes={onSyncMutes}
        onConfirm={onConfirm}
      />,
    );

    act(() => {
      openEmojiActions({ kind: 'unicode', native: '😀' }, { anchor, source: 'standard_picker' });
    });

    fireEvent.click(await screen.findByRole('button', { name: 'Mute emoji' }));

    await act(async () => {
      confirm();
    });

    await waitFor(() => expect(createEmojiMute).toHaveBeenCalledTimes(1));
    expect(createEmojiMute.mock.calls[0][0]).toEqual(expect.objectContaining({ native: '😀' }));
    expect(createEmojiMute.mock.calls[0][1]).toEqual({ enable: true });
    anchor.remove();
  });

  it('asks again for the same emoji when the server requires re-enable after the menu closes', async () => {
    resetEmojiMuteBootForTests();
    const rejected = Object.assign(new Error('reenable'), { errors: [{ code: 'reenable_required' }] });
    createEmojiMute.mockRejectedValueOnce(rejected);
    const confirms = [];
    const anchor = document.createElement('button');
    function onConfirm(config) {
      confirms.push(config.onConfirm);
    }
    document.body.appendChild(anchor);

    render(
      <EmojiActionsMenuController
        intl={intl}
        signedIn
        muteActionsEnabled
        onSyncMutes={jest.fn(() => Promise.resolve())}
        onConfirm={onConfirm}
      />,
    );

    act(() => {
      openEmojiActions({ kind: 'unicode', native: '😀' }, { anchor, source: 'standard_picker' });
    });

    fireEvent.click(await screen.findByRole('button', { name: 'Mute emoji' }));

    await act(async () => {
      confirms[0]();
    });

    await waitFor(() => expect(confirms).toHaveLength(2));
    expect(createEmojiMute).toHaveBeenCalledTimes(1);
    expect(createEmojiMute.mock.calls[0][0]).toEqual(expect.objectContaining({ native: '😀' }));

    await act(async () => {
      confirms[1]();
    });

    await waitFor(() => expect(createEmojiMute).toHaveBeenCalledTimes(2));
    expect(createEmojiMute.mock.calls[1][0]).toEqual(expect.objectContaining({ native: '😀' }));
    expect(createEmojiMute.mock.calls[1][1]).toEqual({ enable: true });
    anchor.remove();
  });

  it('does not re-enable a different emoji that opened while the server asked for confirmation', async () => {
    resetEmojiMuteBootForTests();
    const rejected = Object.assign(new Error('reenable'), { errors: [{ code: 'reenable_required' }] });
    createEmojiMute.mockRejectedValueOnce(rejected);
    const confirms = [];
    const anchor = document.createElement('button');
    function onConfirm(config) {
      confirms.push(config.onConfirm);
    }
    document.body.appendChild(anchor);

    render(
      <EmojiActionsMenuController
        intl={intl}
        signedIn
        muteActionsEnabled
        onSyncMutes={jest.fn(() => Promise.resolve())}
        onConfirm={onConfirm}
      />,
    );

    act(() => {
      openEmojiActions({ kind: 'unicode', native: '😀' }, { anchor, source: 'standard_picker' });
    });

    fireEvent.click(await screen.findByRole('button', { name: 'Mute emoji' }));

    await act(async () => {
      confirms[0]();
    });

    await waitFor(() => expect(confirms).toHaveLength(2));

    act(() => {
      openEmojiActions({ kind: 'unicode', native: '🎉' }, { anchor, source: 'standard_picker' });
    });
    await screen.findByRole('button', { name: 'Mute emoji' });

    await act(async () => {
      confirms[1]();
    });

    expect(createEmojiMute).toHaveBeenCalledTimes(1);
    anchor.remove();
  });
});
