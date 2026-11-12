import { initializeEmojiSettingsRanges } from '../emoji_settings_range';

describe('emoji settings range sliders', () => {
  beforeEach(() => {
    document.body.innerHTML = `
      <div data-emoji-settings-range data-emoji-settings-range-suffix="×">
        <input id="scale" type="range" min="1" max="4" step="0.1" value="1" />
        <output for="scale">1×</output>
      </div>
      <div data-emoji-settings-range data-emoji-settings-range-suffix=" px">
        <input id="reaction-size" type="range" min="10" max="48" step="1" value="16" />
        <output for="reaction-size">16 px</output>
      </div>
    `;
  });

  afterEach(() => {
    document.body.innerHTML = '';
  });

  it('shows current values for the two settings and updates them as they move', () => {
    initializeEmojiSettingsRanges();

    const scale = document.getElementById('scale');
    const reaction = document.getElementById('reaction-size');

    expect(document.querySelector('output[for="scale"]').textContent).toBe('1×');
    expect(document.querySelector('output[for="reaction-size"]').textContent).toBe('16 px');

    scale.value = '2.3';
    scale.dispatchEvent(new Event('input', { bubbles: true }));
    reaction.value = '32';
    reaction.dispatchEvent(new Event('input', { bubbles: true }));

    expect(document.querySelector('output[for="scale"]').textContent).toBe('2.3×');
    expect(document.querySelector('output[for="reaction-size"]').textContent).toBe('32 px');
    expect(scale.getAttribute('aria-valuetext')).toBe('2.3×');
    expect(reaction.getAttribute('aria-valuetext')).toBe('32 px');
  });

  it('does not install duplicate input listeners when the page reinitializes', () => {
    const scale = document.getElementById('scale');
    const addEventListener = jest.spyOn(scale, 'addEventListener');

    initializeEmojiSettingsRanges();
    initializeEmojiSettingsRanges();

    expect(addEventListener).toHaveBeenCalledTimes(2);

    scale.value = '3.5';
    scale.dispatchEvent(new Event('change', { bubbles: true }));
    expect(document.querySelector('output[for="scale"]').textContent).toBe('3.5×');
  });

  it('ignores unrelated markup safely', () => {
    document.body.innerHTML = '<div data-emoji-settings-range><output></output></div>';

    expect(() => initializeEmojiSettingsRanges()).not.toThrow();
  });
});
