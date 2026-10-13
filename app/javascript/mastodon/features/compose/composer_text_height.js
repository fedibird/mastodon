export const PORTABLE_COMPOSER_FULL_ROWS = 4;
export const PORTABLE_COMPOSER_COMPACT_ROWS = 2;

export function portableComposerRows (displayMode) {
  return displayMode === 'simple' ? PORTABLE_COMPOSER_COMPACT_ROWS : PORTABLE_COMPOSER_FULL_ROWS;
}

export function clampComposerTextHeight (height, min, max) {
  const value = Number(height);

  if (!Number.isFinite(value)) {
    return min;
  }

  return Math.min(max, Math.max(min, Math.round(value)));
}

export function composerTextHeightBounds ({ viewportHeight, chromeHeight, lineHeight } = {}) {
  const line = Math.max(16, lineHeight || 22);
  const min = Math.round(line + 12);
  const viewport = Math.max(320, viewportHeight || 800);
  const maxComposer = Math.min(viewport * 0.5, viewport - 160);
  const max = Math.max(min, Math.round(maxComposer - Math.max(0, chromeHeight || 0)));

  return { min, max };
}
