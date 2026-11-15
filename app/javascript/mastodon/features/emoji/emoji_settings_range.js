// Keep the displayed slider value in sync without changing the Rails form's
// setting keys or save semantics.
export const initializeEmojiSettingsRanges = (root = document) => {
  root.querySelectorAll('[data-emoji-settings-range]').forEach(control => {
    const slider = control.querySelector('input[type="range"]');
    const output = control.querySelector('output');

    if (!slider || !output) {
      return;
    }

    const update = () => {
      const formatted = `${slider.value}${control.dataset.emojiSettingsRangeSuffix || ''}`;
      output.textContent = formatted;
      slider.setAttribute('aria-valuetext', formatted);
    };

    if (slider.dataset.emojiSettingsRangeBound !== 'true') {
      slider.addEventListener('input', update);
      slider.addEventListener('change', update);
      slider.dataset.emojiSettingsRangeBound = 'true';
    }

    update();
  });
};
