export const SEARCHABILITY_POPUP_ATTRIBUTE = 'data-searchability-popup';

export const searchabilityPopupProps = (composerId) => {
  if (composerId === undefined || composerId === null || composerId === '') {
    return {};
  }

  return { [SEARCHABILITY_POPUP_ATTRIBUTE]: String(composerId) };
};

export const eventInOwnedSearchabilityPopup = (event, composerId) => {
  const target = event && event.target;

  if (composerId === undefined || composerId === null || composerId === '' || !target || typeof target.closest !== 'function') {
    return false;
  }

  const popup = target.closest(`[${SEARCHABILITY_POPUP_ATTRIBUTE}]`);

  return Boolean(popup && popup.getAttribute(SEARCHABILITY_POPUP_ATTRIBUTE) === String(composerId));
};
