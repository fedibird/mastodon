/**
 * @jest-environment jsdom
 */
/* eslint-disable react/prop-types, react/jsx-no-bind */

import React from 'react';
import PropTypes from 'prop-types';
import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { fromJS } from 'immutable';
import {
  createEmojiMute,
  loadPersonalEmojiSetDocument,
  resolveEmojiReference,
} from 'mastodon/features/emoji/emoji_actions/api';
import { openEmojiActions, resetEmojiActionsBusForTests } from 'mastodon/features/emoji/emoji_actions/bus';
import { resetMuteMutationFlightsForTests } from 'mastodon/features/emoji/emoji_actions/mutation_flight';
import {
  EMOJI_ACTIONS_OVERLAY_ROOT_ID,
  resetEmojiActionsOverlayRootForTests,
} from 'mastodon/features/emoji/emoji_actions/overlay_root';
import { resetPendingMuteSyncForTests } from 'mastodon/features/emoji/emoji_actions/pending_sync';
import { currentEmojiMutes } from 'mastodon/features/emoji/emoji_mute_store';
import { copyText } from 'mastodon/utils/clipboard';
import { EmojiActionsMenuController } from '../emoji_actions_menu_controller';

jest.mock('mastodon/features/emoji/emoji_actions/api', () => ({
  createEmojiMute: jest.fn(() => Promise.resolve({ mute: { id: 'm1' }, revision: '2' })),
  deleteEmojiMute: jest.fn(),
  resolveEmojiReference: jest.fn(),
  loadPersonalEmojiSetDocument: jest.fn(() => Promise.resolve({
    revision: '1',
    categories: [{ id: 'cat-1', name: 'Favorites', items: [] }],
  })),
  appendPersonalCategoryItem: jest.fn(() => Promise.resolve({
    revision: '2',
    added: true,
    categories: [{ id: 'cat-1', name: 'Favorites', items: [{ key: 'k' }] }],
  })),
}));

jest.mock('mastodon/features/emoji/emoji_mute_store', () => ({
  currentEmojiMutes: jest.fn(() => []),
}));

jest.mock('mastodon/utils/clipboard', () => ({
  copyText: jest.fn(() => Promise.resolve()),
}));

jest.mock('react-intl', () => {
  const intl = {
    formatMessage: (descriptor, values = {}) => {
      let text = descriptor.defaultMessage || descriptor.id;
      Object.keys(values).forEach(key => {
        text = text.replace(`{${key}}`, values[key]);
      });
      return text;
    },
  };

  return {
    defineMessages: messages => messages,
    FormattedMessage: ({ defaultMessage }) => defaultMessage,
    injectIntl: Component => props => <Component {...props} intl={intl} />,
  };
});

const intl = {
  formatMessage: (descriptor, values = {}) => {
    let text = descriptor.defaultMessage || descriptor.id;
    Object.keys(values).forEach(key => {
      text = text.replace(`{${key}}`, values[key]);
    });
    return text;
  },
};

// Keep Overlay's portal/container behavior (no full mock) so we can assert
// the dedicated root above modal / outside pointer-events:none hosts.
jest.mock('react-overlays/Overlay', () => {
  const ReactDOM = require('react-dom');
  const { resolveContainerRef } = require('react-overlays/cjs/useWaitForDOMRef');

  return function TestOverlay({ show, children, container, target }) {
    if (!show) {
      return null;
    }

    const mountNode = resolveContainerRef(container) || global.document.body;
    const anchor = typeof target === 'function' ? target() : target;
    const child = typeof children === 'function'
      ? children({
        props: {
          style: {
            position: 'fixed',
            top: anchor ? 8 : 0,
            left: anchor ? 8 : 0,
          },
        },
        arrowProps: {},
        placement: 'bottom',
      })
      : children;

    return ReactDOM.createPortal(child, mountNode);
  };
});

