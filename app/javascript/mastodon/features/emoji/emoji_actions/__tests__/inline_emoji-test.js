/**
 * @jest-environment jsdom
 */

import { act, fireEvent } from '@testing-library/react';
import { openEmojiActions, resetEmojiActionsBusForTests, setEmojiActionsListener } from '../bus';
import { attachInlineEmojiMenus, handleInlineEmojiClick, referenceFromInlineEmoji } from '../inline_emoji';

jest.mock('mastodon/initial_state', () => ({ me: 'viewer' }));

describe('inline custom emoji identity', () => {
  it('uses a pinned local id when one is present', () => {
    const image = document.createElement('img');
    image.dataset.shortcode = 'fedibird';
    image.dataset.emojiId = '58';
    expect(referenceFromInlineEmoji(image)).toEqual({
      kind: 'custom', scope: 'local', custom_emoji_id: '58', shortcode: 'fedibird',
    });
  });

  it('never mistakes a remote row for a local row', () => {
    const image = document.createElement('img');
    image.dataset.shortcode = 'fedibird';
    image.dataset.domain = 'remote.example';
    image.dataset.emojiId = '58';
    expect(referenceFromInlineEmoji(image)).toEqual({
      kind: 'custom', scope: 'remote', domain: 'remote.example', shortcode: 'fedibird',
    });
  });

  it('allows local shortcode resolution when HTML lacks a row id', () => {
    const image = document.createElement('img');
    image.dataset.shortcode = 'local';
    expect(referenceFromInlineEmoji(image)).toEqual({
      kind: 'custom', scope: 'local', shortcode: 'local',
    });
    expect(referenceFromInlineEmoji(document.createElement('img'))).toBeNull();
  });
});

describe('inline custom emoji menu routing', () => {
  afterEach(() => {
    resetEmojiActionsBusForTests();
    jest.useRealTimers();
  });

  it('opens the common menu instead of navigating when signed in', () => {
    const element = document.createElement('img');
    element.dataset.shortcode = 'wide';
    element.dataset.emojiId = '93';
    const listener = jest.fn();
    const stop = setEmojiActionsListener(listener);
    const event = {
      button: 0, detail: 1, preventDefault: jest.fn(), stopPropagation: jest.fn(),
    };
    const router = { history: { push: jest.fn() } };

    expect(handleInlineEmojiClick(event, element, router, { source: 'inline_account_header' })).toBe(true);
    expect(listener).toHaveBeenCalledWith(expect.objectContaining({
      reference: { kind: 'custom', scope: 'local', custom_emoji_id: '93', shortcode: 'wide' },
      source: 'inline_account_header',
    }));
    expect(router.history.push).not.toHaveBeenCalled();
    expect(event.preventDefault).toHaveBeenCalled();
    stop();
  });

  it('does not install two hold timers for an emoji nested in two hosts', () => {
    jest.useFakeTimers();
    const outer = document.createElement('div');
    const inner = document.createElement('div');
    const emoji = document.createElement('img');
    emoji.className = 'custom-emoji';
    emoji.dataset.shortcode = 'blob';
    emoji.dataset.emojiId = '10';
    inner.appendChild(emoji);
    outer.appendChild(inner);
    document.body.appendChild(outer);
    const onOpen = jest.fn();
    const stop = setEmojiActionsListener(onOpen);
    const detachInner = attachInlineEmojiMenus(inner, { source: 'inline_status' });
    const detachOuter = attachInlineEmojiMenus(outer, { source: 'inline_status_attribution' });
    const event = new MouseEvent('pointerdown', { bubbles: true, button: 0, cancelable: true });
    Object.defineProperty(event, 'pointerId', { value: 1 });
    Object.defineProperty(event, 'pointerType', { value: 'mouse' });

    emoji.dispatchEvent(event);
    act(() => {
      jest.advanceTimersByTime(500);
    });

    expect(onOpen).toHaveBeenCalledTimes(1);
    expect(onOpen).toHaveBeenCalledWith(expect.objectContaining({ source: 'inline_status' }));
    expect(emoji.dataset.emojiActions).toBe('1');
    detachOuter();
    detachInner();
    stop();
    outer.remove();
  });

  it('preserves native modifier clicks rather than stealing a linked emoji', () => {
    const emoji = document.createElement('img');
    emoji.dataset.shortcode = 'blob';
    const listener = jest.fn();
    const stop = setEmojiActionsListener(listener);
    const event = { button: 0, metaKey: true, preventDefault: jest.fn(), stopPropagation: jest.fn() };
    expect(handleInlineEmojiClick(event, emoji, null)).toBe(false);
    expect(listener).not.toHaveBeenCalled();
    stop();
  });
});
