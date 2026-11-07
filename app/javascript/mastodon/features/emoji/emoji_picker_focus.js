// Compose insertion focuses the textarea. ModalRoot restores the trigger on
// the next microtask. A pick sets this so that restore does not run. Cancel
// leaves it unset and the trigger receives focus again.
let suppressNextModalFocusRestore = false;

export function keepFieldFocusAfterModalClose() {
  suppressNextModalFocusRestore = true;
}

export function takeModalFocusRestore() {
  const suppress = suppressNextModalFocusRestore;
  suppressNextModalFocusRestore = false;
  return suppress;
}

export function resetEmojiPickerFocusForTests() {
  suppressNextModalFocusRestore = false;
}
