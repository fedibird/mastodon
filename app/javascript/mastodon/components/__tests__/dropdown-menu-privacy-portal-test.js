import Dropdown from '../dropdown_menu';

describe('dropdown privacy portal containment', () => {
  it('keeps the react-overlays container inside the detachable WebUI', () => {
    const portal = document.createElement('div');
    portal.className = 'emoji-mutes-privacy-portal';
    const target = document.createElement('span');
    portal.appendChild(target);

    const dropdown = new Dropdown({});
    dropdown.target = target;

    expect(dropdown.findOverlayContainer()).toBe(portal);
    expect(portal.isConnected).toBe(false);
    expect(dropdown.findOverlayContainer()).toBe(portal);
  });

  it('retains the default body host outside the WebUI', () => {
    const dropdown = new Dropdown({});
    dropdown.target = document.createElement('span');

    expect(dropdown.findOverlayContainer()).toBe(document.body);
  });
});
