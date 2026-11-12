import React from 'react';
import PropTypes from 'prop-types';
import classNames from 'classnames';
import { defineMessages, injectIntl } from 'react-intl';
import {
  createEmojiMute,
  deleteEmojiMute,
  loadEmojiMutesDocument,
  resolveEmojiReference,
  updateEmojiMute,
} from '../emoji_actions/api';
import EmojiPickerShell from '../emoji_picker_shell';
import { noteEmojiMutesChanged } from '../emoji_mute_store';

export const DEFAULT_REPLACEMENT = '◻';

const codePointLabel = native => Array.from(typeof native === 'string' ? native : '')
  .map(ch => `U+${ch.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')}`)
  .join(' ');

const describeReference = (reference, detail) => {
  if (!reference) return '';

  if (reference.kind === 'unicode') {
    return [detail && detail.emoji_id, codePointLabel(reference.native)].filter(Boolean).join(' · ');
  }

  if (reference.scope === 'remote') {
    return `:${reference.shortcode || ''}@${reference.domain || ''}:`;
  }

  return reference.shortcode ? `:${reference.shortcode}:` : '';
};

const replacementBytes = value => {
  const text = value === null || value === undefined ? '' : String(value);

  if (typeof TextEncoder === 'function') return new TextEncoder().encode(text).length;

  return unescape(encodeURIComponent(text)).length;
};

const replacementProblem = value => {
  if (typeof value !== 'string') return 'invalid_type';
  if (value.match(/[\u0000-\u001F\u007F]/)) return 'invalid_character';

  const length = typeof Intl !== 'undefined' && typeof Intl.Segmenter === 'function'
    ? Array.from(new Intl.Segmenter(undefined, { granularity: 'grapheme' }).segment(value)).length
    : Array.from(value).length;

  return length > 32 || replacementBytes(value) > 256 ? 'too_long' : '';
};

