import { createThemePreview } from '../theme_preview';

describe('theme preview', () => {
  let active;
  let previewTheme;

  const stylesheet = name => document.head.querySelector(`link[rel="stylesheet"][href="/${name}.css"]`);
  const emit = (link, event = 'load') => link.dispatchEvent(new Event(event));

  beforeEach(() => {
    document.head.innerHTML = `
      <link rel="stylesheet" data-active-theme href="/default.css" media="all">
      <link rel="preload" as="style" data-theme-preview="default" href="/default.css" media="all">
      <link rel="preload" as="style" data-theme-preview="light" href="/light.css" media="all">
      <link rel="preload" as="style" data-theme-preview="contrast" href="/contrast.css" media="all">
      <link rel="preload" as="style" data-theme-preview="system" href="/system-dark.css" media="not all and (prefers-color-scheme: light)">
      <link rel="preload" as="style" data-theme-preview="system" href="/system-light.css" media="(prefers-color-scheme: light)">
    `;
    active = stylesheet('default');
    previewTheme = createThemePreview(document);
  });

  afterEach(() => {
    document.head.innerHTML = '';
  });

  it('keeps the current theme while the next stylesheet loads', () => {
    previewTheme('light');
    const light = stylesheet('light');
    expect(active.disabled).toBeFalsy();
    expect(light.media).toBe('not all');

    emit(light);
    expect(light.media).toBe('all');
    expect(active.disabled).toBe(true);
  });

  it('retains the previous preview on failure and allows retrying', () => {
    previewTheme('light');
    const light = stylesheet('light');
    emit(light);

    previewTheme('contrast');
    const failed = stylesheet('contrast');
    expect(light.media).toBe('all');
    emit(failed, 'error');

    expect(failed.isConnected).toBe(false);
    expect(light.isConnected).toBe(true);
    expect(light.media).toBe('all');

    previewTheme('contrast');
    const retry = stylesheet('contrast');
    emit(retry);
    expect(retry.media).toBe('all');
    expect(light.isConnected).toBe(false);
  });

  it('ignores obsolete load and error events during rapid changes', () => {
    previewTheme('light');
    const light = stylesheet('light');
    previewTheme('contrast');
    const contrast = stylesheet('contrast');
    previewTheme('default');
    const newest = document.head.querySelector('link[rel="stylesheet"][href="/default.css"]:not([data-active-theme])');

    emit(light);
    emit(contrast, 'error');
    expect(active.disabled).toBeFalsy();
    expect(newest.isConnected).toBe(true);
    expect(newest.media).toBe('not all');

    emit(newest);
    expect(newest.media).toBe('all');
    expect(active.disabled).toBe(true);
    expect(light.isConnected).toBe(false);
    expect(contrast.isConnected).toBe(false);
  });

  it('applies system mode only after both appearances can be displayed', () => {
    previewTheme('system');
    const dark = stylesheet('system-dark');
    const light = stylesheet('system-light');

    emit(light);
    expect(active.disabled).toBeFalsy();
    expect(light.media).toBe('not all');
    expect(dark.media).toBe('not all');

    emit(dark);
    expect(active.disabled).toBe(true);
    expect(light.media).toBe('(prefers-color-scheme: light)');
    expect(dark.media).toBe('not all and (prefers-color-scheme: light)');
  });

  it('keeps the saved theme if either system stylesheet fails', () => {
    previewTheme('system');
    const dark = stylesheet('system-dark');
    const light = stylesheet('system-light');
    emit(dark);
    emit(light, 'error');

    expect(active.disabled).toBeFalsy();
    expect(dark.isConnected).toBe(false);
    expect(light.isConnected).toBe(false);
  });
});
