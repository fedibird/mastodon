import React from 'react';
import NimbleEmoji from 'emoji-mart/dist-es/components/emoji/nimble-emoji';
import NimblePicker from 'emoji-mart/dist-es/components/picker/nimble-picker';
import nimblePickerData from './emoji_mart_nimble_data';

// The full standard dataset stays in this async chunk. Skin-tone previews
// and the empty-search emoji use the same bound data as the picker.
function Picker(props) {
  return (
    <NimblePicker {...props} data={nimblePickerData} />
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