const messages = defineMessages({
  title: { id: 'emoji_mutes.title', defaultMessage: 'Muted emoji' },
  intro: { id: 'emoji_mutes.intro', defaultMessage: 'Manage how muted emoji are replaced, hidden, and handled.' },
  loading: { id: 'emoji_mutes.loading', defaultMessage: 'Loading muted emoji…' },
  loadError: { id: 'emoji_mutes.load_error', defaultMessage: 'Muted emoji could not be loaded.' },
  retry: { id: 'emoji_mutes.retry', defaultMessage: 'Try again' },
  empty: { id: 'emoji_mutes.empty', defaultMessage: 'You have not muted any emoji.' },
  search: { id: 'emoji_mutes.search', defaultMessage: 'Search muted emoji' },
  searchPlaceholder: { id: 'emoji_mutes.search_placeholder', defaultMessage: 'Shortcode, domain, code point, or replacement' },
  noMatches: { id: 'emoji_mutes.no_matches', defaultMessage: 'No muted emoji matches that search.' },
  shown: { id: 'emoji_mutes.shown', defaultMessage: 'Showing {shown} of {count}' },
  replacement: { id: 'emoji_mutes.replacement', defaultMessage: 'Replacement text' },
  replacementHint: { id: 'emoji_mutes.replacement_hint', defaultMessage: 'Up to 32 characters and 256 bytes. An empty value means no replacement glyph.' },
  tooLong: { id: 'emoji_mutes.too_long', defaultMessage: 'Use 32 characters and 256 bytes or fewer.' },
  invalidCharacter: { id: 'emoji_mutes.invalid_character', defaultMessage: 'Control characters cannot be used.' },
  save: { id: 'emoji_mutes.save', defaultMessage: 'Save changes' },
  saving: { id: 'emoji_mutes.saving', defaultMessage: 'Saving…' },
  saved: { id: 'emoji_mutes.saved', defaultMessage: 'Saved.' },
  saveError: { id: 'emoji_mutes.save_error', defaultMessage: 'Could not save. Your edits are still here.' },
  conflict: { id: 'emoji_mutes.conflict', defaultMessage: 'This mute changed elsewhere. Reload the page and try again.' },
  remove: { id: 'emoji_mutes.remove', defaultMessage: 'Remove mute' },
  removed: { id: 'emoji_mutes.removed', defaultMessage: 'Mute removed.' },
  removeError: { id: 'emoji_mutes.remove_error', defaultMessage: 'Could not remove this mute.' },
  disabled: { id: 'emoji_mutes.disabled', defaultMessage: 'Disabled' },
  deleted: { id: 'emoji_mutes.deleted', defaultMessage: 'Deleted' },
  unfetched: { id: 'emoji_mutes.unfetched', defaultMessage: 'Image not fetched' },
  unavailable: { id: 'emoji_mutes.unavailable', defaultMessage: 'Unavailable' },
  dirty: { id: 'emoji_mutes.dirty', defaultMessage: 'Unsaved' },
  external: { id: 'emoji_mutes.external', defaultMessage: 'Muted emoji changed in another tab. Reload before applying more changes.' },
  effectReplace: { id: 'emoji_mutes.effect_replace_applied', defaultMessage: 'Replace in text' },
  effectReject: { id: 'emoji_mutes.effect_reject_applied', defaultMessage: 'Refuse reactions on your own posts' },
  effectHide: { id: 'emoji_mutes.effect_hide_applied', defaultMessage: 'Hide reactions' },
  effectPicker: { id: 'emoji_mutes.effect_picker_applied', defaultMessage: 'Hide in pickers' },
  effectReplaceShort: { id: 'emoji_mutes.effect_replace_short', defaultMessage: 'Text' },
  effectRejectShort: { id: 'emoji_mutes.effect_reject_short', defaultMessage: 'Refuse' },
  effectHideShort: { id: 'emoji_mutes.effect_hide_short', defaultMessage: 'Hide' },
  effectPickerShort: { id: 'emoji_mutes.effect_picker_short', defaultMessage: 'Picker' },
  limit: { id: 'emoji_mutes.limit', defaultMessage: '{count} of 500' },
  authError: { id: 'emoji_mutes.auth_error', defaultMessage: 'Sign in again to manage your muted emoji.' },
  replacementView: { id: 'emoji_mutes.replacement_view', defaultMessage: 'Show replacements' },
  originalView: { id: 'emoji_mutes.original_view', defaultMessage: 'Show original emoji' },
  listMode: { id: 'emoji_mutes.list_mode', defaultMessage: 'Manage list' },
  gridMode: { id: 'emoji_mutes.grid_mode', defaultMessage: 'Select emoji' },
  selectAll: { id: 'emoji_mutes.select_all', defaultMessage: 'Select all shown' },
  clearSelection: { id: 'emoji_mutes.clear_selection', defaultMessage: 'Clear selection' },
  selected: { id: 'emoji_mutes.selected', defaultMessage: '{count} selected' },
  bulkTitle: { id: 'emoji_mutes.bulk_title', defaultMessage: 'Bulk actions' },
  bulkRemove: { id: 'emoji_mutes.bulk_remove', defaultMessage: 'Remove selected mutes' },
  bulkReplacement: { id: 'emoji_mutes.bulk_replacement', defaultMessage: 'Set replacement for selected' },
  bulkReplacementEnable: { id: 'emoji_mutes.bulk_replacement_enable', defaultMessage: 'Change replacement text' },
  bulkEffect: { id: 'emoji_mutes.bulk_effect', defaultMessage: 'Bulk setting' },
  bulkKeep: { id: 'emoji_mutes.bulk_keep', defaultMessage: 'No change' },
  bulkEnable: { id: 'emoji_mutes.bulk_enable', defaultMessage: 'Enable' },
  bulkDisable: { id: 'emoji_mutes.bulk_disable', defaultMessage: 'Disable' },
  bulkReplaceOn: { id: 'emoji_mutes.bulk_replace_on', defaultMessage: 'Replace' },
  bulkReplaceOff: { id: 'emoji_mutes.bulk_replace_off', defaultMessage: 'Do not replace' },
  bulkRejectOn: { id: 'emoji_mutes.bulk_reject_on', defaultMessage: 'Refuse' },
  bulkRejectOff: { id: 'emoji_mutes.bulk_reject_off', defaultMessage: 'Allow' },
  bulkHideOn: { id: 'emoji_mutes.bulk_hide_on', defaultMessage: 'Hide' },
  bulkHideOff: { id: 'emoji_mutes.bulk_hide_off', defaultMessage: 'Show' },
  bulkPickerOn: { id: 'emoji_mutes.bulk_picker_on', defaultMessage: 'Hide from pickers' },
  bulkPickerOff: { id: 'emoji_mutes.bulk_picker_off', defaultMessage: 'Show in pickers' },
  bulkApply: { id: 'emoji_mutes.bulk_apply', defaultMessage: 'Apply to selected' },
  bulkWorking: { id: 'emoji_mutes.bulk_working', defaultMessage: 'Applying…' },
  bulkDone: { id: 'emoji_mutes.bulk_done', defaultMessage: 'Bulk changes applied.' },
  bulkPartial: { id: 'emoji_mutes.bulk_partial', defaultMessage: 'Some items could not be changed. Review the marked rows.' },
  gridHint: { id: 'emoji_mutes.grid_hint', defaultMessage: 'Click to select. With a mouse or pen, drag across emoji to select a range.' },
  add: { id: 'emoji_mutes.add', defaultMessage: 'Add muted emoji' },
  addHint: { id: 'emoji_mutes.add_hint', defaultMessage: 'Pick an emoji to mute it with the default replacement.' },
  addDuplicate: { id: 'emoji_mutes.add_duplicate', defaultMessage: 'That emoji is already muted.' },
  addError: { id: 'emoji_mutes.add_error', defaultMessage: 'Could not add that emoji.' },
  blankReplacement: { id: 'emoji_mutes.blank_replacement', defaultMessage: '(empty)' },
  originalLoading: { id: 'emoji_mutes.original_loading', defaultMessage: 'Loading…' },
  originalUnavailable: { id: 'emoji_mutes.original_unavailable', defaultMessage: 'Unavailable' },
});

const EFFECTS = [
  ['replace_in_text', 'effectReplace', 'effectReplaceShort'],
  ['reject_reactions_to_own_posts', 'effectReject', 'effectRejectShort'],
  ['hide_reactions', 'effectHide', 'effectHideShort'],
  ['hide_in_picker', 'effectPicker', 'effectPickerShort'],
];

const copyEffects = effects => EFFECTS.reduce((result, [key]) => {
  result[key] = Boolean(effects && effects[key]);
  return result;
}, {});

