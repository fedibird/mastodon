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
import {
  openEmojiActions,
  reportEmojiActionsSlideRelease,
  resetEmojiActionsBusForTests,
} from 'mastodon/features/emoji/emoji_actions/bus';
import { detailPathForReference } from 'mastodon/features/emoji/emoji_actions/reference';
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

  it('shows context i18n (with retry) for context.account_id invalid_id, not deleted-emoji copy', async () => {
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

    expect(await screen.findByText('Could not verify this post context')).toBeTruthy();
    expect(screen.queryByText('This emoji is unavailable or was deleted')).toBeNull();
    expect(screen.queryByText('Invalid emoji reference')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Mute emoji' })).toBeNull();
    expect(screen.getByRole('button', { name: 'Try again' })).toBeTruthy();

    document.body.removeChild(anchor);
  });

  it('shows unavailable i18n without retry for emoji.custom_emoji_id unavailable_emoji', async () => {
    resolveEmojiReference.mockImplementation(() => Promise.reject(Object.assign(
      new Error('Invalid emoji reference'),
      {
        status: 422,
        errors: [{ path: 'emoji.custom_emoji_id', code: 'unavailable_emoji' }],
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
      openEmojiActions({ kind: 'custom', scope: 'local', custom_emoji_id: '99' }, { anchor, source: 'reaction' });
    });

    expect(await screen.findByText('This emoji is unavailable or was deleted')).toBeTruthy();
    expect(screen.queryByText('Invalid emoji reference')).toBeNull();
    expect(screen.queryByRole('button', { name: 'Mute emoji' })).toBeNull();
    expect(screen.queryByRole('button', { name: 'Try again' })).toBeNull();

    document.body.removeChild(anchor);
  });

  it('activates a menu item once on slide release over that item (coordinate hit-test)', async () => {
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
      openEmojiActions({ kind: 'unicode', native: '😀' }, { anchor, source: 'standard_picker' });
    });

    const muteItem = await screen.findByRole('button', { name: 'Mute emoji' });
    const original = document.elementFromPoint;
    document.elementFromPoint = () => muteItem;

    act(() => {
      expect(reportEmojiActionsSlideRelease({ clientX: 40, clientY: 40 })).toBe(true);
      // Second release in the same gesture session must not re-run.
      expect(reportEmojiActionsSlideRelease({ clientX: 40, clientY: 40 })).toBe(false);
    });

    document.elementFromPoint = original;

    await waitFor(() => expect(createEmojiMute).toHaveBeenCalledTimes(1));
    document.body.removeChild(anchor);
  });

  it('leaves the menu open when slide release is outside any item', async () => {
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
      openEmojiActions({ kind: 'unicode', native: '😀' }, { anchor, source: 'standard_picker' });
    });

    await screen.findByRole('button', { name: 'Mute emoji' });

    const original = document.elementFromPoint;
    document.elementFromPoint = () => document.body;

    act(() => {
      expect(reportEmojiActionsSlideRelease({ clientX: 1, clientY: 1 })).toBe(false);
    });

    document.elementFromPoint = original;

    expect(screen.getByRole('button', { name: 'Mute emoji' })).toBeTruthy();
    expect(createEmojiMute).not.toHaveBeenCalled();
    document.body.removeChild(anchor);
  });

  it('does not activate disabled items via slide release', async () => {
    currentEmojiMutes.mockReturnValue([{
      id: 'm1',
      emoji: { kind: 'unicode', native: '😀' },
      revision: '1',
    }]);

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
      openEmojiActions({ kind: 'unicode', native: '😀' }, { anchor, source: 'standard_picker' });
    });

    const muted = await screen.findByRole('button', { name: 'Muted' });
    expect(muted).toHaveAttribute('aria-disabled', 'true');

    const original = document.elementFromPoint;
    document.elementFromPoint = () => muted;

    act(() => {
      expect(reportEmojiActionsSlideRelease({ clientX: 12, clientY: 12 })).toBe(false);
    });

    document.elementFromPoint = original;
    expect(createEmojiMute).not.toHaveBeenCalled();
    document.body.removeChild(anchor);
  });

  it('closes mobile picker surfaces before navigating to emoji detail', async () => {
    const history = { push: jest.fn() };
    const onCloseReactionModal = jest.fn();
    const onCloseDropdown = jest.fn();

    class RouterHarness extends React.Component {

      static childContextTypes = { router: PropTypes.object };

      getChildContext() {
        return { router: { history } };
      }

      render() {
        return this.props.children;
      }

    }

    render(
      <RouterHarness>
        <EmojiActionsMenuController
          intl={intl}
          signedIn
          layout='mobile'
          openDropdownId='picker-dd'
          onCloseReactionModal={onCloseReactionModal}
          onCloseDropdown={onCloseDropdown}
          onSyncMutes={jest.fn(() => Promise.resolve())}
        />
      </RouterHarness>,
    );

    const anchor = document.createElement('button');
    document.body.appendChild(anchor);
    const reference = { kind: 'unicode', native: '😀' };

    act(() => {
      openEmojiActions(reference, { anchor, source: 'standard_picker' });
    });

    fireEvent.click(await screen.findByRole('button', { name: 'Emoji details' }));

    expect(onCloseReactionModal).toHaveBeenCalledTimes(1);
    expect(onCloseDropdown).toHaveBeenCalledWith('picker-dd');
    await waitFor(() => {
      expect(history.push).toHaveBeenCalledWith(detailPathForReference(reference));
    });

    document.body.removeChild(anchor);
  });

  it('closes single-column picker on detail but not for mute/copy', async () => {
    const history = { push: jest.fn() };
    const onCloseReactionModal = jest.fn();

    class RouterHarness extends React.Component {

      static childContextTypes = { router: PropTypes.object };

      getChildContext() {
        return { router: { history } };
      }

      render() {
        return this.props.children;
      }

    }

    render(
      <RouterHarness>
        <EmojiActionsMenuController
          intl={intl}
          signedIn
          layout='single-column'
          onCloseReactionModal={onCloseReactionModal}
          onSyncMutes={jest.fn(() => Promise.resolve())}
        />
      </RouterHarness>,
    );

    const anchor = document.createElement('button');
    document.body.appendChild(anchor);
    const reference = { kind: 'unicode', native: '😀' };

    act(() => {
      openEmojiActions(reference, { anchor, source: 'personal_picker' });
    });

    fireEvent.click(await screen.findByRole('button', { name: 'Copy emoji' }));
    await waitFor(() => expect(copyText).toHaveBeenCalledWith('😀'));
    expect(onCloseReactionModal).not.toHaveBeenCalled();

    act(() => {
      openEmojiActions(reference, { anchor, source: 'personal_picker' });
    });

    fireEvent.click(await screen.findByRole('button', { name: 'Mute emoji' }));
    await waitFor(() => expect(createEmojiMute).toHaveBeenCalledTimes(1));
    expect(onCloseReactionModal).not.toHaveBeenCalled();

    act(() => {
      openEmojiActions(reference, { anchor, source: 'personal_picker' });
    });

    fireEvent.click(await screen.findByRole('button', { name: 'Emoji details' }));
    expect(onCloseReactionModal).toHaveBeenCalledTimes(1);
    await waitFor(() => {
      expect(history.push).toHaveBeenCalledWith(detailPathForReference(reference));
    });

    document.body.removeChild(anchor);
  });

  it('does not close pickers for detail from reaction or desktop multi-column', async () => {
    const history = { push: jest.fn() };
    const onCloseReactionModal = jest.fn();

    class RouterHarness extends React.Component {

      static childContextTypes = { router: PropTypes.object };

      getChildContext() {
        return { router: { history } };
      }

      render() {
        return this.props.children;
      }

    }

    const { unmount } = render(
      <RouterHarness>
        <EmojiActionsMenuController
          intl={intl}
          signedIn
          layout='multi-column'
          onCloseReactionModal={onCloseReactionModal}
          onSyncMutes={jest.fn(() => Promise.resolve())}
        />
      </RouterHarness>,
    );

    const anchor = document.createElement('button');
    document.body.appendChild(anchor);
    const reference = { kind: 'unicode', native: '😀' };

    act(() => {
      openEmojiActions(reference, { anchor, source: 'standard_picker' });
    });

    fireEvent.click(await screen.findByRole('button', { name: 'Emoji details' }));
    expect(onCloseReactionModal).not.toHaveBeenCalled();
    expect(history.push).toHaveBeenCalledWith(detailPathForReference(reference));

    unmount();
    history.push.mockClear();
    onCloseReactionModal.mockClear();

    render(
      <RouterHarness>
        <EmojiActionsMenuController
          intl={intl}
          signedIn
          layout='mobile'
          onCloseReactionModal={onCloseReactionModal}
          onSyncMutes={jest.fn(() => Promise.resolve())}
          onAddEmojiReaction={jest.fn()}
          onRemoveEmojiReaction={jest.fn()}
          getStatus={() => fromJS({ id: 'status-1', account: '42' })}
        />
      </RouterHarness>,
    );

    act(() => {
      openEmojiActions(reference, {
        anchor,
        source: 'reaction',
        status_id: 'status-1',
        account_id: '42',
        reaction: { name: '😀', my_reaction: false },
      });
    });

    fireEvent.click(await screen.findByRole('button', { name: 'Emoji details' }));
    expect(onCloseReactionModal).not.toHaveBeenCalled();
    expect(history.push).toHaveBeenCalledWith(detailPathForReference(reference));

    document.body.removeChild(anchor);
  });

  it('slide-release detail on mobile closes picker then navigates once', async () => {
    const history = { push: jest.fn() };
    const onCloseReactionModal = jest.fn();

    class RouterHarness extends React.Component {

      static childContextTypes = { router: PropTypes.object };

      getChildContext() {
        return { router: { history } };
      }

      render() {
        return this.props.children;
      }

    }

    render(
      <RouterHarness>
        <EmojiActionsMenuController
          intl={intl}
          signedIn
          layout='mobile'
          onCloseReactionModal={onCloseReactionModal}
          onSyncMutes={jest.fn(() => Promise.resolve())}
        />
      </RouterHarness>,
    );

    const anchor = document.createElement('button');
    document.body.appendChild(anchor);
    const reference = { kind: 'unicode', native: '😀' };

    act(() => {
      openEmojiActions(reference, { anchor, source: 'standard_picker' });
    });

    const detailItem = await screen.findByRole('button', { name: 'Emoji details' });
    const original = document.elementFromPoint;
    document.elementFromPoint = () => detailItem;

    act(() => {
      expect(reportEmojiActionsSlideRelease({ clientX: 22, clientY: 22 })).toBe(true);
    });

    document.elementFromPoint = original;

    expect(onCloseReactionModal).toHaveBeenCalledTimes(1);
    await waitFor(() => {
      expect(history.push).toHaveBeenCalledTimes(1);
      expect(history.push).toHaveBeenCalledWith(detailPathForReference(reference));
    });

    document.body.removeChild(anchor);
  });

  it('does not steal an unrelated click or keyboard activation after slide select', async () => {
    render(
      <EmojiActionsMenuController
        intl={intl}
        signedIn
        onSyncMutes={jest.fn(() => Promise.resolve())}
      />,
    );

    const anchor = document.createElement('button');
    document.body.appendChild(anchor);
    const other = document.createElement('button');
    other.textContent = 'Elsewhere';
    const otherClick = jest.fn();
    other.addEventListener('click', otherClick);
    document.body.appendChild(other);

    act(() => {
      openEmojiActions({ kind: 'unicode', native: '😀' }, { anchor, source: 'standard_picker' });
    });

    const muteItem = await screen.findByRole('button', { name: 'Mute emoji' });
    const original = document.elementFromPoint;
    document.elementFromPoint = () => muteItem;

    act(() => {
      expect(reportEmojiActionsSlideRelease({ clientX: 40, clientY: 40 })).toBe(true);
    });

    document.elementFromPoint = original;
    await waitFor(() => expect(createEmojiMute).toHaveBeenCalledTimes(1));

    // No synthetic click on the emoji cell — an unrelated button must work now.
    fireEvent.click(other, { detail: 1 });
    expect(otherClick).toHaveBeenCalledTimes(1);

    const keyboardTarget = document.createElement('button');
    const keyboardClick = jest.fn();
    keyboardTarget.addEventListener('click', keyboardClick);
    document.body.appendChild(keyboardTarget);
    fireEvent.click(keyboardTarget, { detail: 0 });
    expect(keyboardClick).toHaveBeenCalledTimes(1);

    document.body.removeChild(anchor);
    document.body.removeChild(other);
    document.body.removeChild(keyboardTarget);
  });

  it('waits for ModalRoot POP before pushing detail (delayed goBack)', async () => {
    const { createMemoryHistory } = require('history');
    const ModalRoot = require('mastodon/components/modal_root').default;

    const history = createMemoryHistory({ initialEntries: ['/timelines/home'] });
    const onCloseReactionModal = jest.fn();

    class RouterHarness extends React.Component {

      static childContextTypes = { router: PropTypes.object };

      getChildContext() {
        return { router: { history } };
      }

      render() {
        return this.props.children;
      }

    }

    class ReactionModalHost extends React.Component {

      // Start closed so ModalRoot sees children null → present and arms history.
      state = { open: false };

      componentDidMount() {
        this.props.registerClose(() => this.setState({ open: false }));
        this.setState({ open: true });
      }

      render() {
        return (
          <ModalRoot onClose={() => this.setState({ open: false })}>
            {this.state.open ? <div>Reaction picker</div> : null}
          </ModalRoot>
        );
      }

    }

    let closeHost = null;

    render(
      <RouterHarness>
        <ReactionModalHost
          registerClose={fn => {
            closeHost = fn;
          }}
        />
        <EmojiActionsMenuController
          intl={intl}
          signedIn
          layout='mobile'
          onCloseReactionModal={() => {
            onCloseReactionModal();
            if (closeHost) {
              closeHost();
            }
          }}
          onSyncMutes={jest.fn(() => Promise.resolve())}
        />
      </RouterHarness>,
    );

    // Let ModalRoot push its history buffer.
    await waitFor(() => {
      expect(history.location.state && history.location.state.mastodonModalKey).toBeTruthy();
    });

    const modalKey = history.location.state.mastodonModalKey;
    const realGoBack = history.goBack.bind(history);
    let pendingPop = null;
    history.goBack = () => {
      pendingPop = () => {
        history.goBack = realGoBack;
        realGoBack();
      };
    };

    const anchor = document.createElement('button');
    document.body.appendChild(anchor);
    const reference = { kind: 'unicode', native: '😀' };

    act(() => {
      openEmojiActions(reference, { anchor, source: 'standard_picker' });
    });

    fireEvent.click(await screen.findByRole('button', { name: 'Emoji details' }));
    expect(onCloseReactionModal).toHaveBeenCalledTimes(1);

    // Detail must not push before the delayed POP lands.
    expect(history.location.pathname).toBe('/timelines/home');
    expect(history.location.state && history.location.state.mastodonModalKey).toBe(modalKey);

    act(() => {
      expect(typeof pendingPop).toBe('function');
      pendingPop();
    });

    await waitFor(() => {
      // history may decode the unicode segment in location.pathname
      expect(decodeURIComponent(history.location.pathname)).toBe(
        decodeURIComponent(detailPathForReference(reference)),
      );
    });

    act(() => {
      realGoBack();
    });
    expect(history.location.pathname).toBe('/timelines/home');

    document.body.removeChild(anchor);
  });
});
