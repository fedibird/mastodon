import { normalizeTimelineLayout, timelineFlowColumnsForWidth } from './timeline_layout';

export const FULLSCREEN_SCALES = {
  small: 1,
  medium: 1.25,
  large: 1.5,
  max: 2,
};

export const FULLSCREEN_SCALE_OPTIONS = ['small', 'medium', 'large', 'max'];
export const FULLSCREEN_APPEARANCES = ['normal', 'card', 'media'];

export const fullscreenScaleFactor = (scale) => FULLSCREEN_SCALES[scale] || FULLSCREEN_SCALES.small;

export const presentationFromLayoutMode = (layoutMode) => {
  const mode = normalizeTimelineLayout(layoutMode);

  if (mode === 'media') {
    return { appearance: 'media', columns: 1 };
  }

  if (mode === 'card-2' || mode === 'card-3') {
    return { appearance: 'card', columns: Number(mode.slice(-1)) };
  }

  if (mode === 'card-1') {
    return { appearance: 'card', columns: 1 };
  }

  return { appearance: 'normal', columns: 1 };
};

export const initialFullscreenPresentation = (layoutMode, media) => {
  const parsed = presentationFromLayoutMode(layoutMode);

  return {
    appearance: parsed.appearance,
    columns: parsed.columns,
    scale: 'small',
    mediaShape: media && media.shape ? media.shape : 'square',
    mediaSize: media && media.size ? media.size : 'small',
    mediaVisibility: media && media.visibility ? media.visibility : 'hide_sensitive',
  };
};

export const layoutModeForPresentation = (presentation) => {
  if (!presentation || presentation.appearance === 'media') {
    return 'media';
  }

  if (presentation.appearance === 'card') {
    const columns = Math.min(3, Math.max(1, Number(presentation.columns) || 1));
    return `card-${columns}`;
  }

  return 'normal';
};

// Column count is requested independently of scale. Callers that zoom the
// stream pass the pre-zoom width (viewport width / scale) so a large scale
// shrinks the effective count without forgetting the request.
export const fullscreenFlowColumns = (requested, viewportWidth, scale) => (
  timelineFlowColumnsForWidth(requested, (Number(viewportWidth) || 0) / fullscreenScaleFactor(scale))
);

export const fullscreenComposerIdFor = (sourceKey) => `fullscreen:${sourceKey}`;

export const captureVisibleStatusId = (opener) => {
  if (!opener || typeof opener.closest !== 'function' || typeof document === 'undefined') {
    return null;
  }

  const column = opener.closest('.column');

  if (!column) {
    return null;
  }

  const scroller = column.querySelector('.timeline-split__pane--history .scrollable')
    || column.querySelector('.scrollable')
    || column;
  const rect = scroller.classList && scroller.classList.contains('scrollable--document')
    ? { top: 0, bottom: window.innerHeight || 0 }
    : scroller.getBoundingClientRect();
  const nodes = column.querySelectorAll('.status__wrapper[data-id], .status[data-id]');
  let best = null;
  let bestTop = Infinity;

  Array.from(nodes).forEach((node) => {
    const box = node.getBoundingClientRect();

    if (box.bottom < rect.top || box.top > rect.bottom) {
      return;
    }

    if (box.top < bestTop) {
      bestTop = box.top;
      best = node.getAttribute('data-id');
    }
  });

  return best;
};

let returnFocus = null;
let activeComposerId = null;

export const rememberFullscreenOpener = (node) => {
  returnFocus = node || null;
};

export const restoreFullscreenOpener = () => {
  const node = returnFocus;
  returnFocus = null;

  if (node && typeof node.focus === 'function') {
    Promise.resolve().then(() => {
      try {
        node.focus({ preventScroll: true });
      } catch (error) {
        node.focus();
      }
    }).catch(() => {});
  }
};

export const setActiveFullscreenComposerId = (composerId) => {
  activeComposerId = composerId || null;
};

export const getActiveFullscreenComposerId = () => activeComposerId;
