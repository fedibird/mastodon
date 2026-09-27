export const TRANSLATION_MODE_ORIGINAL = 'original';
export const TRANSLATION_MODE_TRANSLATED = 'translated';
export const TRANSLATION_MODE_BILINGUAL = 'bilingual';

const DISPLAY_MODES = new Set([
  TRANSLATION_MODE_ORIGINAL,
  TRANSLATION_MODE_TRANSLATED,
  TRANSLATION_MODE_BILINGUAL,
]);

export function preferredTranslationMode(value) {
  return value === TRANSLATION_MODE_BILINGUAL ? TRANSLATION_MODE_BILINGUAL : TRANSLATION_MODE_TRANSLATED;
}

export function normalizeRequestedMode(mode) {
  return mode === TRANSLATION_MODE_BILINGUAL ? TRANSLATION_MODE_BILINGUAL : TRANSLATION_MODE_TRANSLATED;
}

export function statusTranslationView(status) {
  const translation = status && status.get('translation');
  const detected = translation && translation.get('detected_source_language');
  const sourceLang = (typeof detected === 'string' && detected.trim()) ? detected.trim() : ((status && status.get('language')) || '');
  const targetLang = (translation && translation.get('language')) || '';
  let mode = TRANSLATION_MODE_ORIGINAL;

  if (translation) {
    const stored = status.get('translationMode');
    mode = DISPLAY_MODES.has(stored) ? stored : TRANSLATION_MODE_TRANSLATED;
  }

  return {
    mode,
    sourceLang,
    targetLang,
    mediaLang: mode === TRANSLATION_MODE_ORIGINAL ? sourceLang : (targetLang || sourceLang),
    pending: !!(status && status.get('translationPending')),
  };
}

export function galleryTranslationProps(view) {
  return {
    lang: view.mediaLang,
    translationMode: view.mode,
    sourceLang: view.sourceLang,
    targetLang: view.targetLang,
  };
}

export function attachmentAccessibility(attachment, view) {
  const original = attachment.get('description') || '';
  const translated = attachment.getIn(['translation', 'description']) || '';
  const sourceLang = (view && view.sourceLang) || '';
  const targetLang = (view && view.targetLang) || '';
  const mode = view && view.mode;

  if (mode === TRANSLATION_MODE_TRANSLATED || mode === TRANSLATION_MODE_BILINGUAL) {
    if (translated) {
      return { text: translated, lang: targetLang || sourceLang, original, translated };
    }

    return { text: original, lang: sourceLang, original, translated };
  }

  if (!mode && translated) {
    return { text: translated, lang: targetLang || sourceLang, original, translated };
  }

  return { text: original, lang: sourceLang, original, translated };
}
