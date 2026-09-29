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

export function normalizedContentLocale(locale) {
  return (locale || '').replace(/[_-].*/, '');
}

export function legacyTranslationPair(status, locale) {
  return {
    source: (status && status.get('language')) || 'und',
    target: normalizedContentLocale(locale),
  };
}

export function viewerSourceAssumption(assumption) {
  if (typeof assumption === 'string' && assumption !== '') {
    return assumption;
  }

  if (assumption && typeof assumption.get === 'function') {
    const source = assumption.get('source');
    return typeof source === 'string' && source !== '' ? source : '';
  }

  return '';
}

export function viewerTranslationPair(status, assumption, locale, savedTarget) {
  const legacy = legacyTranslationPair(status, locale);
  const target = typeof savedTarget === 'string' && savedTarget !== '' ? savedTarget : legacy.target;

  return {
    source: viewerSourceAssumption(assumption) || legacy.source,
    target,
  };
}

export function sameLanguagePair(left, right) {
  return !!left && !!right && left.source === right.source && left.target === right.target;
}

export function translationRequestPair(status, locale) {
  const translation = status && status.get('translation');

  if (!translation || typeof translation.get !== 'function') {
    return null;
  }

  const source = translation.get('requested_source_language');
  const target = translation.get('requested_target_language');

  if (typeof source === 'string' && source !== '' && typeof target === 'string' && target !== '') {
    return { source, target };
  }

  return legacyTranslationPair(status, locale);
}

export function normalizeRequestedMode(mode) {
  return mode === TRANSLATION_MODE_BILINGUAL ? TRANSLATION_MODE_BILINGUAL : TRANSLATION_MODE_TRANSLATED;
}

const requestedLanguage = (translation, key) => {
  const value = translation && translation.get(key);
  return typeof value === 'string' && value !== '' ? value : '';
};

export function statusTranslationView(status) {
  const translation = status && status.get('translation');
  const detected = translation && translation.get('detected_source_language');
  const requestedSource = requestedLanguage(translation, 'requested_source_language');
  const requestedTarget = requestedLanguage(translation, 'requested_target_language');
  const hasRequestPair = requestedSource !== '' && requestedTarget !== '';
  const legacySource = (typeof detected === 'string' && detected.trim()) ? detected.trim() : ((status && status.get('language')) || '');
  const legacyTarget = (translation && translation.get('language')) || '';
  const sourceLang = hasRequestPair ? requestedSource : legacySource;
  const targetLang = hasRequestPair ? requestedTarget : legacyTarget;
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
