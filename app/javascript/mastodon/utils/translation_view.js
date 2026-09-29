import { fromJS } from 'immutable';
import { sameTranslationLanguage, translationRequestStatus } from 'mastodon/utils/translation_languages';

export const TRANSLATION_MODE_ORIGINAL = 'original';
export const TRANSLATION_MODE_TRANSLATED = 'translated';
export const TRANSLATION_MODE_BILINGUAL = 'bilingual';
export const TRANSLATION_MODE_BOTH = 'both';

export const TRANSLATION_BAR_ALWAYS = 'always';
export const TRANSLATION_BAR_TARGET = 'target';
export const TRANSLATION_BAR_NEVER = 'never';

const DISPLAY_MODES = new Set([
  TRANSLATION_MODE_ORIGINAL,
  TRANSLATION_MODE_TRANSLATED,
  TRANSLATION_MODE_BILINGUAL,
]);

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

export function preferredTranslationMode(value) {
  return normalizeTranslationPreferredMode(value);
}

export function preTranslationRequestModes(preferredMode) {
  switch (normalizeTranslationPreferredMode(preferredMode)) {
  case TRANSLATION_MODE_BILINGUAL:
    return [TRANSLATION_MODE_BILINGUAL];
  case TRANSLATION_MODE_BOTH:
    return [TRANSLATION_MODE_TRANSLATED, TRANSLATION_MODE_BILINGUAL];
  default:
    return [TRANSLATION_MODE_TRANSLATED];
  }
}

export function normalizeTranslationBarVisibility(value) {
  return BAR_VISIBILITIES.has(value) ? value : null;
}

export function translationBarEffectivelyVisible({ visibility, revealed, source, target, translationLanguages }) {
  if (revealed) {
    return true;
  }

  if (visibility === TRANSLATION_BAR_ALWAYS) {
    return true;
  }

  if (visibility === TRANSLATION_BAR_TARGET) {
    return !sameTranslationLanguage(source, target, translationLanguages);
  }

  return false;
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

// Merge a wrapper's translation onto the displayed status for rendering only.
// Media ALT stays inside the wrapper translation so the proper status does
// not show it outside this permission context.
export function translationDisplayStatus(displayed, wrapper) {
  if (!displayed || typeof displayed.get !== 'function') {
    return displayed;
  }

  const subject = translationRequestStatus(wrapper || displayed) || displayed;

  if (!subject || typeof subject.get !== 'function' || subject.get('id') === displayed.get('id')) {
    return displayed;
  }

  return displayed.withMutations(map => {
    map.set('translation', subject.get('translation'));
    map.set('translationPending', subject.get('translationPending'));
    map.set('translationMode', subject.get('translationMode'));
    map.set('translationRequestId', subject.get('translationRequestId'));

    const translatedMedia = subject.getIn(['translation', 'media_attachments']);
    const attachments = map.get('media_attachments');

    if (!translatedMedia || typeof translatedMedia.map !== 'function' || !attachments || typeof attachments.map !== 'function') {
      return;
    }

    map.set('media_attachments', attachments.map(attachment => {
      const match = translatedMedia.find(item => item.get('id') === attachment.get('id'));

      if (!match) {
        return attachment;
      }

      return attachment.set('translation', fromJS({ description: match.get('description') || '' }));
    }));
  });
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
