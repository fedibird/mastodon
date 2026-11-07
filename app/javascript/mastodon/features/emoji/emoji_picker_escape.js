// ModalRoot listens for Escape on window keyup. The shell closes on keydown.
// One key would otherwise close the picker and the modal behind it. The flag
// lasts for the matching keyup, including when the shell unmounts first.
let consumeNextEscapeKeyUp = false;

function isEscape(event) {
  return Boolean(event && (event.key === 'Escape' || event.key === 'Esc' || event.keyCode === 27));
}

export function markEmojiPickerEscape() {
  consumeNextEscapeKeyUp = true;
}

export function consumeEmojiPickerEscape(event) {
  if (!consumeNextEscapeKeyUp || !isEscape(event)) {
    return false;
  }

  consumeNextEscapeKeyUp = false;
  return true;
}

export function resetEmojiPickerEscapeForTests() {
  consumeNextEscapeKeyUp = false;
}
