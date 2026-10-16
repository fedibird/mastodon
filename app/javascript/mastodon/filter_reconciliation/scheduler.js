import { fetchFilters } from '../actions/filter_definitions';
import { reconcileFilterMatches, clearFilterMatches } from '../actions/filter_matches';
import { isStatusId } from '../utils/filter_rules';

export const RETAIN_LIMIT = 2000;
export const SURFACE_LIMIT = 64;
export const BATCH_SIZE = 100;
export const BATCH_DELAY = 80;
const schedulers = new WeakMap();
const browserDocument = () => typeof document === 'undefined' ? null : document;
const browserWindow = () => typeof window === 'undefined' ? null : window;

// Round robin within each priority tier: a busy column cannot starve a pane.
export const candidatesFor = surfaces => {
  const selected = new Set();
  const groups = Array.from(surfaces.values());
  for (const tier of ['visible', 'near', 'ids']) {
    const lists = groups.map(surface => Array.from(surface[tier] || []).filter(isStatusId).slice(0, RETAIN_LIMIT));
    const length = Math.max(0, ...lists.map(ids => ids.length));
    for (let i = 0; i < length && selected.size < RETAIN_LIMIT; i++) {
      lists.forEach(ids => {
        if (selected.size < RETAIN_LIMIT && ids[i]) selected.add(ids[i]);
      });
    }
  }
  return selected;
};

export class FilterScheduler {

  constructor(dispatch, getState, environment = {}) {
    this.dispatch = dispatch;
    this.getState = getState;
    this.document = environment.document === undefined ? browserDocument() : environment.document;
    this.window = environment.window === undefined ? browserWindow() : environment.window;
    this.surfaces = new Map();
    this.attempts = new Map();
    this.inflight = new Set();
    this.retained = new Set();
    this.timer = null;
    this.active = 0;
    this.epoch = 0;
    this.blockedUntil = 0;
    this.baselineAttempted = false;
    this.wake = () => {
      if (this.paused()) return;
      if (!this.getState().getIn(['filterMatches', 'baseline'])) this.baselineAttempted = false;
      // Recovery is event driven, never an autonomous retry timer.
      const now = Date.now();
      this.attempts.forEach((attempt, id) => {
        if (attempt.failed && now - attempt.at >= 60000) this.attempts.delete(id);
      });
      this.schedule();
    };
  }

  paused() {
    return this.document?.hidden || this.window?.navigator?.onLine === false || Date.now() < this.blockedUntil;
  }

  register(token, surface) {
    if (!this.surfaces.has(token) && this.surfaces.size >= SURFACE_LIMIT) return;
    if (this.surfaces.size === 0) {
      this.document?.addEventListener('visibilitychange', this.wake);
      this.window?.addEventListener('online', this.wake);
    }
    this.surfaces.set(token, { ...surface, visible: new Set(surface.visible || []), near: new Set(surface.near || []) });
    this.schedule();
  }

  priority(token, visible, near) {
    const surface = this.surfaces.get(token);
    if (!surface) return;
    // A visible revisit permits a failed row one fresh attempt after a minute.
    visible.forEach(id => {
      const attempt = this.attempts.get(id);
      if (!surface.visible.has(id) && attempt?.failed && Date.now() - attempt.at >= 60000) this.attempts.delete(id);
    });
    surface.visible = new Set(visible);
    surface.near = new Set(near);
    this.schedule();
  }

  release(token) {
    this.surfaces.delete(token);
    if (this.surfaces.size) {
      this.schedule();
      return;
    }
    this.epoch++;
    clearTimeout(this.timer);
    this.timer = null;
    this.document?.removeEventListener('visibilitychange', this.wake);
    this.window?.removeEventListener('online', this.wake);
    const ids = Array.from(this.retained);
    this.retained.clear();
    this.attempts.clear();
    this.baselineAttempted = false;
    if (ids.length) this.dispatch(clearFilterMatches(ids));
  }

  beforeChange() {
    this.surfaces.forEach(surface => surface.prepare?.());
  }

  changed(previous, action) {
    if (!this.surfaces.size) return;
    const current = this.getState().get('filterMatches');
    if (action.type === 'FILTER_MATCHES_FAIL') {
      if (action.status === 429) this.blockedUntil = Math.max(this.blockedUntil, action.retryAt || Date.now() + 60000);
      if ([401, 403, 422].includes(action.status)) this.blockedUntil = Math.max(this.blockedUntil, Date.now() + 60000);
    }
    if (previous !== current) this.schedule();
  }

