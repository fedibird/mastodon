import { defineMessages } from 'react-intl';
import { closeModal, openModal } from './modal';
import {
  replyInComposer,
  quoteInComposer,
  mentionInComposer,
  directInComposer,
} from './compose';
import { createComposer } from './composer';
import { selectComposer, selectPortableComposerSeed } from '../selectors/composer';
import { defaultMediaShape, defaultMediaSize, defaultMediaVisibility } from '../utils/media_display';
import {
  fullscreenComposerIdFor,
  getActiveFullscreenComposerId,
  initialFullscreenPresentation,
  setActiveFullscreenComposerId,
} from '../utils/fullscreen_column';
import { resolveFullscreenSource, stripRouterBasename } from '../features/fullscreen_column/sources';

export const FULLSCREEN_COLUMN_OPEN = 'FULLSCREEN_COLUMN_OPEN';
export const FULLSCREEN_COLUMN_CLOSE = 'FULLSCREEN_COLUMN_CLOSE';
export const FULLSCREEN_COLUMN_PATCH = 'FULLSCREEN_COLUMN_PATCH';

const messages = defineMessages({
  replyConfirm: { id: 'confirmations.reply.confirm', defaultMessage: 'Reply' },
  replyMessage: { id: 'confirmations.reply.message', defaultMessage: 'Replying now will overwrite the message you are currently composing. Are you sure you want to proceed?' },
  quoteConfirm: { id: 'confirmations.quote.confirm', defaultMessage: 'Quote' },
  quoteMessage: { id: 'confirmations.quote.message', defaultMessage: 'Quoting now will overwrite the message you are currently composing. Are you sure you want to proceed?' },
});

const silentHistory = { push () {} };
let viewSerial = 0;

const nextViewId = () => {
  viewSerial += 1;
  return `fsview:${viewSerial}:${Date.now()}`;
};

export const closeFullscreenColumn = () => {
  setActiveFullscreenComposerId(null);

  return { type: FULLSCREEN_COLUMN_CLOSE };
};

export const patchFullscreenColumn = (patch) => ({
  type: FULLSCREEN_COLUMN_PATCH,
  patch,
});

export function openFullscreenColumn (input = {}) {
  return (dispatch, getState) => {
    const state = getState();

    if (state.getIn(['meta', 'layout']) === 'mobile') {
      return null;
    }

    const source = resolveFullscreenSource(state, {
      ...input,
      pathname: stripRouterBasename(input.pathname || (typeof window !== 'undefined' ? window.location.pathname : '')),
    });

    if (!source) {
      return null;
    }

    const viewId = nextViewId();
    const composerId = fullscreenComposerIdFor(source.sourceKey);

    setActiveFullscreenComposerId(source.supportsComposer ? composerId : null);
    dispatch({
      type: FULLSCREEN_COLUMN_OPEN,
      viewId,
      composerId,
      source,
      anchorStatusId: input.anchorStatusId || null,
      presentation: initialFullscreenPresentation(source.layoutMode, {
        shape: defaultMediaShape(),
        size: defaultMediaSize(),
        visibility: defaultMediaVisibility(),
      }),
    });

    return viewId;
  };
}

export const setFullscreenComposerOpen = (composerOpen) => patchFullscreenColumn({ composerOpen: !!composerOpen });

// A reference from a media modal opens the composer underneath that modal.
// Drop every open modal in the same update so the existing history handoff
// can replace the modal entry instead of stacking the composer above it.
export function dismissFullscreenModals () {
  return (dispatch, getState) => {
    const stack = getState().get('modal');
    const count = stack && typeof stack.size === 'number' ? stack.size : 0;

    for (let index = 0; index < count; index += 1) {
      dispatch(closeModal());
    }
  };
}

export const pushFullscreenPath = (path) => (dispatch, getState) => {
  const current = getState().getIn(['fullscreenColumn', 'paths']);

  if (!current || !path) {
    return;
  }

  dispatch(patchFullscreenColumn({ paths: current.push(String(path)) }));
};

export const popFullscreenPath = () => (dispatch, getState) => {
  const current = getState().getIn(['fullscreenColumn', 'paths']);

  if (!current || current.isEmpty()) {
    dispatch(closeFullscreenColumn());
    return;
  }

  dispatch(patchFullscreenColumn({ paths: current.pop() }));
};

export const fullscreenModalScope = (state) => {
  const session = state.get('fullscreenColumn');

  if (!session || !session.get('open')) {
    return null;
  }

  return {
    viewId: session.get('viewId'),
    composerId: session.get('composerId'),
  };
};

// The composer that should receive a result captured when the user started
// the action. A later close or a different fullscreen must not retarget it,
// and must not open that other composer's popup.
export const capturedComposerDestination = (capturedComposerId, currentComposerId) => ({
  composerId: capturedComposerId || null,
  reveal: !!(capturedComposerId && capturedComposerId === currentComposerId),
});

const ensureFullscreenComposer = (dispatch, getState, composerId, reveal = true) => {
  if (!selectComposer(getState(), composerId)) {
    dispatch(createComposer(composerId, selectPortableComposerSeed(getState())));
  }

  if (reveal) {
    dispatch(setFullscreenComposerOpen(true));
  }
};

export function dispatchFullscreenCompose (kind, target, intl, composerIdOverride) {
  return (dispatch, getState) => {
    const state = getState();
    const sessionComposerId = state.getIn(['fullscreenColumn', 'composerId']);
    const composerId = composerIdOverride || sessionComposerId || getActiveFullscreenComposerId();
    const destination = capturedComposerDestination(composerId, sessionComposerId);

    if (!composerId || (!composerIdOverride && !state.get('fullscreenColumn'))) {
      return false;
    }

    const composer = selectComposer(state, composerId);
    const dirty = !!(composer && composer.get('dirty') && String(composer.get('text') || '').trim().length !== 0);
    const run = () => {
      ensureFullscreenComposer(dispatch, getState, composerId, !composerIdOverride || destination.reveal);

      if (kind === 'reply') {
        dispatch(replyInComposer(composerId, target, silentHistory));
      } else if (kind === 'quote') {
        dispatch(quoteInComposer(composerId, target, silentHistory));
      } else if (kind === 'mention') {
        dispatch(mentionInComposer(composerId, target, silentHistory));
      } else if (kind === 'direct') {
        dispatch(directInComposer(composerId, target, silentHistory));
      }
    };

    if ((kind === 'reply' || kind === 'quote') && dirty && intl) {
      const message = kind === 'quote' ? messages.quoteMessage : messages.replyMessage;
      const confirm = kind === 'quote' ? messages.quoteConfirm : messages.replyConfirm;

      dispatch(openModal('CONFIRM', {
        message: intl.formatMessage(message),
        confirm: intl.formatMessage(confirm),
        onConfirm: run,
      }));
    } else {
      run();
    }

    return true;
  };
}
