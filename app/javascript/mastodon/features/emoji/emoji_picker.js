import React from 'react';
import NimbleEmoji from 'emoji-mart/dist-es/components/emoji/nimble-emoji';
import NimblePicker from 'emoji-mart/dist-es/components/picker/nimble-picker';
import nimblePickerData from './emoji_mart_nimble_data';
import { openEmojiActions } from './emoji_actions/bus';

// The full standard dataset stays in this async chunk. Skin-tone previews
// and the empty-search emoji use the same bound data as the picker.
function nativeFromMartButton(button) {
  if (!button || button.closest('[data-emoji-actions="1"]')) {
    return null;
  }

  const label = button.getAttribute('aria-label') || '';
  const native = label.split(',')[0].trim();

  return native || null;
}

function openStandardEmojiActions(button, event) {
  const native = nativeFromMartButton(button);

  if (!native) {
    return;
  }

  if (event) {
    event.preventDefault();
    event.stopPropagation();
  }

  openEmojiActions({ kind: 'unicode', native }, {
    anchor: button,
    source: 'standard_picker',
  });
}

function Picker(props) {
  const pickerRef = React.useRef(null);

  React.useEffect(() => {
    const picker = pickerRef.current;
    const scroll = picker.scroll;
    const root = scroll.parentNode;
    let frame = null;

    const cancelRefresh = () => {
      if (frame !== null) {
        cancelAnimationFrame(frame);
        frame = null;
      }
    };

    const refresh = () => {
      frame = null;

      if (picker.scroll) {
        picker.updateCategoriesSize();
        picker.handleScroll();
      }
    };

    const scheduleRefresh = () => {
      if (frame === null) {
        frame = requestAnimationFrame(refresh);
      }
    };

    // Wide lazy images can wrap onto another row after Nimble caches the
    // category positions. Measure once per frame after their dimensions settle.
    const handleImage = event => {
      if (event.target.matches('.emoji-mart-emoji-custom > img')) {
        scheduleRefresh();
      }
    };

    // Flush before Nimble's click handler, including keyboard clicks and a
    // click that arrives before the pending image-load frame. Nimble still
    // owns clearing search and scrolling to the selected category.
    const handleAnchor = event => {
      if (event.target.closest('.emoji-mart-anchor')) {
        cancelRefresh();
        refresh();
      }
    };

    const handleContextMenu = event => {
      const button = event.target && event.target.closest && event.target.closest('button.emoji-mart-emoji');

      if (button) {
        openStandardEmojiActions(button, event);
      }
    };

    const handleKeyDown = event => {
      const isMenuKey = event.key === 'ContextMenu' || (event.key === 'F10' && event.shiftKey);

      if (!isMenuKey) {
        return;
      }

      const origin = event.target && event.target.nodeType === Node.ELEMENT_NODE
        ? event.target
        : event.target && event.target.parentElement;
      const button = origin && origin.closest && origin.closest('button.emoji-mart-emoji');

      if (button) {
        openStandardEmojiActions(button, event);
      }
    };

    scroll.addEventListener('load', handleImage, true);
    scroll.addEventListener('error', handleImage, true);
    root.addEventListener('click', handleAnchor, true);
    root.addEventListener('contextmenu', handleContextMenu);
    root.addEventListener('keydown', handleKeyDown);

    // Touch dialogs stretch to their container. Rotation can change both row
    // wrapping and the vh-limited scroll height without a React props update.
    const resizeObserver = window.ResizeObserver ? new window.ResizeObserver(scheduleRefresh) : null;

    if (resizeObserver) {
      resizeObserver.observe(root);
    } else {
      window.addEventListener('resize', scheduleRefresh);
    }

    return () => {
      if (resizeObserver) {
        resizeObserver.disconnect();
      } else {
        window.removeEventListener('resize', scheduleRefresh);
      }

      cancelRefresh();
      scroll.removeEventListener('load', handleImage, true);
      scroll.removeEventListener('error', handleImage, true);
      root.removeEventListener('click', handleAnchor, true);
      root.removeEventListener('contextmenu', handleContextMenu);
      root.removeEventListener('keydown', handleKeyDown);
    };
  }, []);

  return (
    <NimblePicker {...props} ref={pickerRef} data={nimblePickerData} />
  );
}

function Emoji(props) {
  return (
    <NimbleEmoji {...props} data={nimblePickerData} />
  );
}

export {
  Picker,
  Emoji,
};
