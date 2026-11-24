import {
  EMOJI_ACTIONS_OVERLAY_ROOT_ID,
  getEmojiActionsOverlayRoot,
  resetEmojiActionsOverlayRootForTests,
  setEmojiActionsOverlayPrivacyContainer,
} from '../overlay_root';

describe('emoji actions overlay privacy containment', () => {
  afterEach(() => {
    resetEmojiActionsOverlayRootForTests();
    setEmojiActionsOverlayPrivacyContainer(null);
  });

  it('removes the menu and its aria/image DOM from the document when the WebUI is detached', () => {
    const host = document.createElement('div');
    const portal = document.createElement('div');
    host.appendChild(portal);
    document.body.appendChild(host);
    setEmojiActionsOverlayPrivacyContainer(portal);

    const root = getEmojiActionsOverlayRoot();
    const emoji = document.createElement('img');
    emoji.src = '/private-emoji.svg';
    emoji.alt = 'hidden :blob:';
    root.appendChild(emoji);

    expect(root.parentNode).toBe(portal);
    expect(document.getElementById(EMOJI_ACTIONS_OVERLAY_ROOT_ID)).toBe(root);

    host.removeChild(portal);

    expect(document.getElementById(EMOJI_ACTIONS_OVERLAY_ROOT_ID)).toBeNull();
    expect(document.querySelector('img[src="/private-emoji.svg"]')).toBeNull();
    expect(getEmojiActionsOverlayRoot()).toBe(root);
    expect(root.isConnected).toBe(false);

    host.appendChild(portal);
    expect(document.getElementById(EMOJI_ACTIONS_OVERLAY_ROOT_ID)).toBe(root);
    expect(root.isConnected).toBe(true);
    host.remove();
  });

  it('moves an existing body-level menu under the privacy portal without recreating it', () => {
    const original = getEmojiActionsOverlayRoot();
    expect(original.parentNode).toBe(document.body);

    const portal = document.createElement('div');
    document.body.appendChild(portal);
    setEmojiActionsOverlayPrivacyContainer(portal);

    expect(getEmojiActionsOverlayRoot()).toBe(original);
    expect(original.parentNode).toBe(portal);
    portal.remove();
  });
});
