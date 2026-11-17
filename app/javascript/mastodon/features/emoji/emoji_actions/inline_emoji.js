import { me } from 'mastodon/initial_state';
import { attachLongPressGesture, LONG_PRESS_CLICK_SUPPRESS_MS } from '../long_press';
import { openEmojiActions } from './bus';
import { datasetFromReference, normalizeReference } from './reference';

export function referenceFromInlineEmoji(element) {
  const shortcode = element?.dataset?.shortcode;
  const domain = element?.dataset?.domain;
  const customEmojiId = element?.dataset?.emojiId;

  if (!shortcode) {
    return null;
  }

  return normalizeReference(domain ? {
    kind: 'custom', scope: 'remote', domain, shortcode,
  } : {
    kind: 'custom', scope: 'local', shortcode,
    ...(customEmojiId ? { custom_emoji_id: customEmojiId } : {}),
  });
}

// A root-level component and its nested Content/DisplayName can both scan
// the same emoji. Only the first owner installs a long-press timer.
const attachedInlineEmojiNodes = new WeakSet();

export function openInlineEmojiMenu(element, context = {}) {
  if (!me) {
    return false;
  }

  const reference = referenceFromInlineEmoji(element);
  return reference ? openEmojiActions(reference, {
    anchor: element, source: context.source || 'inline_emoji',
    status_id: context.statusId || null,
    account_id: context.accountId || null,
  }) : false;
}

// Convert a plain emoji click to the shared menu, preserving the historical
// signed-out detail navigation and not hijacking modified link clicks.
export function handleInlineEmojiClick(event, emoji, router, context = {}) {
  if (!emoji || !referenceFromInlineEmoji(emoji)) {
    return false;
  }

  if (isInlineEmojiLongPressClick(event, emoji)) {
    event.preventDefault();
    event.stopPropagation();
    return true;
  }

  if (event.button !== undefined && event.button !== 0 || event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) {
    return false;
  }

  if (openInlineEmojiMenu(emoji, context)) {
    event.preventDefault();
    event.stopPropagation();
    return true;
  }

  // Signed-out behavior is intentionally unchanged.
  const { shortcode, domain } = emoji.dataset;
  if (router?.history && shortcode) {
    event.preventDefault();
    event.stopPropagation();
    router.history.push(`/emoji_detail/${shortcode}${domain ? `@${domain}` : ''}`);
    return true;
  }

  return false;
}

// Existing body/emoji HTML can be replaced after mute/translation updates.
// Return the disposers to the owning component; do not install document-wide
// listeners or retain detached emoji nodes.
export function attachInlineEmojiMenus(root, context = {}) {
  if (!root || !me) {
    return () => {};
  }

  const disposers = [];
  const emojis = root.querySelectorAll('img.custom-emoji[data-shortcode]');

  for (const emoji of emojis) {
    if (attachedInlineEmojiNodes.has(emoji)) {
      continue;
    }

    const reference = referenceFromInlineEmoji(emoji);
    if (!reference) {
      continue;
    }

    attachedInlineEmojiNodes.add(emoji);
    emoji.setAttribute('data-emoji-actions', '1');
    emoji.setAttribute('data-emoji-source', context.source || 'inline_emoji');
    if (context.statusId) emoji.dataset.emojiStatusId = String(context.statusId);
    if (context.accountId) emoji.dataset.emojiAccountId = String(context.accountId);
    const dataset = datasetFromReference(reference);
    Object.keys(dataset).forEach(key => {
      emoji.dataset[key] = dataset[key];
    });

    // The first pointer/touch after a completed long press is a new gesture.
    // Do not suppress a legitimate quick tap because a former hold ended <700ms ago.
    const resetClickSuppress = () => {
      delete emoji.dataset.emojiLongPressUntil;
    };
    emoji.addEventListener('touchstart', resetClickSuppress, { passive: true });
    emoji.addEventListener('pointerdown', resetClickSuppress);

    const onLongPress = () => {
      // A synthetic click may reach an ancestor's capturing click listener
      // before the gesture's own target listener can suppress it.
      emoji.dataset.emojiLongPressUntil = String(Date.now() + LONG_PRESS_CLICK_SUPPRESS_MS);
      openInlineEmojiMenu(emoji, context);
    };
    const detachGesture = attachLongPressGesture(emoji, {
      onLongPress,
      // A cancelled hold is a normal swipe: the timeline must see touchend.
      // After the menu opens, slide-selection movements must not swipe it.
      propagateCancelledTouchEnd: true,
      stopSlideTouchMovePropagation: true,
    });
    disposers.push(() => {
      detachGesture();
      emoji.removeEventListener('touchstart', resetClickSuppress);
      emoji.removeEventListener('pointerdown', resetClickSuppress);
      attachedInlineEmojiNodes.delete(emoji);
    });
  }

  return () => {
    disposers.forEach(dispose => dispose());
  };
}

export function isInlineEmojiLongPressClick(event, emoji) {
  return event.detail !== 0 && Date.now() < Number(emoji?.dataset?.emojiLongPressUntil || 0);
}