const presentRule = rule => ({
  id: String(rule.id),
  revision: String(rule.revision),
  emoji: {
    kind: rule.emoji && rule.emoji.kind,
    native: rule.emoji && rule.emoji.native,
    scope: rule.emoji && rule.emoji.scope,
    custom_emoji_id: rule.emoji && rule.emoji.custom_emoji_id,
    domain: rule.emoji && rule.emoji.domain,
    shortcode: rule.emoji && rule.emoji.shortcode,
  },
  effects: copyEffects(rule.effects),
  replacement: typeof rule.replacement === 'string' ? rule.replacement : '',
  detail: {
    state: rule.detail && rule.detail.state,
    kind: rule.detail && rule.detail.kind,
    emoji_id: rule.detail && rule.detail.emoji_id,
    disabled: rule.detail && rule.detail.disabled,
    shortcode: rule.detail && rule.detail.shortcode,
    domain: rule.detail && rule.detail.domain,
    scope: rule.detail && rule.detail.scope,
  },
});

const draftFrom = rule => ({
  effects: copyEffects(rule.effects),
  replacement: rule.replacement,
});

const sameDraft = (rule, draft) => EFFECTS.every(([key]) => Boolean(rule.effects[key]) === Boolean(draft.effects[key])) && rule.replacement === draft.replacement;

const ruleStatus = (rule, text) => {
  const detail = rule.detail || {};

  if (detail.disabled) return text('disabled');
  if (detail.state === 'unavailable') return text('deleted');
  if (detail.state === 'unfetched') return text('unfetched');
  if (detail.state && detail.state !== 'resolved' && detail.state !== 'fetched') return text('unavailable');
  return '';
};

const matchesQuery = (rule, query) => {
  if (!query) return true;

  const haystack = [
    describeReference(rule.emoji, rule.detail),
    rule.replacement,
    rule.detail.state,
    rule.detail.emoji_id,
    rule.detail.shortcode,
    rule.detail.domain,
    rule.emoji.shortcode,
    rule.emoji.domain,
    rule.emoji.kind === 'unicode' ? codePointLabel(rule.emoji.native) : '',
    rule.emoji.native,
  ].filter(Boolean).join('\n').toLocaleLowerCase();

  return haystack.includes(query.toLocaleLowerCase());
};

const pickerReference = payload => {
  if (!payload) return null;

  if (payload.custom) {
    const raw = payload.colons || payload.native || payload.id || '';
    const shortcode = String(raw).replace(/^:/, '').replace(/:$/, '');
    return shortcode ? { kind: 'custom', scope: 'local', shortcode } : null;
  }

  return payload.native ? { kind: 'unicode', native: payload.native } : null;
};

