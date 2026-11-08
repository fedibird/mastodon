// The editor preview and every picker host use the same application theme.
export function emojiPickerTheme() {
  if (document.body.classList.contains('theme-mastodon-light')) {
    return 'light';
  }

  return document.body.classList.contains('theme-system') ? 'auto' : 'dark';
}
