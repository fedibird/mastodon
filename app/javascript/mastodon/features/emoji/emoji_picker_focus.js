// The compose field is recorded when an emoji is inserted. A touch-modal pick
// that actually closes promotes that field to the post-inert focus target.
// Ctrl/Meta keeps the modal open and does not promote it, so a later Escape
// still returns to the trigger. Undefined means "use the trigger".
let notedComposeField = null;
let fieldAfterClose;

export function noteComposeInsertionField(element) {
  notedComposeField = element && typeof element.focus === 'function' ? element : null;
}

export function beginComposeFieldNote() {
  notedComposeField = null;
}

export function focusNotedComposeFieldAfterModalClose() {
  if (notedComposeField) {
    fieldAfterClose = notedComposeField;
  }

  notedComposeField = null;
}

export function takeModalFocusTarget() {
  if (fieldAfterClose === undefined) {
    return undefined;
  }

  const field = fieldAfterClose;
  fieldAfterClose = undefined;
  return field;
}

export function resetEmojiPickerFocusForTests() {
  notedComposeField = null;
  fieldAfterClose = undefined;
}
