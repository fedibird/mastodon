import { emojiPickerTheme } from '../emoji_picker_theme';

describe('emoji picker legacy palette', () => {
  let originalClassName;

  beforeEach(() => {
    originalClassName = document.body.className;
  });

  afterEach(() => {
    document.body.className = originalClassName;
  });

  it.each([
    ['default dark theme', ''],
    ['explicit light theme', 'theme-mastodon-light'],
    ['system theme', 'theme-system'],
  ])('keeps the old light picker palette with %s', (_label, bodyClass) => {
    document.body.className = bodyClass;
    expect(emojiPickerTheme()).toBe('light');
  });
});
