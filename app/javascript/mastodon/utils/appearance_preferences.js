// Applies accepted public values for content font size, info font size, and
// reduced motion. `configured` is never read. A missing or invalid public
// value leaves that setting as it is, including the server-rendered CSS
// variables and body class used before the first successful GET.
//
// Font sizes override the :root custom properties on the document element.
// Reduced motion toggles the same body classes the server renders. OS
// `prefers-reduced-motion` media queries are left alone, matching the
// server: the user setting and the OS preference stay independent.
// Nothing here remounts React, resets a composer, or moves scroll.

import { acceptedPublicValue } from './preference_apply';

const isBoolean = value => value === true || value === false;

// Schema ui_range 10..20 is the appearance form slider and
// WriteContract::FONT_RANGE. It is not the public validity range.
// public_type is integer, storage_constraint is nil, and Conformance
// accepts an integer such as 99. The initial :root rule prints that
// stored integer with no clamp, so live apply uses the same gate.
const isPublicFontSize = value => Number.isInteger(value);

let reduceMotionPublished = false;
let reduceMotionValue;
const reduceMotionListeners = new Set();

export const acceptedAppearance = (document) => ({
  contentFontSize: acceptedPublicValue(document, 'user.content_font_size', isPublicFontSize),
  infoFontSize: acceptedPublicValue(document, 'user.info_font_size', isPublicFontSize),
  reduceMotion: acceptedPublicValue(document, 'user.reduce_motion', isBoolean),
});

// `undefined` until a valid public boolean has been applied. Callers keep
// their InitialState fallback until then.
export const publishedReduceMotion = () => (
  reduceMotionPublished ? reduceMotionValue : undefined
);

export const reduceMotionNow = (initialValue) => (
  reduceMotionPublished ? reduceMotionValue : initialValue
);

export const subscribeReduceMotion = (listener) => {
  reduceMotionListeners.add(listener);

  return () => {
    reduceMotionListeners.delete(listener);
  };
};

export const watchReduceMotion = (instance, initialValue) => {
  let mounted = true;
  let current = reduceMotionNow(initialValue);
  const unsubscribe = subscribeReduceMotion(() => {
    const next = reduceMotionNow(initialValue);

    if (!mounted || next === current) {
      return;
    }

    current = next;
    instance.forceUpdate();
  });

  return () => {
    mounted = false;
    unsubscribe();
  };
};

const publishReduceMotion = (value) => {
  if (reduceMotionPublished && reduceMotionValue === value) {
    return;
  }

  reduceMotionPublished = true;
  reduceMotionValue = value;
  reduceMotionListeners.forEach(listener => listener(value));
};

export const resetAppearancePreferences = () => {
  reduceMotionPublished = false;
  reduceMotionValue = undefined;
  reduceMotionListeners.clear();
};

export const browserAppearanceTarget = () => {
  if (typeof document === 'undefined') {
    return { root: null, body: null };
  }

  return {
    root: document.documentElement,
    body: document.body,
  };
};

const fontProperty = (root, name, value) => {
  if (!root || !root.style || typeof root.style.setProperty !== 'function') {
    return;
  }

  root.style.setProperty(name, `${value}px`);
};

const motionClasses = (body, reduceMotion) => {
  if (!body || !body.classList) {
    return;
  }

  body.classList.toggle('reduce-motion', reduceMotion === true);
  body.classList.toggle('no-reduce-motion', reduceMotion === false);
};

export const applyAcceptedAppearance = (document, target = browserAppearanceTarget()) => {
  if (!document) {
    return null;
  }

  const appearance = acceptedAppearance(document);
  const root = target && target.root;
  const body = target && target.body;

  if (appearance.contentFontSize !== undefined) {
    fontProperty(root, '--content-font-size', appearance.contentFontSize);
  }

  if (appearance.infoFontSize !== undefined) {
    fontProperty(root, '--info-font-size', appearance.infoFontSize);
  }

  if (appearance.reduceMotion !== undefined) {
    motionClasses(body, appearance.reduceMotion);
    publishReduceMotion(appearance.reduceMotion);
  }

  return appearance;
};
