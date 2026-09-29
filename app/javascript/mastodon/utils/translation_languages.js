const CHINESE_REGIONAL_SCRIPTS = {
  'zh-cn': 'zh-Hans',
  'zh-sg': 'zh-Hans',
  'zh-tw': 'zh-Hant',
  'zh-hk': 'zh-Hant',
  'zh-mo': 'zh-Hant',
};

const CHINESE_SCRIPT_TAGS = ['zh-Hans', 'zh-Hant'];

const normalizedLanguageTag = language => String(language || '').replace(/_/g, '-').toLowerCase();

const providerChineseScript = (normalized, translationLanguages) => (
  CHINESE_SCRIPT_TAGS.find(tag => tag.toLowerCase() === normalized && translationLanguages?.has(tag))
);

// Provider script codes are not in Mastodon's locale list. Keep the aliases
// local to Translation Bar options.
const PROVIDER_LANGUAGE_ALIASES = {
  'zh-Hans': ['zh-Hans', 'Chinese (Simplified)', '简体中文'],
  'zh-Hant': ['zh-Hant', 'Chinese (Traditional)', '繁體中文'],
};

// Same source resolution as TranslateStatusService. The public languages map
// exposes provider auto-detection as "und" rather than a nil key. Bare zh is
// Chinese with an unspecified script: never rewrite it to und, and never guess
// zh-Hans or zh-Hant.
export const translationSourceLanguage = (language, translationLanguages) => {
  if (!language || translationLanguages?.has(language)) {
    return language;
  }

  const normalized = normalizedLanguageTag(language);

  if (normalized === 'zh') {
    return 'zh';
  }

  const script = providerChineseScript(normalized, translationLanguages) || CHINESE_REGIONAL_SCRIPTS[normalized];
  if (script && translationLanguages?.has(script)) {
    return script;
  }

  const match = String(language).match(/^([A-Za-z]{2,3})[-_]([A-Za-z]{2}|\d{3})$/);
  if (!match) {
    return language;
  }

  const primary = match[1].toLowerCase();
  return translationLanguages?.has(primary) ? primary : language;
};

export const languageOption = (code, preloadedLanguages, unspecifiedName) => {
  if (!code || code === 'und') {
    return ['und', 'Unspecified', unspecifiedName];
  }

  const known = (preloadedLanguages || []).find(lang => lang[0] === code);
  return known || PROVIDER_LANGUAGE_ALIASES[code] || [code, code, code];
};

export const needsChineseScriptChoice = (source, target, translationLanguages) => {
  if (normalizedLanguageTag(source) !== 'zh' || !target || !translationLanguages || typeof translationLanguages.has !== 'function') {
    return false;
  }

  if (translationLanguages.has('zh')) {
    return false;
  }

  const resolved = translationSourceLanguage(source, translationLanguages);
  if (translationLanguages.has(resolved)) {
    return false;
  }

  return CHINESE_SCRIPT_TAGS.some(tag => translationLanguages.get(tag)?.includes(target));
};

const addCode = (codes, seen, code) => {
  if (!code || seen.has(code)) {
    return;
  }

  seen.add(code);
  codes.push(code);
};

const byKnownLanguage = (preloadedLanguages) => {
  const order = new Map((preloadedLanguages || []).map((lang, index) => [lang[0], index]));

  return (left, right) => {
    if (left === 'und') {
      return -1;
    }

    if (right === 'und') {
      return 1;
    }

    const leftIndex = order.has(left) ? order.get(left) : Number.MAX_SAFE_INTEGER;
    const rightIndex = order.has(right) ? order.get(right) : Number.MAX_SAFE_INTEGER;

    if (leftIndex !== rightIndex) {
      return leftIndex - rightIndex;
    }

    return left.localeCompare(right);
  };
};

