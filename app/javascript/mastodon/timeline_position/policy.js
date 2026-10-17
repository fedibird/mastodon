import { isDecimalStatusId } from '../timeline_navigation';

// Restore priority, highest first. Later steps must not undo an earlier one.
//
// 1. Modal route updates. React Router scroll returns false and P3 does not run.
// 2. Embedded settings return. Root shouldUpdateScroll supplies an explicit
//    window position. That path is not a timeline history resume.
// 3. React Router scroll (react-router-scroll-4). PUSH scrolls to the top and
//    does not read the saved entry. POP restores sessionStorage scroll for
//    that location.key (window, then each ScrollContainer).
// 4. Split return anchor. After router scroll, a single-column anchor whose
//    locationKey matches this entry re-aligns the document and then clears
//    itself. A different location.key discards the anchor. Multi-column
//    ignores it. P3 does not auto-seek while this anchor is still going to run.
// 5. P3 automatic resume. Only a POP back to the same location.key, and only
//    when History is already open and the saved row is outside the current
//    P1 window. A new PUSH never auto-applies. Closing History back to Live
//    never reopens History.
// 6. P3 explicit resume. The header control may open History, then either
//    scrolls with the P0 anchor (row already in the window) or asks P2 to
//    seek. unavailable / unsupported / not_visible / not_found / not_in_source
//    leave the window and the saved position untouched.

export const routeResumeDecision = ({
  saved,
  locationKey,
  historyAction,
  explicit = false,
} = {}) => {
  if (!saved || !saved.position) {
    return { apply: false, reason: 'absent' };
  }

  if (explicit) {
    return { apply: true, reason: 'explicit' };
  }

  if (
    historyAction === 'POP'
    && saved.routeEntryKey
    && locationKey
    && saved.routeEntryKey === locationKey
  ) {
    return { apply: true, reason: 'route_pop' };
  }

  return { apply: false, reason: 'new_visit' };
};

export const autoResumeDecision = ({
  saved,
  locationKey,
  historyAction,
  historyOpen = false,
  statusInWindow = false,
  returnAnchorOwnsRestore = false,
} = {}) => {
  const decision = routeResumeDecision({
    saved,
    locationKey,
    historyAction,
    explicit: false,
  });

  if (!decision.apply) {
    return decision;
  }

  if (!historyOpen) {
    return { apply: false, reason: 'history_closed' };
  }

  if (returnAnchorOwnsRestore) {
    return { apply: false, reason: 'return_anchor' };
  }

  if (statusInWindow) {
    return { apply: false, reason: 'loaded_row' };
  }

  return { apply: true, reason: 'route_pop' };
};

export const resumeModeForWindow = ({ statusId, items } = {}) => {
  if (!isDecimalStatusId(statusId)) {
    return { mode: 'unavailable', reason: 'invalid_anchor' };
  }

  const list = Array.isArray(items) ? items : [];

  if (list.indexOf(statusId) !== -1) {
    return { mode: 'scroll', reason: 'in_window' };
  }

  return { mode: 'seek', reason: 'outside_window' };
};

export const sameHostLayout = (saved, current) => (
  !!saved
  && !!current
  && saved.hostKind === current.hostKind
  && saved.layout === current.layout
);

export const isNondestructiveSeekOutcome = (outcome) => (
  outcome === 'unavailable'
  || outcome === 'unsupported'
  || outcome === 'not_visible'
  || outcome === 'not_found'
  || outcome === 'not_in_source'
);