  schedule() {
    if (!this.surfaces.size || this.timer !== null || this.paused()) return;
    this.timer = setTimeout(() => {
      this.timer = null;
      this.drain();
    }, BATCH_DELAY);
  }

  drain() {
    if (!this.surfaces.size || this.paused()) return;
    const state = this.getState();
    const matches = state.get('filterMatches');
    if (!matches.get('baseline')) {
      if (!this.baselineAttempted) {
        this.baselineAttempted = true;
        this.dispatch(fetchFilters({ timeout: 15000 }));
      }
      return;
    }
    const generation = matches.get('generation');
    if (generation !== this.generation) {
      this.generation = generation;
      this.attempts.clear();
    }
    const selected = candidatesFor(this.surfaces);
    const removed = Array.from(this.retained).filter(id => !selected.has(id));
    this.retained = selected;
    this.attempts.forEach((_, id) => {
      if (!selected.has(id)) this.attempts.delete(id);
    });
    if (removed.length) this.dispatch(clearFilterMatches(removed));
    if (this.active) return; // One POST at a time, including old generations.
    const ids = [];
    selected.forEach(id => {
      if (ids.length >= BATCH_SIZE || this.inflight.has(id) || !state.getIn(['statuses', id])) return;
      const entry = matches.getIn(['entries', id]);
      if (entry?.get('resultGeneration') === generation && entry.has('filterIds')) return;
      if (entry?.get('phase') === 'pending' && entry.get('generation') === generation) return;
      // Gen 0 trusts freshly imported FilterResults. Edits of an existing
      // overlay are still rechecked; a changed definition opts all owners in.
      if (generation === 0 && entry?.get('phase') !== 'unevaluated') return;
      const attempt = this.attempts.get(id);
      if (attempt && attempt.generation === generation && attempt.entry === entry) return;
      ids.push(id);
    });
    if (!ids.length) return;
    const epoch = this.epoch;
    this.active++;
    ids.forEach(id => this.inflight.add(id));
    // P2 owns serials, validation and stale/content response rejection.
    Promise.resolve(this.dispatch(reconcileFilterMatches(ids, { timeout: 15000 }))).finally(() => {
      this.active--;
      ids.forEach(id => this.inflight.delete(id));
      if (epoch === this.epoch) {
        const current = this.getState().get('filterMatches');
        if (current.get('generation') === generation) {
          ids.forEach(id => {
            if (!this.retained.has(id)) return;
            const entry = current.getIn(['entries', id]);
            // An edit rejected the in-flight response: allow a fresh request.
            if (entry?.get('phase') !== 'unevaluated') this.attempts.set(id, { generation, entry, at: Date.now(), failed: ['failed', 'unavailable'].includes(entry?.get('phase')) });
          });
        }
      }
      this.schedule();
    }).catch(() => {
      // P2 normally resolves failures. Guard unexpected caller/store teardown.
      this.blockedUntil = Date.now() + 60000;
    });
  }

  stats() {
    return { surfaces: this.surfaces.size, retained: this.retained.size, attempts: this.attempts.size, inflight: this.inflight.size, active: this.active, timers: this.timer === null ? 0 : 1 };
  }

}

export const getFilterScheduler = (dispatch, getState) => {
  let scheduler = schedulers.get(getState);
  if (!scheduler) {
    scheduler = new FilterScheduler(dispatch, getState);
    schedulers.set(getState, scheduler);
  }
  return scheduler;
};

export const registerFilterSurface = (token, surface) => (dispatch, getState) => getFilterScheduler(dispatch, getState).register(token, surface);
export const prioritizeFilterSurface = (token, visible, near) => (dispatch, getState) => getFilterScheduler(dispatch, getState).priority(token, visible, near);
export const releaseFilterSurface = token => (dispatch, getState) => getFilterScheduler(dispatch, getState).release(token);
export const retryFilterReconciliation = () => (dispatch, getState) => getFilterScheduler(dispatch, getState).wake();

const layoutActions = new Set(['FILTERS_FETCH_SUCCESS', 'FILTER_MATCHES_SUCCESS', 'FILTER_MATCHES_CLEAR', 'STATUS_IMPORT', 'STATUSES_IMPORT', 'POLLS_IMPORT']);
export const filterReconciliationMiddleware = ({ dispatch, getState }) => next => action => {
  const scheduler = getFilterScheduler(dispatch, getState);
  const previous = getState().get('filterMatches');
  if (layoutActions.has(action.type)) scheduler.beforeChange();
  const result = next(action);
  scheduler.changed(previous, action);
  return result;
};
