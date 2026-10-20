import { isAdministrator } from '../initial_state';
import { isExistingPostEdit } from './materialize';
import {
  lockedStyleHardRejects,
  portablePostingContextReady,
  selectPortablePostingStyleCandidates,
  styleMatchesSurface,
} from './surface';

// global/default is the saved usual style. It is not a composer surface.
export const GLOBAL_SURFACE = Object.freeze({ kind: 'global', key: 'default' });

const targetKind = style => (style && style.getIn ? (style.getIn(['target', 'kind']) || 'none') : 'none');

const findStyle = (styles, styleId) => {
  if (!styles || !styles.find || styleId === null || styleId === undefined || styleId === '') {
    return null;
  }

  return styles.find(style => style.get('id') === String(styleId)) || null;
};

const singleDedicatedStyle = (styles, composer) => {
  const dedicated = selectPortablePostingStyleCandidates(styles, composer.get('surface'))
    .filter(style => targetKind(style) !== 'none');

  if (!dedicated || dedicated.size !== 1) {
    return null;
  }

  const style = dedicated.get(0);

  if (lockedStyleHardRejects(composer, style)) {
    return null;
  }

  return style;
};

const assignmentStatus = assignment => (assignment && assignment.get ? assignment.get('status') : null);

const savedStatus = assignment => (assignment && assignment.get ? assignment.get('assignmentStatus') : null);

// Shared by first open, post-success restore, and "return to usual".
// Loading, failure, and a missing catalog row are not unset.
// A global row never guesses a dedicated style by itself.
export function decideUsualSelection({ portable, composer, styles, placeAssignment, globalAssignment, catalogStatus }) {
  if (catalogStatus !== 'ready') {
    return { phase: 'pending', reason: 'catalog' };
  }

  if (portable) {
    if (!placeAssignment || assignmentStatus(placeAssignment) === 'idle' || assignmentStatus(placeAssignment) === 'loading' || assignmentStatus(placeAssignment) === 'saving') {
      return { phase: 'pending', reason: 'place' };
    }

    if (assignmentStatus(placeAssignment) === 'failed') {
      return { phase: 'failed', reason: 'place', scope: 'place' };
    }

    if (!portablePostingContextReady(composer)) {
      return { phase: 'pending', reason: 'context' };
    }

    const status = savedStatus(placeAssignment);

    if (status === 'style') {
      const styleId = placeAssignment.get('styleId');
      const style = findStyle(styles, styleId);

      if (!style) {
        return { phase: 'pending', reason: 'catalog_style', scope: 'place' };
      }

      if (!styleMatchesSurface(style, composer.get('surface')) || lockedStyleHardRejects(composer, style)) {
        return { phase: 'unavailable', scope: 'place', styleId: String(styleId) };
      }

      return { phase: 'style', style, origin: 'saved_default', scope: 'place' };
    }

    if (status === 'none') {
      return { phase: 'none', origin: 'saved_default', scope: 'place' };
    }

    if (status === 'unavailable') {
      return { phase: 'unavailable', scope: 'place', styleId: placeAssignment.get('styleId') ? String(placeAssignment.get('styleId')) : null };
    }

    if (status !== 'unset') {
      return { phase: 'pending', reason: 'place' };
    }

    const dedicated = singleDedicatedStyle(styles, composer);

    if (dedicated) {
      return { phase: 'style', style: dedicated, origin: 'automatic', scope: 'dedicated' };
    }
  }

  return decideGlobal({ portable, composer, styles, globalAssignment });
}

function decideGlobal({ portable, composer, styles, globalAssignment }) {
  if (!globalAssignment || assignmentStatus(globalAssignment) === 'idle' || assignmentStatus(globalAssignment) === 'loading' || assignmentStatus(globalAssignment) === 'saving') {
    return { phase: 'pending', reason: 'global' };
  }

  if (assignmentStatus(globalAssignment) === 'failed') {
    return { phase: 'failed', reason: 'global', scope: 'global' };
  }

  const status = savedStatus(globalAssignment);

  if (!status || status === 'unset' || status === 'none') {
    return { phase: 'none', origin: 'usual', scope: 'global' };
  }

  if (status === 'unavailable') {
    return { phase: 'unavailable', scope: 'global', styleId: globalAssignment.get('styleId') ? String(globalAssignment.get('styleId')) : null };
  }

  if (status !== 'style') {
    return { phase: 'pending', reason: 'global' };
  }

  const style = findStyle(styles, globalAssignment.get('styleId'));

  if (!style) {
    return { phase: 'pending', reason: 'catalog_style', scope: 'global' };
  }

  if (portable && (!styleMatchesSurface(style, composer.get('surface')) || lockedStyleHardRejects(composer, style))) {
    return { phase: 'none', origin: 'usual', scope: 'global_unfit' };
  }

  return { phase: 'style', style, origin: 'saved_default', scope: 'global' };
}

// Hold a new post until the usual choice is settled, or the user explicitly
// picks a style or no style. An existing edit is left to its own rules.
export function postingStyleBlocksNewPost(composer) {
  if (!isAdministrator || !composer || isExistingPostEdit(composer)) {
    return false;
  }

  const style = composer.get('userPostingStyle');

  if (!style || style.get('resolutionRequired') !== true) {
    return false;
  }

  const usage = style.get('usageMode') || 'usual';
  const kind = style.get('selectionKind') || 'pending';

  if ((usage === 'once' || usage === 'keep') && (kind === 'style' || kind === 'none')) {
    return false;
  }

  return kind === 'pending' || kind === 'unavailable' || kind === 'failed';
}

export function usualSelectionName(decision) {
  if (!decision) {
    return null;
  }

  if (decision.phase === 'style' && decision.style && decision.style.get) {
    return decision.style.get('name') || null;
  }

  return null;
}