export const sourceLanguageOptions = (translationLanguages, currentSource, preloadedLanguages, unspecifiedName) => {
  const codes = [];
  const seen = new Set();

  if (translationLanguages?.has('und')) {
    addCode(codes, seen, 'und');
  }

  translationLanguages?.keySeq?.().forEach(key => {
    if (key && key !== 'und') {
      addCode(codes, seen, key);
    }
  });

  addCode(codes, seen, currentSource || 'und');
  codes.sort(byKnownLanguage(preloadedLanguages));

  return placeChineseScriptsBesideBareZh(codes, currentSource).map(code => languageOption(code, preloadedLanguages, unspecifiedName));
};

// The unfiltered dropdown pins the current value first and otherwise keeps
// this order. Putting the script tags immediately after bare zh keeps them
// next to the current Chinese option instead of at the end of unknown codes.
const placeChineseScriptsBesideBareZh = (codes, currentSource) => {
  if (normalizedLanguageTag(currentSource) !== 'zh') {
    return codes;
  }

  const bare = codes.find(code => normalizedLanguageTag(code) === 'zh');
  const scripts = CHINESE_SCRIPT_TAGS.filter(code => codes.includes(code));

  if (!bare || scripts.length === 0) {
    return codes;
  }

  const rest = codes.filter(code => code !== bare && !scripts.includes(code));
  return [bare, ...scripts, ...rest];
};

export const sameTranslationLanguage = (source, target, translationLanguages) => {
  const resolvedSource = translationSourceLanguage(source, translationLanguages);
  const resolvedTarget = translationSourceLanguage(target, translationLanguages);

  return !!resolvedSource && !!resolvedTarget && resolvedSource === resolvedTarget;
};

export const targetLanguageOptions = (translationLanguages, source, currentTarget, preloadedLanguages, unspecifiedName, defaultTarget) => {
  const resolved = translationSourceLanguage(source, translationLanguages);
  const codes = [];
  const seen = new Set();
  const targets = translationLanguages?.get(resolved);

  targets?.forEach(code => addCode(codes, seen, code));
  addCode(codes, seen, currentTarget);
  addCode(codes, seen, defaultTarget);

  return codes.map(code => languageOption(code, preloadedLanguages, unspecifiedName));
};

// Provider-wide private content stays a separate flag. A personal status is
// an extra allowance only when this viewer wrote the wrapper and the proper
// status whose text would be sent to the provider.
export const selfAuthoredPersonalStatus = (status, viewerAccountId) => {
  if (viewerAccountId === null || viewerAccountId === undefined || viewerAccountId === '') {
    return false;
  }

  if (status?.get('visibility') !== 'personal') {
    return false;
  }

  const wrapperAccountId = status.getIn(['account', 'id']);
  const reblog = status.get('reblog');
  const properAccountId = reblog && typeof reblog.getIn === 'function'
    ? reblog.getIn(['account', 'id'])
    : wrapperAccountId;

  return String(wrapperAccountId) === String(viewerAccountId) &&
    String(properAccountId) === String(viewerAccountId);
};

export const translationCapability = (status, viewerPair, translationLanguages, { loggedIn, privateContentAllowed, viewerAccountId }) => {
  const visibilityAllowsTranslation = ['public', 'unlisted'].includes(status.get('visibility')) ||
    privateContentAllowed ||
    selfAuthoredPersonalStatus(status, viewerAccountId);
  const allowsRequest = !!loggedIn &&
    visibilityAllowsTranslation &&
    (status.get('search_index') || '').trim().length > 0;

  const languagesKnown = !!(translationLanguages && typeof translationLanguages.get === 'function');

  if (!allowsRequest || !languagesKnown) {
    return { allowsRequest, languagesKnown, pairSupported: false };
  }

  const resolved = translationSourceLanguage(viewerPair.source, translationLanguages);
  const targets = translationLanguages.get(resolved);

  return {
    allowsRequest: true,
    languagesKnown: true,
    pairSupported: !!targets?.includes(viewerPair.target),
  };
};
