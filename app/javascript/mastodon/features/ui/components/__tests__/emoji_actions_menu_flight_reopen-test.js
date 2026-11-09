/**
 * @jest-environment jsdom
 */

jest.mock('mastodon/features/emoji/emoji_actions/api', () => ({
  createEmojiMute: jest.fn(),
  deleteEmojiMute: jest.fn(),
  resolveEmojiReference: jest.fn(() => Promise.resolve({
    reference: { kind: 'unicode', native: '😀' },
    actions: { mute: { allowed: true }, add_to_personal_category: { allowed: true } },
  })),
  loadPersonalEmojiSetDocument: jest.fn(() => Promise.resolve({ revision: '1', categories: [] })),
  appendPersonalCategoryItem: jest.fn(),
}));

jest.mock('mastodon/features/emoji/emoji_mute_store', () => ({
  currentEmojiMutes: jest.fn(() => []),
}));

import {
  createEmojiMute,
  deleteEmojiMute,
  resolveEmojiReference,
} from 'mastodon/features/emoji/emoji_actions/api';
import { currentEmojiMutes } from 'mastodon/features/emoji/emoji_mute_store';
import {
  resetMuteMutationFlightsForTests,
  isMuteMutationInFlight,
} from 'mastodon/features/emoji/emoji_actions/mutation_flight';
import { resetPendingMuteSyncForTests } from 'mastodon/features/emoji/emoji_actions/pending_sync';
import { EmojiActionsMenuController } from '../emoji_actions_menu_controller';

const intl = {
  formatMessage: (message, values = {}) => {
    let text = message.defaultMessage || message.id;
    Object.keys(values).forEach(key => {
      text = text.replace(`{${key}}`, values[key]);
    });
    return text;
  },
};

const referenceA = { kind: 'unicode', native: '😀' };
const referenceB = { kind: 'unicode', native: '❤️' };

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((res, rej) => {
    resolve = res;
    reject = rej;
  });
  return { promise, resolve, reject };
}

function createHarness({ onSyncMutes } = {}) {
  const controller = new EmojiActionsMenuController({
    intl,
    signedIn: true,
    onSyncMutes: onSyncMutes || jest.fn(() => Promise.resolve()),
  });

  controller.setState = function setState(partial, cb) {
    const next = typeof partial === 'function' ? partial(this.state) : partial;
    this.state = { ...this.state, ...next };
    if (typeof cb === 'function') {
      cb();
    }
  };

  return controller;
}

function openReady(controller, reference, { mute = null } = {}) {
  controller.handleOpen({ reference, anchor: document.createElement('button') });
  // Invalidate the async loadMenuData from handleOpen so it cannot race the
  // mutation completion assertions in these controller-path tests.
  controller.loadGeneration = (controller.loadGeneration || 0) + 1;
  controller.setState({
    status: 'ready',
    resolved: {
      reference,
      actions: { mute: { allowed: true }, add_to_personal_category: { allowed: true } },
    },
    mute,
    categories: [],
    busy: isMuteMutationInFlight(reference),
  });
}

describe('EmojiActionsMenuController mute flight across close→reopen', () => {
  beforeEach(() => {
    resetMuteMutationFlightsForTests();
    resetPendingMuteSyncForTests();
    createEmojiMute.mockReset();
    deleteEmojiMute.mockReset();
    resolveEmojiReference.mockReset();
    resolveEmojiReference.mockImplementation(reference => Promise.resolve({
      reference,
      actions: { mute: { allowed: true }, add_to_personal_category: { allowed: true } },
    }));
    currentEmojiMutes.mockReset();
    currentEmojiMutes.mockReturnValue([]);
  });

  it('clears busy on reopened A when deferred POST succeeds after close→reopen', async () => {
    const pending = deferred();
    createEmojiMute.mockReturnValue(pending.promise);
    const onSyncMutes = jest.fn(() => Promise.resolve());
    const controller = createHarness({ onSyncMutes });

    openReady(controller, referenceA);
    controller.handleMute();
    expect(controller.state.busy).toBe(true);
    expect(isMuteMutationInFlight(referenceA)).toBe(true);

    controller.handleClose();
    expect(controller.state.reference).toBeNull();

    openReady(controller, referenceA);
    expect(controller.state.busy).toBe(true);

    const savedMute = { id: '10', revision: '4', emoji: referenceA };
    pending.resolve({ revision: '4', emoji_mute: savedMute });
    await pending.promise;
    await Promise.resolve();
    await Promise.resolve();

    expect(isMuteMutationInFlight(referenceA)).toBe(false);
    expect(controller.state.busy).toBe(false);
    expect(controller.state.mute).toEqual(savedMute);
    expect(controller.state.reference).toEqual(referenceA);
    expect(createEmojiMute).toHaveBeenCalledTimes(1);
  });

  it('clears busy on reopened A when deferred POST fails so Mute can retry', async () => {
    const pending = deferred();
    createEmojiMute.mockReturnValue(pending.promise);
    const controller = createHarness();

    openReady(controller, referenceA);
    controller.handleMute();
    controller.handleClose();
    openReady(controller, referenceA);
    expect(controller.state.busy).toBe(true);

    pending.reject(Object.assign(new Error('server'), { status: 500 }));

    await pending.promise.catch(() => {});
    await Promise.resolve();
    await Promise.resolve();

    expect(isMuteMutationInFlight(referenceA)).toBe(false);
    expect(controller.state.busy).toBe(false);
    expect(controller.state.error).toBeTruthy();
    expect(controller.state.mute).toBeNull();
  });

  it('does not paint A completion into an open B menu', async () => {
    const pending = deferred();
    createEmojiMute.mockReturnValue(pending.promise);
    const controller = createHarness();

    openReady(controller, referenceA);
    controller.handleMute();

    openReady(controller, referenceB);
    expect(controller.state.reference).toEqual(referenceB);
    expect(controller.state.busy).toBe(false);

    pending.resolve({ revision: '4', emoji_mute: { id: '10', revision: '4', emoji: referenceA } });
    await pending.promise;
    await Promise.resolve();
    await Promise.resolve();

    expect(controller.state.reference).toEqual(referenceB);
    expect(controller.state.mute).toBeNull();
    expect(controller.state.busy).toBe(false);
    expect(controller.state.notice).toBeNull();
  });

  it('clears busy on reopened A when deferred DELETE succeeds', async () => {
    const pending = deferred();
    deleteEmojiMute.mockReturnValue(pending.promise);
    const onSyncMutes = jest.fn(() => Promise.resolve());
    const controller = createHarness({ onSyncMutes });
    const savedMute = { id: '10', revision: '4', emoji: referenceA };

    openReady(controller, referenceA);
    controller.setState({ mute: savedMute });
    controller.handleUnmute();
    expect(controller.state.busy).toBe(true);

    controller.handleClose();
    openReady(controller, referenceA, { mute: savedMute });
    expect(controller.state.busy).toBe(true);

    pending.resolve({ revision: '5' });
    await pending.promise;
    await Promise.resolve();
    await Promise.resolve();

    expect(isMuteMutationInFlight(referenceA)).toBe(false);
    expect(controller.state.busy).toBe(false);
    expect(controller.state.mute).toBeNull();
    expect(deleteEmojiMute).toHaveBeenCalledTimes(1);
  });
});
