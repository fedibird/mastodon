/**
 * @jest-environment jsdom
 */

import {
  clearEmojiActionsSlideHighlight,
  hitTestEmojiActionsMenuItem,
  setEmojiActionsSlideHighlight,
} from '../emoji_actions/slide_select';

describe('emoji actions slide select hit-test', () => {
  afterEach(() => {
    document.body.innerHTML = '';
  });

  it('returns an enabled menu item under the point inside the actions portal', () => {
    const portal = document.createElement('div');
    portal.setAttribute('data-emoji-actions-menu', '1');
    const item = document.createElement('a');
    item.setAttribute('role', 'button');
    item.setAttribute('data-index', '2');
    item.textContent = 'Mute emoji';
    item.getBoundingClientRect = () => ({ left: 10, top: 10, right: 110, bottom: 40, width: 100, height: 30 });
    portal.appendChild(item);
    document.body.appendChild(portal);

    const original = document.elementFromPoint;
    document.elementFromPoint = () => item;

    expect(hitTestEmojiActionsMenuItem(20, 20)).toBe(item);

    document.elementFromPoint = original;
  });

  it('ignores disabled items and points outside the portal', () => {
    const portal = document.createElement('div');
    portal.setAttribute('data-emoji-actions-menu', '1');
    const disabled = document.createElement('a');
    disabled.setAttribute('data-index', '0');
    disabled.setAttribute('aria-disabled', 'true');
    portal.appendChild(disabled);
    document.body.appendChild(portal);

    const original = document.elementFromPoint;
    document.elementFromPoint = () => disabled;
    expect(hitTestEmojiActionsMenuItem(1, 1)).toBeNull();

    document.elementFromPoint = () => document.body;
    expect(hitTestEmojiActionsMenuItem(1, 1)).toBeNull();

    document.elementFromPoint = original;
  });

  it('toggles slide highlight class', () => {
    const a = document.createElement('a');
    const b = document.createElement('a');
    document.body.appendChild(a);
    document.body.appendChild(b);

    let current = setEmojiActionsSlideHighlight(null, a);
    expect(a.classList.contains('emoji-actions-menu__slide-target')).toBe(true);
    current = setEmojiActionsSlideHighlight(current, b);
    expect(a.classList.contains('emoji-actions-menu__slide-target')).toBe(false);
    expect(b.classList.contains('emoji-actions-menu__slide-target')).toBe(true);
    clearEmojiActionsSlideHighlight(current);
    expect(b.classList.contains('emoji-actions-menu__slide-target')).toBe(false);
  });
});