describe('emoji actions menu portal host', () => {
  beforeEach(() => {
    resetEmojiActionsBusForTests();
    resetMuteMutationFlightsForTests();
    resetPendingMuteSyncForTests();
    resetEmojiActionsOverlayRootForTests();
    createEmojiMute.mockClear();
    copyText.mockClear();
    resolveEmojiReference.mockClear();
    loadPersonalEmojiSetDocument.mockClear();
    currentEmojiMutes.mockReturnValue([]);
    resolveEmojiReference.mockImplementation(reference => Promise.resolve({
      reference,
      actions: {
        mute: { allowed: true },
        add_to_personal_category: { allowed: true },
      },
    }));
    loadPersonalEmojiSetDocument.mockResolvedValue({
      revision: '1',
      categories: [{ id: 'cat-1', name: 'Favorites', items: [] }],
    });
  });

  afterEach(() => {
    resetEmojiActionsBusForTests();
    resetEmojiActionsOverlayRootForTests();
  });

  it('portals the menu into the dedicated overlay root above a modal host', async () => {
    const modal = document.createElement('div');
    modal.className = 'modal-root';
    modal.style.zIndex = '9999';
    document.body.appendChild(modal);

    const ui = document.createElement('div');
    ui.className = 'ui';
    ui.style.pointerEvents = 'none';
    document.body.appendChild(ui);

    render(
      <EmojiActionsMenuController
        intl={intl}
        signedIn
        onSyncMutes={jest.fn(() => Promise.resolve())}
      />,
      { container: ui },
    );

    const anchor = document.createElement('button');
    modal.appendChild(anchor);

    act(() => {
      openEmojiActions({ kind: 'unicode', native: '😀' }, { anchor, source: 'standard_picker' });
    });

    const muteItem = await screen.findByRole('button', { name: 'Mute emoji' });
    const portal = muteItem.closest('[data-emoji-actions-menu="1"]');
    const root = document.getElementById(EMOJI_ACTIONS_OVERLAY_ROOT_ID);

    expect(root).not.toBeNull();
    expect(root.contains(portal)).toBe(true);
    expect(modal.contains(portal)).toBe(false);
    expect(ui.contains(portal)).toBe(false);
    expect(Number(window.getComputedStyle(root).zIndex || 0)).toBeGreaterThan(9999);

    fireEvent.click(muteItem);
    await waitFor(() => expect(createEmojiMute).toHaveBeenCalledTimes(1));

    document.body.removeChild(modal);
    document.body.removeChild(ui);
  });

  it('runs menu actions while a pointer-events:none .ui host is present (desktop dropdown)', async () => {
    const history = { push: jest.fn() };

    class RouterHarness extends React.Component {

      static childContextTypes = { router: PropTypes.object };

      getChildContext() {
        return { router: { history } };
      }

      render() {
        return this.props.children;
      }

    }

    const ui = document.createElement('div');
    ui.className = 'ui';
    ui.style.pointerEvents = 'none';
    document.body.appendChild(ui);

    render(
      <RouterHarness>
        <div style={{ pointerEvents: 'none' }}>
          <EmojiActionsMenuController
            intl={intl}
            signedIn
            onSyncMutes={jest.fn(() => Promise.resolve())}
          />
        </div>
      </RouterHarness>,
      { container: ui },
    );

    const anchor = document.createElement('button');
    document.body.appendChild(anchor);

    act(() => {
      openEmojiActions({ kind: 'unicode', native: '😀' }, { anchor, source: 'standard_picker' });
    });

    await screen.findByRole('button', { name: 'Emoji details' });

    fireEvent.click(screen.getByRole('button', { name: 'Copy emoji' }));
    await waitFor(() => expect(copyText).toHaveBeenCalledWith('😀'));

    fireEvent.click(await screen.findByRole('button', { name: 'Mute emoji' }));
    await waitFor(() => expect(createEmojiMute).toHaveBeenCalledTimes(1));

    act(() => {
      openEmojiActions({ kind: 'unicode', native: '😀' }, { anchor, source: 'standard_picker' });
    });

    fireEvent.click(await screen.findByRole('button', { name: 'Emoji details' }));
    expect(history.push).toHaveBeenCalled();

    document.body.removeChild(ui);
    document.body.removeChild(anchor);
  });

  it('resolves reaction references with a string account id, not an expanded account map', async () => {
    render(
      <EmojiActionsMenuController
        intl={intl}
        signedIn
        onSyncMutes={jest.fn(() => Promise.resolve())}
        onAddEmojiReaction={jest.fn()}
        onRemoveEmojiReaction={jest.fn()}
        getStatus={() => fromJS({ id: 'status-1', account: { id: '42', acct: 'alice' } })}
      />,
    );

    const anchor = document.createElement('button');
    document.body.appendChild(anchor);

    act(() => {
      openEmojiActions(
        { kind: 'unicode', native: '😀' },
        {
          anchor,
          source: 'reaction',
          status_id: 'status-1',
          account_id: '42',
          reaction: {
            name: '😀',
            my_reaction: true,
            reaction_limit_reached: false,
            disabled: false,
          },
        },
      );
    });

    await screen.findByRole('button', { name: 'Remove this reaction' });

    await waitFor(() => expect(resolveEmojiReference).toHaveBeenCalled());
    const [, context] = resolveEmojiReference.mock.calls[0];
    expect(context).toEqual({ status_id: 'status-1', account_id: '42' });
    expect(screen.queryByText('Invalid emoji reference')).toBeNull();

    document.body.removeChild(anchor);
  });

  it('shows i18n resolve failure instead of raw Invalid emoji reference', async () => {
    resolveEmojiReference.mockImplementation(() => Promise.reject(Object.assign(
      new Error('Invalid emoji reference'),
      {
        status: 422,
        errors: [{ path: 'context.account_id', code: 'invalid_id' }],
      },
    )));

    render(
      <EmojiActionsMenuController
        intl={intl}
        signedIn
        onSyncMutes={jest.fn(() => Promise.resolve())}
      />,
    );

    const anchor = document.createElement('button');
    document.body.appendChild(anchor);

    act(() => {
      openEmojiActions({ kind: 'unicode', native: '😀' }, { anchor, source: 'reaction' });
    });

    expect(await screen.findByText('This emoji is unavailable or was deleted')).toBeTruthy();
    expect(screen.queryByText('Invalid emoji reference')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Mute emoji' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Try again' })).toBeNull();

    document.body.removeChild(anchor);
  });
});
