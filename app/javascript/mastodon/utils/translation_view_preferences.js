// Keep preference normalization independent of the translation rendering
// pipeline. initial_state must not pull status normalizers or emoji catalogs
// into lightweight consumers such as the personal emoji picker.
export const TRANSLATION_MODE_TRANSLATED = 'translated';
export const TRANSLATION_MODE_BILINGUAL = 'bilingual';
export const TRANSLATION_MODE_BOTH = 'both';

export const TRANSLATION_BAR_ALWAYS = 'always';
export const TRANSLATION_BAR_TARGET = 'target';
export const TRANSLATION_BAR_NEVER = 'never';

const PREFERRED_MODES = new Set([
  TRANSLATION_MODE_TRANSLATED,
  TRANSLATION_MODE_BILINGUAL,
  TRANSLATION_MODE_BOTH,
]);

const BAR_VISIBILITIES = new Set([
  TRANSLATION_BAR_ALWAYS,
  TRANSLATION_BAR_TARGET,
  TRANSLATION_BAR_NEVER,
]);

export function normalizeTranslationPreferredMode(value) {
  return PREFERRED_MODES.has(value) ? value : TRANSLATION_MODE_TRANSLATED;
}

export function normalizeTranslationBarVisibility(value) {
  return BAR_VISIBILITIES.has(value) ? value : null;
}
