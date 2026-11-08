import React from 'react';
import NimbleEmoji from 'emoji-mart/dist-es/components/emoji/nimble-emoji';
import NimblePicker from 'emoji-mart/dist-es/components/picker/nimble-picker';
import nimblePickerData from './emoji_mart_nimble_data';

// The full standard dataset stays in this async chunk. Skin-tone previews
// and the empty-search emoji use the same bound data as the picker.
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

    // Wide lazy images can wrap onto another row after Nimble caches the
    // category positions. Measure once per frame after their dimensions settle.
    const handleImage = event => {
      if (event.target.matches('.emoji-mart-emoji-custom > img') && frame === null) {
        frame = requestAnimationFrame(refresh);
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

    scroll.addEventListener('load', handleImage, true);
    scroll.addEventListener('error', handleImage, true);
    root.addEventListener('click', handleAnchor, true);

    return () => {
      cancelRefresh();
      scroll.removeEventListener('load', handleImage, true);
      scroll.removeEventListener('error', handleImage, true);
      root.removeEventListener('click', handleAnchor, true);
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