export class EmojiMuteSettings extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    loadDocument: PropTypes.func,
    saveRule: PropTypes.func,
    removeRule: PropTypes.func,
    createRule: PropTypes.func,
    resolveEmoji: PropTypes.func,
    onChanged: PropTypes.func,
  };

  static defaultProps = {
    loadDocument: loadEmojiMutesDocument,
    saveRule: updateEmojiMute,
    removeRule: deleteEmojiMute,
    createRule: createEmojiMute,
    resolveEmoji: resolveEmojiReference,
    onChanged: noteEmojiMutesChanged,
  };

  state = {
    status: 'loading',
    revision: null,
    rules: [],
    drafts: {},
    query: '',
    previews: {},
    rowNotice: {},
    busyId: '',
    external: false,
    mode: 'list',
    showOriginal: false,
    selected: {},
    bulkReplacementEnabled: false,
    bulkReplacement: DEFAULT_REPLACEMENT,
    bulkEffects: EFFECTS.reduce((result, [key]) => ({ ...result, [key]: 'keep' }), {}),
    bulkBusy: false,
    bulkNotice: '',
    pickerOpen: false,
    addNotice: '',
  };

  loadTimeouts = new Set();

  componentDidMount() {
    this.mounted = true;
    window.addEventListener('beforeunload', this.handleUnload);
    document.addEventListener('visibilitychange', this.handleVisibility);
    window.addEventListener('pointerup', this.stopGridDrag);
    window.addEventListener('pointercancel', this.stopGridDrag);
    this.load(false);
  }

  componentDidUpdate(_prevProps, prevState) {
    if (!prevState.showOriginal && this.state.showOriginal) {
      this.ensureVisiblePreviews();
    }
  }

  componentWillUnmount() {
    this.mounted = false;
    window.removeEventListener('beforeunload', this.handleUnload);
    document.removeEventListener('visibilitychange', this.handleVisibility);
    window.removeEventListener('pointerup', this.stopGridDrag);
    window.removeEventListener('pointercancel', this.stopGridDrag);
    this.loadTimeouts.forEach(timeoutId => window.clearTimeout(timeoutId));
    this.loadTimeouts.clear();
  }

  text(id, values) {
    return this.props.intl.formatMessage(messages[id], values);
  }

  handleUnload = event => {
    if (this.anyDirty() || this.state.bulkBusy) {
      event.preventDefault();
      event.returnValue = '';
    }
  };

  handleVisibility = () => {
    if (document.visibilityState === 'visible' && !this.state.bulkBusy) this.load(true);
  };

  anyDirty(rules = this.state.rules, drafts = this.state.drafts) {
    return rules.some(rule => drafts[rule.id] && !sameDraft(rule, drafts[rule.id]));
  }

  load(background) {
    const generation = (this.generation || 0) + 1;
    this.generation = generation;

    if (!background) this.setState({ status: this.state.rules.length ? this.state.status : 'loading' });

    const request = Promise.resolve().then(() => this.props.loadDocument());
    let timeoutId;
    const timeout = new Promise((_, reject) => {
      timeoutId = window.setTimeout(() => reject(Object.assign(new Error('timeout'), { status: 0, code: 'timeout' })), 15000);
      this.loadTimeouts.add(timeoutId);
    });

    Promise.race([request, timeout]).then(document => {
      if (!this.mounted || generation !== this.generation) return null;
      if (!document) {
        if (!background) this.setState({ status: 'error' });
        return null;
      }

      if (background && this.anyDirty()) {
        if (String(document.revision) !== String(this.state.revision)) this.setState({ external: true });
        return null;
      }

      if (background && String(document.revision) === String(this.state.revision)) return null;
      this.acceptDocument(document);
      return null;
    }).catch(error => {
      if (!this.mounted || generation !== this.generation) return;
      if (background && this.state.status === 'ready') return;
      const status = error && (error.status === 401 || error.status === 403) ? 'auth' : 'error';
      this.setState({ status });
    }).finally(() => {
      // Another load may have started: only clear this request's timer.
      window.clearTimeout(timeoutId);
      this.loadTimeouts.delete(timeoutId);
    });
  }

  acceptDocument(document) {
    const rules = (document.emoji_mutes || []).map(presentRule);
    const drafts = {};
    rules.forEach(rule => { drafts[rule.id] = draftFrom(rule); });

    this.setState({
      status: 'ready',
      revision: String(document.revision),
      rules,
      drafts,
      external: false,
      rowNotice: {},
      selected: {},
      bulkNotice: '',
    }, () => {
      if (this.state.showOriginal) this.ensureVisiblePreviews();
    });
  }

  visibleRules() {
    const query = this.state.query.trim();
    return this.state.rules.filter(rule => matchesQuery(rule, query));
  }

  selectedIds() {
    return Object.keys(this.state.selected).filter(id => this.state.selected[id] && this.state.rules.some(rule => rule.id === id));
  }

  handleRetry = () => {
    this.setState({ status: 'loading' });
    this.load(false);
  };

  handleQuery = event => {
    this.setState({ query: event.target.value }, () => {
      if (this.state.showOriginal) this.ensureVisiblePreviews();
    });
  };

  handleMode = event => {
    this.setState({ mode: event.currentTarget.getAttribute('data-mode') });
  };

  handleOriginalToggle = event => {
    this.setState({ showOriginal: event.currentTarget.checked });
  };

  updateDraft(id, recipe) {
    this.setState(state => {
      const current = state.drafts[id];
      if (!current) return null;
      return {
        drafts: { ...state.drafts, [id]: recipe(current) },
        rowNotice: { ...state.rowNotice, [id]: '' },
      };
    });
  }

  handleEffect = event => {
    const id = event.currentTarget.getAttribute('data-mute-id');
    const effect = event.currentTarget.getAttribute('data-effect');
    const checked = event.currentTarget.checked;
    this.updateDraft(id, draft => ({ ...draft, effects: { ...draft.effects, [effect]: checked } }));
  };

  handleReplacement = event => {
    const id = event.currentTarget.getAttribute('data-mute-id');
    const replacement = event.currentTarget.value;
    this.updateDraft(id, draft => ({ ...draft, replacement }));
  };

  handleSave = event => {
    event.preventDefault();
    const id = event.currentTarget.getAttribute('data-mute-id');
    const rule = this.state.rules.find(entry => entry.id === id);
    const draft = this.state.drafts[id];

    if (!rule || !draft || this.state.busyId || this.state.bulkBusy || replacementProblem(draft.replacement) || sameDraft(rule, draft)) return;

    this.setState({ busyId: id });
    this.props.saveRule(id, { expectedRevision: rule.revision, effects: draft.effects, replacement: draft.replacement }).then(body => {
      if (!this.mounted) return null;
      const saved = presentRule(body.emoji_mute);
      this.props.onChanged({ revision: body.revision });
      this.setState(state => ({
        busyId: '',
        revision: body.revision ? String(body.revision) : state.revision,
        rules: state.rules.map(entry => entry.id === id ? saved : entry),
        drafts: { ...state.drafts, [id]: draftFrom(saved) },
        rowNotice: { ...state.rowNotice, [id]: 'saved' },
      }));
      return null;
    }).catch(error => {
      if (!this.mounted) return;
      const notice = error && error.status === 409 ? 'conflict' : 'saveError';
      this.setState(state => ({ busyId: '', rowNotice: { ...state.rowNotice, [id]: notice } }));
    });
  };

  removeRuleLocally(id, body) {
    this.setState(state => {
      const drafts = { ...state.drafts };
      const previews = { ...state.previews };
      const rowNotice = { ...state.rowNotice };
      const selected = { ...state.selected };
      delete drafts[id];
      delete previews[id];
      delete rowNotice[id];
      delete selected[id];
      return {
        busyId: '',
        revision: body && body.revision ? String(body.revision) : state.revision,
        rules: state.rules.filter(entry => entry.id !== id),
        drafts,
        previews,
        rowNotice,
        selected,
      };
    });
  }

  handleRemove = event => {
    const id = event.currentTarget.getAttribute('data-mute-id');
    const rule = this.state.rules.find(entry => entry.id === id);
    if (!rule || this.state.busyId || this.state.bulkBusy) return;

    this.setState({ busyId: id });
    this.props.removeRule(id, rule.revision).then(body => {
      if (this.mounted) {
        this.props.onChanged({ revision: body && body.revision });
        this.removeRuleLocally(id, body);
      }
      return null;
    }).catch(error => {
      if (!this.mounted) return;
      const notice = error && error.status === 409 ? 'conflict' : 'removeError';
      this.setState(state => ({ busyId: '', rowNotice: { ...state.rowNotice, [id]: notice } }));
    });
  };

  ensurePreview(rule) {
    const existing = this.state.previews[rule.id];
    if (existing && (existing.loading || existing.loaded)) return;

    this.setState(state => ({
      previews: { ...state.previews, [rule.id]: { loading: true, loaded: false } },
    }));

    this.props.resolveEmoji(rule.emoji).then(resolved => {
      if (!this.mounted) return null;
      const detail = resolved && resolved.detail || {};
      const customEmoji = detail.emoji || {};
      const image = rule.emoji.kind === 'unicode'
        ? (detail.image || {})
        : {
          src: customEmoji.url || customEmoji.static_url || '',
          alt: customEmoji.shortcode ? `:${customEmoji.shortcode}:` : '',
        };
      const native = rule.emoji.kind === 'unicode' ? (detail.native || rule.emoji.native || '') : '';
      this.setState(state => ({
        previews: {
          ...state.previews,
          [rule.id]: {
            loading: false,
            loaded: true,
            src: image.src || '',
            alt: image.alt || native || '',
            native: native || '',
          },
        },
      }));
      return null;
    }).catch(() => {
      if (this.mounted) {
        this.setState(state => ({
          previews: { ...state.previews, [rule.id]: { loading: false, loaded: true, error: true } },
        }));
      }
    });
  }

  ensureVisiblePreviews() {
    this.visibleRules().forEach(rule => this.ensurePreview(rule));
  }

  renderEmoji(rule, compact = false) {
    const draft = this.state.drafts[rule.id] || draftFrom(rule);

    if (!this.state.showOriginal) {
      return (
        <span className={classNames('emoji-mute-settings__replacement-glyph', { 'emoji-mute-settings__replacement-glyph--empty': draft.replacement === '' })}>
          {draft.replacement === '' ? this.text('blankReplacement') : draft.replacement}
        </span>
      );
    }

    const preview = this.state.previews[rule.id];
    if (!preview || preview.loading) return <span className='emoji-mute-settings__original-placeholder'>{this.text('originalLoading')}</span>;
    if (preview.error || (!preview.src && !preview.native)) return <span className='emoji-mute-settings__original-placeholder'>{this.text('originalUnavailable')}</span>;

    return (
      <span className={classNames('emoji-mute-settings__original-glyph', { 'emoji-mute-settings__original-glyph--compact': compact })}>
        {rule.emoji.kind === 'unicode' && preview.native ? <span aria-hidden='true'>{preview.native}</span> : null}
        {rule.emoji.kind !== 'unicode' && preview.src ? <img src={preview.src} alt={preview.alt || ''} draggable='false' /> : null}
      </span>
    );
  }

  toggleSelected(id, value) {
    this.setState(state => ({
      selected: { ...state.selected, [id]: value === undefined ? !state.selected[id] : value },
      bulkNotice: '',
    }));
  }

  handleRowSelect = event => {
    this.toggleSelected(event.currentTarget.getAttribute('data-mute-id'), event.currentTarget.checked);
  };

  handleSelectAll = () => {
    const selected = { ...this.state.selected };
    this.visibleRules().forEach(rule => { selected[rule.id] = true; });
    this.setState({ selected, bulkNotice: '' });
  };

  handleClearSelection = () => {
    this.setState({ selected: {}, bulkNotice: '' });
  };

  handleGridClick = event => {
    if (this.gridDrag && this.gridDrag.moved) return;
    this.toggleSelected(event.currentTarget.getAttribute('data-mute-id'));
  };

  handleGridPointerDown = event => {
    if (event.button !== 0 || event.pointerType === 'touch') return;
    const id = event.currentTarget.getAttribute('data-mute-id');
    const next = !this.state.selected[id];
    this.gridDrag = { value: next, moved: false, seen: { [id]: true } };
    this.toggleSelected(id, next);
    event.preventDefault();
  };

  handleGridPointerEnter = event => {
    if (!this.gridDrag || event.pointerType === 'touch') return;
    const id = event.currentTarget.getAttribute('data-mute-id');
    if (this.gridDrag.seen[id]) return;
    this.gridDrag.seen[id] = true;
    this.gridDrag.moved = true;
    this.toggleSelected(id, this.gridDrag.value);
  };

  stopGridDrag = () => {
    if (this.gridDrag) {
      this.gridDrag = null;
      this.gridSuppressClickUntil = Date.now() + 200;
    }
  };

  handleGridClickSafe = event => {
    if (this.gridSuppressClickUntil && Date.now() < this.gridSuppressClickUntil) {
      event.preventDefault();
      return;
    }
    this.handleGridClick(event);
  };

  handleBulkReplacementEnabled = event => {
    this.setState({ bulkReplacementEnabled: event.currentTarget.checked, bulkNotice: '' });
  };

  handleBulkReplacement = event => {
    this.setState({ bulkReplacement: event.currentTarget.value, bulkNotice: '' });
  };

  handleBulkEffect = event => {
    const effect = event.currentTarget.getAttribute('data-effect');
    const value = event.currentTarget.value;

    this.setState(state => ({
      bulkEffects: { ...state.bulkEffects, [effect]: value },
      bulkNotice: '',
    }));
  };

  bulkDraftFor(rule) {
    const base = this.state.drafts[rule.id] || draftFrom(rule);
    const effects = { ...base.effects };

    EFFECTS.forEach(([key]) => {
      const value = this.state.bulkEffects[key];
      if (value === 'on') effects[key] = true;
      if (value === 'off') effects[key] = false;
    });

    return {
      effects,
      replacement: this.state.bulkReplacementEnabled ? this.state.bulkReplacement : base.replacement,
    };
  }

  runBulkUpdate = async () => {
    const ids = this.selectedIds();
    const replacementValue = this.state.bulkReplacementEnabled ? this.state.bulkReplacement : '';

    if (ids.length === 0 || this.state.bulkBusy || replacementProblem(replacementValue)) return;

    const operations = ids.map(id => {
      const rule = this.state.rules.find(entry => entry.id === id);
      return rule ? { rule, draft: this.bulkDraftFor(rule) } : null;
    }).filter(Boolean);

    this.setState({ bulkBusy: true, bulkNotice: '', rowNotice: {} });
    let failed = false;
    const failedNotices = {};

    for (const { rule, draft } of operations) {
      if (sameDraft(rule, draft)) continue;

      try {
        const body = await this.props.saveRule(rule.id, { expectedRevision: rule.revision, effects: draft.effects, replacement: draft.replacement });

        if (!this.mounted) return;

        if (body && body.emoji_mute) {
          const saved = presentRule(body.emoji_mute);
          this.props.onChanged({ revision: body.revision });

          this.setState(state => ({
            revision: body.revision ? String(body.revision) : state.revision,
            rules: state.rules.map(entry => entry.id === rule.id ? saved : entry),
            drafts: { ...state.drafts, [rule.id]: draftFrom(saved) },
          }));
        }
      } catch (error) {
        failed = true;
        failedNotices[rule.id] = error && error.status === 409 ? 'conflict' : 'saveError';
      }
    }

    if (!this.mounted) return;

    if (!failed) {
      try {
        const document = await this.props.loadDocument();

        if (document) {
          this.acceptDocument(document);
        }
      } catch (error) {
        failed = true;
      }
    }

    if (!this.mounted) return;

    this.setState(state => ({
      bulkBusy: false,
      bulkNotice: failed ? 'bulkPartial' : 'bulkDone',
      rowNotice: { ...state.rowNotice, ...failedNotices },
    }));
  };

  runBulkRemove = async () => {
    const ids = this.selectedIds();
    if (ids.length === 0 || this.state.bulkBusy) return;

    this.setState({ bulkBusy: true, bulkNotice: '', rowNotice: {} });
    let failed = false;

    for (const id of ids) {
      const rule = this.state.rules.find(entry => entry.id === id);
      if (!rule) continue;

      try {
        const body = await this.props.removeRule(id, rule.revision);
        if (!this.mounted) return;
        this.removeRuleLocally(id, body);
      } catch (error) {
        if (!this.mounted) return;
        failed = true;
        const notice = error && error.status === 409 ? 'conflict' : 'removeError';
        this.setState(state => ({ rowNotice: { ...state.rowNotice, [id]: notice } }));
      }
    }

    if (this.mounted) this.setState({ bulkBusy: false, bulkNotice: failed ? 'bulkPartial' : 'bulkDone' });
  };

  togglePicker = () => {
    this.setState(state => ({ pickerOpen: !state.pickerOpen, addNotice: '' }));
  };

  closePicker = () => {
    this.setState({ pickerOpen: false });
  };

  handlePickerPick = payload => {
    const reference = pickerReference(payload);
    if (!reference || this.state.bulkBusy) return;

    this.props.createRule(reference, { replacement: DEFAULT_REPLACEMENT }).then(body => {
      if (!this.mounted || !body || !body.emoji_mute) return null;
      const rule = presentRule(body.emoji_mute);
      this.props.onChanged({ revision: body.revision });
      this.setState(state => ({
        revision: body.revision ? String(body.revision) : state.revision,
        rules: state.rules.concat(rule),
        drafts: { ...state.drafts, [rule.id]: draftFrom(rule) },
        pickerOpen: false,
        addNotice: 'saved',
      }), () => {
        if (this.state.showOriginal) this.ensurePreview(rule);
      });
      return null;
    }).catch(error => {
      if (!this.mounted) return;
      this.setState({ addNotice: error && error.status === 409 ? 'addDuplicate' : 'addError' });
    });
  };

  renderToolbar() {
    const selectedCount = this.selectedIds().length;

    return (
      <div className='emoji-mute-settings__toolbar'>
        <div className='emoji-mute-settings__tabs' role='tablist'>
          <button type='button' role='tab' aria-selected={this.state.mode === 'list'} data-mode='list' onClick={this.handleMode}>{this.text('listMode')}</button>
          <button type='button' role='tab' aria-selected={this.state.mode === 'grid'} data-mode='grid' onClick={this.handleMode}>{this.text('gridMode')}</button>
        </div>
        <label className='emoji-mute-settings__display-toggle'>
          <span>{this.text('originalView')}</span>
          <input type='checkbox' checked={this.state.showOriginal} onChange={this.handleOriginalToggle} aria-label={this.text('originalView')} />
        </label>
        <div className='emoji-mute-settings__selection-summary'>
          <strong>{this.text('selected', { count: selectedCount })}</strong>
          <button type='button' onClick={this.handleSelectAll}>{this.text('selectAll')}</button>
          <button type='button' onClick={this.handleClearSelection} disabled={selectedCount === 0}>{this.text('clearSelection')}</button>
        </div>
      </div>
    );
  }

  bulkEffectOptionLabel(key, enabled) {
    const labels = {
      replace_in_text: enabled ? 'bulkReplaceOn' : 'bulkReplaceOff',
      reject_reactions_to_own_posts: enabled ? 'bulkRejectOn' : 'bulkRejectOff',
      hide_reactions: enabled ? 'bulkHideOn' : 'bulkHideOff',
      hide_in_picker: enabled ? 'bulkPickerOn' : 'bulkPickerOff',
    };

    return this.text(labels[key]);
  }

  renderBulkPanel() {
    const selectedCount = this.selectedIds().length;
    const replacementProblemValue = this.state.bulkReplacementEnabled ? replacementProblem(this.state.bulkReplacement) : '';

    return (
      <aside className='emoji-mute-settings__bulk'>
        <h3>{this.text('bulkTitle')}</h3>
        <p>{this.text('selected', { count: selectedCount })}</p>
        <label className='emoji-mute-settings__bulk-replacement-toggle'>
          <input type='checkbox' checked={this.state.bulkReplacementEnabled} onChange={this.handleBulkReplacementEnabled} />
          {this.text('bulkReplacementEnable')}
        </label>
        <input type='text' value={this.state.bulkReplacement} onChange={this.handleBulkReplacement} disabled={!this.state.bulkReplacementEnabled} aria-label={this.text('bulkReplacement')} />
        {replacementProblemValue ? <p role='alert'>{this.text(replacementProblemValue === 'invalid_character' ? 'invalidCharacter' : 'tooLong')}</p> : null}
        <div className='emoji-mute-settings__bulk-effects'>
          {EFFECTS.map(([key, stem]) => (
            <label key={key}>
              <span>{this.text(stem)}</span>
              <select value={this.state.bulkEffects[key]} data-effect={key} onChange={this.handleBulkEffect}>
                <option value='keep'>{this.text('bulkKeep')}</option>
                <option value='on'>{this.bulkEffectOptionLabel(key, true)}</option>
                <option value='off'>{this.bulkEffectOptionLabel(key, false)}</option>
              </select>
            </label>
          ))}
        </div>
        <button type='button' className='button' onClick={this.runBulkUpdate} disabled={selectedCount === 0 || this.state.bulkBusy || Boolean(replacementProblemValue)}>
          {this.state.bulkBusy ? this.text('bulkWorking') : this.text('bulkApply')}
        </button>
        <button type='button' className='button button--destructive' onClick={this.runBulkRemove} disabled={selectedCount === 0 || this.state.bulkBusy}>
          {this.text('bulkRemove')}
        </button>
        {this.state.bulkNotice ? <p role='status'>{this.text(this.state.bulkNotice)}</p> : null}
      </aside>
    );
  }

  renderRule(rule) {
    const draft = this.state.drafts[rule.id] || draftFrom(rule);
    const problem = replacementProblem(draft.replacement);
    const dirty = !sameDraft(rule, draft);
    const notice = this.state.rowNotice[rule.id];
    const busy = this.state.busyId === rule.id;
    const identity = describeReference(rule.emoji, rule.detail);
    const status = ruleStatus(rule, id => this.text(id));

    return (
      <form key={rule.id} className={classNames('emoji-mute-settings__rule', { 'emoji-mute-settings__rule--selected': this.state.selected[rule.id] })} data-mute-id={rule.id} onSubmit={this.handleSave}>
        <div className='emoji-mute-settings__rule-select'>
          <input type='checkbox' checked={Boolean(this.state.selected[rule.id])} data-mute-id={rule.id} onChange={this.handleRowSelect} aria-label={identity} />
        </div>

        <div className='emoji-mute-settings__rule-main'>
          <div className='emoji-mute-settings__rule-glyph'>
            {this.renderEmoji(rule, true)}
          </div>

          <div className='emoji-mute-settings__rule-identity'>
            <strong>{identity}</strong>
            {status ? <span>{status}</span> : null}
            {dirty ? <span className='emoji-mute-settings__dirty'>{this.text('dirty')}</span> : null}
          </div>

          <label className='emoji-mute-settings__rule-replacement'>
            <input
              type='text'
              value={draft.replacement}
              data-mute-id={rule.id}
              onChange={this.handleReplacement}
              aria-label={this.text('replacement')}
              aria-invalid={problem ? 'true' : 'false'}
            />
            {problem ? <small role='alert'>{this.text(problem === 'invalid_character' ? 'invalidCharacter' : 'tooLong')}</small> : null}
          </label>
        </div>

        <fieldset className='emoji-mute-settings__effects'>
          {EFFECTS.map(([key, _stem, shortStem]) => (
            <label key={key}>
              <input type='checkbox' checked={Boolean(draft.effects[key])} data-mute-id={rule.id} data-effect={key} onChange={this.handleEffect} />
              <span>{this.text(shortStem)}</span>
            </label>
          ))}
        </fieldset>

        <div className='emoji-mute-settings__actions'>
          <button type='button' data-mute-id={rule.id} onClick={this.handleRemove} disabled={busy || this.state.bulkBusy}>{this.text('remove')}</button>
          <button type='submit' disabled={!dirty || Boolean(problem) || busy || this.state.bulkBusy}>{busy ? this.text('saving') : this.text('save')}</button>
        </div>

        {notice ? <p className='emoji-mute-settings__row-notice' role='status'>{this.text(notice)}</p> : null}
      </form>
    );
  }

  renderList() {
    const visible = this.visibleRules();

    return (
      <div className='emoji-mute-settings__list'>
        <div className='emoji-mute-settings__search-line'>
          <label className='emoji-mute-settings__field'>
            <span>{this.text('search')}</span>
            <input type='search' value={this.state.query} onChange={this.handleQuery} placeholder={this.text('searchPlaceholder')} />
          </label>
          <span>{this.text('shown', { shown: visible.length, count: this.state.rules.length })}</span>
        </div>
        {visible.length === 0 ? <p>{this.state.rules.length === 0 ? this.text('empty') : this.text('noMatches')}</p> : null}
        {visible.map(rule => this.renderRule(rule))}
      </div>
    );
  }

  renderGrid() {
    const visible = this.visibleRules();

    return (
      <div className='emoji-mute-settings__grid-wrap'>
        <div className='emoji-mute-settings__search-line'>
          <label className='emoji-mute-settings__field'>
            <span>{this.text('search')}</span>
            <input type='search' value={this.state.query} onChange={this.handleQuery} placeholder={this.text('searchPlaceholder')} />
          </label>
          <span>{this.text('shown', { shown: visible.length, count: this.state.rules.length })}</span>
        </div>
        <p className='emoji-mute-settings__hint'>{this.text('gridHint')}</p>
        <div className='emoji-mute-settings__grid' role='listbox' aria-multiselectable='true'>
          {visible.map(rule => (
            <button
              type='button'
              key={rule.id}
              className={classNames('emoji-mute-settings__grid-item', { 'emoji-mute-settings__grid-item--selected': this.state.selected[rule.id] })}
              data-mute-id={rule.id}
              role='option'
              aria-selected={Boolean(this.state.selected[rule.id])}
              aria-label={describeReference(rule.emoji, rule.detail)}
              onClick={this.handleGridClickSafe}
              onPointerDown={this.handleGridPointerDown}
              onPointerEnter={this.handleGridPointerEnter}
            >
              {this.renderEmoji(rule)}
            </button>
          ))}
        </div>
        {visible.length === 0 ? <p>{this.state.rules.length === 0 ? this.text('empty') : this.text('noMatches')}</p> : null}
      </div>
    );
  }

  renderAddPicker() {
    return (
      <section className='emoji-mute-settings__add'>
        <button type='button' className='button' onClick={this.togglePicker} aria-expanded={this.state.pickerOpen}>{this.text('add')}</button>
        <p className='emoji-mute-settings__hint'>{this.text('addHint')}</p>
        {this.state.addNotice ? <p role='status'>{this.text(this.state.addNotice)}</p> : null}
        {this.state.pickerOpen ? (
          <div className='emoji-mute-settings__picker'>
            <EmojiPickerShell
              open
              initialMode='standard'
              onPick={this.handlePickerPick}
              onRequestClose={this.closePicker}
              emojiSize={24}
              perLine={12}
              autoFocus
              animate
              theme='auto'
              actionsEnabled={false}
            />
          </div>
        ) : null}
      </section>
    );
  }

  render() {
    const { status, rules, external, mode } = this.state;

    return (
      <section className='emoji-mute-settings'>
        <div className='emoji-mute-settings__header'>
          <div>
            <h2>{this.text('title')}</h2>
            <p>{this.text('intro')}</p>
          </div>
          {status === 'ready' ? <span>{this.text('limit', { count: rules.length })}</span> : null}
        </div>
        {status === 'loading' ? <p role='status'>{this.text('loading')}</p> : null}
        {status === 'error' ? <p role='alert'>{this.text('loadError')} <button type='button' onClick={this.handleRetry}>{this.text('retry')}</button></p> : null}
        {status === 'auth' ? <p role='alert'>{this.text('authError')}</p> : null}
        {status === 'ready' ? (
          <React.Fragment>
            {external ? <p className='emoji-mute-settings__external' role='status'>{this.text('external')}</p> : null}
            {this.renderToolbar()}
            <div className='emoji-mute-settings__workspace'>
              <main>
                {mode === 'grid' ? this.renderGrid() : this.renderList()}
                {this.renderAddPicker()}
              </main>
              {this.renderBulkPanel()}
            </div>
          </React.Fragment>
        ) : null}
      </section>
    );
  }

}

export default injectIntl(EmojiMuteSettings);
