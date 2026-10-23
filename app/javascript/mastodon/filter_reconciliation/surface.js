import { isStatusId } from '../utils/filter_rules';
import { registerFilterSurface, prioritizeFilterSurface, releaseFilterSurface, RETAIN_LIMIT } from './scheduler';
import { captureFilterAnchor, restoreFilterAnchor } from './scroll_anchor';

export const normalizeStatusIds = (lists, limit = Infinity) => {
  const ids = new Set();
  for (const list of lists) {
    for (const value of list || []) {
      if (ids.size >= limit) break;
      const id = Number.isSafeInteger(value) ? String(value) : value;
      if (isStatusId(id)) ids.add(id);
    }
  }
  return Array.from(ids);
};

// One instance per mounted list/pane, independent of timeline ID/scrollKey.
export class FilterSurface {

  constructor(dispatch, node, { bindToDocument, scrollKey, preventScroll, ids, idForRow, followingLatest, onAcceptedScroll }) {
    this.dispatch = dispatch;
    this.node = node;
    this.bindToDocument = bindToDocument;
    this.scrollKey = scrollKey;
    this.preventScroll = preventScroll;
    this.followingLatest = followingLatest;
    this.onAcceptedScroll = onAcceptedScroll;
    this.idForRow = idForRow || (id => id.startsWith('f-') ? id.slice(2) : id);
    this.visible = new Set();
    this.near = new Set();
    this.nearRows = new Map();
    this.priorityFrame = null;
    this.frame = null;
    this.target = bindToDocument ? document : node;
    this.cancel = () => {
      if (this.frame !== null) cancelAnimationFrame(this.frame);
      this.frame = null;
      this.snapshot = null;
    };
    ['wheel', 'touchstart', 'pointerdown', 'keydown'].forEach(event => this.target.addEventListener(event, this.cancel, { passive: true }));
    this.onScroll = () => {
      if (this.priorityFrame !== null) return;
      this.priorityFrame = requestAnimationFrame(() => {
        this.priorityFrame = null;
        this.refreshPriority();
      });
    };
    this.target.addEventListener('scroll', this.onScroll, { passive: true });
    this.update(ids);
  }

  scroller() {
    return this.bindToDocument ? (document.scrollingElement || document.documentElement) : this.node;
  }

  top() {
    return this.bindToDocument ? 0 : this.node.getBoundingClientRect().top;
  }

  update(ids) {
    this.sourceIds = ids;
    this.ids = new Set(normalizeStatusIds([ids], RETAIN_LIMIT));
    this.visible = new Set(Array.from(this.visible).filter(id => this.owns(id)));
    this.near = new Set(Array.from(this.near).filter(id => this.owns(id)));
    this.nearRows.forEach((row, rowId) => {
      if (!row.isConnected || !this.owns(this.idForRow(String(rowId)))) this.nearRows.delete(rowId);
    });
    this.dispatch(registerFilterSurface(this, { ids: this.ids, sourceIds: this.sourceIds, visible: this.visible, near: this.near, prepare: () => this.prepare() }));
  }

  owns(id) {
    return isStatusId(id) && (this.ids.has(id) || this.sourceIds?.includes(id));
  }

  intersection(rowId, intersecting, entry) {
    const id = this.idForRow(String(rowId));
    if (!this.owns(id)) return;
    if (intersecting && entry?.target) this.nearRows.set(rowId, entry.target);
    else this.nearRows.delete(rowId);
    if (intersecting) this.near.add(id);
    else this.near.delete(id);
    // IO delivers many rows in one turn. Batch geometry and scheduler updates
    // into one frame, instead of forcing layout after every virtual row render.
    this.onScroll();
  }

  refreshPriority() {
    const visible = new Set();
    const bounds = this.node.getBoundingClientRect();
    const top = this.bindToDocument ? 0 : bounds.top;
    const bottom = this.bindToDocument ? window.innerHeight : bounds.bottom;
    this.nearRows.forEach((row, rowId) => {
      if (!row.isConnected) {
        this.nearRows.delete(rowId);
        return;
      }
      const rect = row.getBoundingClientRect();
      const id = this.idForRow(String(rowId));
      if (this.owns(id) && rect.height > 0 && rect.bottom > top && rect.top < bottom) visible.add(id);
    });
    this.visible = visible;
    this.dispatch(prioritizeFilterSurface(this, visible, new Set(this.near)));
  }

  prepare() {
    if (this.frame !== null || this.preventScroll || document.hidden || document.body.style.overflow === 'hidden' || !this.node.isConnected) return;
    const bounds = this.node.getBoundingClientRect();
    if (bounds.bottom <= 0 || bounds.top >= window.innerHeight || bounds.right <= 0 || bounds.left >= window.innerWidth) return;
    // Only the list crossing the document reading edge owns its correction.
    // Other simultaneously mounted lists must not fight the same scroller.
    if (this.bindToDocument && bounds.top > 0) return;
    this.snapshot = captureFilterAnchor(this.node, this.scroller(), this.top());
    if (!this.snapshot) return;
    const snapshot = this.snapshot;
    // Two finite frames cover connected React children and cached row layout.
    // Follow state is read on each frame so a prepend or a mode change cannot
    // reuse a stale decision from capture time.
    this.frame = requestAnimationFrame(() => {
      if (this.snapshot !== snapshot) return;
      this.restoreSnapshot(snapshot);
      this.frame = requestAnimationFrame(() => {
        if (this.snapshot === snapshot) this.restoreSnapshot(snapshot);
        this.frame = null;
        this.snapshot = null;
      });
    });
  }

  restoreSnapshot(snapshot) {
    const following = typeof this.followingLatest === 'function' && this.followingLatest();

    restoreFilterAnchor(snapshot, this.node, this.scroller(), this.top(), {
      allowScroll: !following,
      onAcceptedScroll: this.onAcceptedScroll,
    });
  }

  destroy() {
    this.cancel();
    if (this.priorityFrame !== null) cancelAnimationFrame(this.priorityFrame);
    this.target.removeEventListener('scroll', this.onScroll);
    this.nearRows.clear();
    ['wheel', 'touchstart', 'pointerdown', 'keydown'].forEach(event => this.target.removeEventListener(event, this.cancel));
    this.dispatch(releaseFilterSurface(this));
  }

}
