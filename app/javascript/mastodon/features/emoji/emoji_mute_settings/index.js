/* eslint-disable react/jsx-no-bind */

import React from 'react';
import PropTypes from 'prop-types';
import { injectIntl } from 'react-intl';
import classNames from 'classnames';
import {
  loadEmojiMutesDocument,
  updateEmojiMute,
  deleteEmojiMute,
  resolveEmojiReference,
} from '../emoji_actions/api';
import {
  DEFAULT_MUTE_EFFECTS,
  detailPathForReference,
  referenceLabel,
} from '../emoji_actions/reference';
import { noteEmojiMutesChanged } from '../emoji_mute_store';
import messages from './messages';

const EFFECT_KEYS = Object.keys(DEFAULT_MUTE_EFFECTS);

const ruleDraft = rule => ({
  id: rule.id,
  revision: rule.revision,
  emoji: rule.emoji,
  detail: rule.detail,
  effects: { ...DEFAULT_MUTE_EFFECTS, ...(rule.effects || {}) },
  replacement: rule.replacement === undefined || rule.replacement === null ? '' : String(rule.replacement),
  savedEffects: { ...DEFAULT_MUTE_EFFECTS, ...(rule.effects || {}) },
  savedReplacement: rule.replacement === undefined || rule.replacement === null ? '' : String(rule.replacement),
  error: null,
  conflict: false,
  saving: false,
  removing: false,
  preview: null,
  previewStatus: 'idle',
});

const isDirty = draft => (
  draft.replacement !== draft.savedReplacement
  || EFFECT_KEYS.some(key => Boolean(draft.effects[key]) !== Boolean(draft.savedEffects[key]))
);

const identityText = draft => {
  const emoji = draft.emoji || {};
  const detail = draft.detail || {};

  if (emoji.kind === 'unicode') {
    return `Unicode · code points ${Array.from(emoji.native || '').map(ch => `U+${ch.codePointAt(0).toString(16).toUpperCase()}`).join(' ')}`;
  }

  if (emoji.scope === 'remote') {
    return `:${emoji.shortcode}@${emoji.domain}:`;
  }

  const shortcode = emoji.shortcode || detail.shortcode;
  const id = emoji.custom_emoji_id || detail.custom_emoji_id;

  return shortcode ? `:${shortcode}: (id ${id || '—'})` : `local id ${id || '—'}`;
};

const matchesQuery = (draft, query) => {
  if (!query) {
    return true;
  }

  const haystack = [
    identityText(draft),
    referenceLabel(draft.emoji, draft.detail),
    draft.replacement,
    draft.emoji && draft.emoji.shortcode,
    draft.emoji && draft.emoji.domain,
    draft.emoji && draft.emoji.native,
    draft.detail && draft.detail.shortcode,
  ].filter(Boolean).join(' ').toLowerCase();

  return haystack.includes(query);
};

export class EmojiMuteSettings extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    loadDocument: PropTypes.func,
    updateRule: PropTypes.func,
    removeRule: PropTypes.func,
    resolveEmoji: PropTypes.func,
    onChanged: PropTypes.func,
  };

  static defaultProps = {
    loadDocument: loadEmojiMutesDocument,
    updateRule: updateEmojiMute,
    removeRule: deleteEmojiMute,
    resolveEmoji: resolveEmojiReference,
    onChanged: noteEmojiMutesChanged,
  };

  state = {
    status: 'loading',
    revision: null,
    effectApplication: null,
    drafts: [],
    revealed: false,
    previewIds: {},
    query: '',
    error: null,
  };

  componentDidMount() {
    this.mounted = true;
    this.load();
  }

  componentWillUnmount() {
    this.mounted = false;
  }

  text = (id, values) => this.props.intl.formatMessage(messages[id], values);

  load = () => {
    this.setState({ status: 'loading', error: null });

    this.props.loadDocument().then(document => {
      if (!this.mounted) {
        return;
      }

      this.setState({
        status: 'ready',
        revision: document.revision,
        effectApplication: document.effect_application || null,
        drafts: (document.emoji_mutes || []).map(ruleDraft),
        error: null,
      });
    }).catch(error => {
      if (!this.mounted) {
        return;
      }

      this.setState({ status: 'error', error });
    });
  };

  handleReveal = () => {
    this.setState(previous => ({ revealed: !previous.revealed }));
  };

  handleQuery = event => {
    this.setState({ query: event.target.value });
  };

  handleReplacement = (id, event) => {
    const replacement = event.target.value;

    this.setState(previous => ({
      drafts: previous.drafts.map(draft => (
        draft.id === id ? { ...draft, replacement, error: null, conflict: false } : draft
      )),
    }));
  };

  handleEffect = (id, key, event) => {
    const checked = event.target.checked;

    this.setState(previous => ({
      drafts: previous.drafts.map(draft => (
        draft.id === id
          ? { ...draft, effects: { ...draft.effects, [key]: checked }, error: null, conflict: false }
          : draft
      )),
    }));
  };

  handleDiscard = id => {
    this.setState(previous => ({
      drafts: previous.drafts.map(draft => (
        draft.id === id
          ? {
            ...draft,
            effects: { ...draft.savedEffects },
            replacement: draft.savedReplacement,
            error: null,
            conflict: false,
          }
          : draft
      )),
    }));
  };

  handleSave = id => {
    const draft = this.state.drafts.find(item => item.id === id);

    if (!draft || draft.saving || !isDirty(draft)) {
      return;
    }

    this.setState(previous => ({
      drafts: previous.drafts.map(item => (
        item.id === id ? { ...item, saving: true, error: null, conflict: false } : item
      )),
    }));

    this.props.updateRule(id, {
      expectedRevision: draft.revision,
      effects: draft.effects,
      replacement: draft.replacement,
    }).then(response => {
      if (!this.mounted) {
        return;
      }

      const next = ruleDraft(response.emoji_mute);

      this.props.onChanged({ revision: response.revision });
      this.setState(previous => ({
        revision: response.revision,
        drafts: previous.drafts.map(item => (item.id === id ? next : item)),
      }));
    }).catch(error => {
      if (!this.mounted) {
        return;
      }

      this.setState(previous => ({
        drafts: previous.drafts.map(item => (
          item.id === id
            ? {
              ...item,
              saving: false,
              conflict: error && error.status === 409,
              error,
            }
            : item
        )),
      }));
    });
  };

  handleReloadRule = id => {
    this.props.loadDocument().then(document => {
      if (!this.mounted) {
        return;
      }

      const remote = (document.emoji_mutes || []).find(rule => rule.id === id);
      const current = this.state.drafts.find(draft => draft.id === id);

      if (!remote || !current) {
        this.setState({
          revision: document.revision,
          drafts: (document.emoji_mutes || []).map(ruleDraft),
        });
        return;
      }

      // Keep the person's unsaved edits; refresh only the saved baseline and revision.
      this.setState(previous => ({
        revision: document.revision,
        drafts: previous.drafts.map(draft => (
          draft.id === id
            ? {
              ...draft,
              revision: remote.revision,
              detail: remote.detail,
              savedEffects: { ...DEFAULT_MUTE_EFFECTS, ...(remote.effects || {}) },
              savedReplacement: remote.replacement === undefined || remote.replacement === null ? '' : String(remote.replacement),
              conflict: false,
              error: null,
            }
            : draft
        )),
      }));
    }).catch(() => {});
  };

  handleRemove = id => {
    const draft = this.state.drafts.find(item => item.id === id);

    if (!draft || draft.removing) {
      return;
    }

    this.setState(previous => ({
      drafts: previous.drafts.map(item => (
        item.id === id ? { ...item, removing: true, error: null } : item
      )),
    }));

    this.props.removeRule(id, draft.revision).then(response => {
      if (!this.mounted) {
        return;
      }

      this.props.onChanged({ revision: response.revision });
      this.setState(previous => ({
        revision: response.revision,
        drafts: previous.drafts.filter(item => item.id !== id),
        previewIds: Object.keys(previous.previewIds).reduce((acc, key) => {
          if (key !== id) {
            acc[key] = previous.previewIds[key];
          }

          return acc;
        }, {}),
      }));
    }).catch(error => {
      if (!this.mounted) {
        return;
      }

      this.setState(previous => ({
        drafts: previous.drafts.map(item => (
          item.id === id ? { ...item, removing: false, error } : item
        )),
      }));
    });
  };

  togglePreview = id => {
    const opening = !this.state.previewIds[id];

    this.setState(previous => ({
      previewIds: {
        ...previous.previewIds,
        [id]: opening,
      },
      drafts: previous.drafts.map(draft => (
        draft.id === id && !opening
          ? { ...draft, preview: null, previewStatus: 'idle' }
          : draft
      )),
    }), () => {
      if (opening) {
        this.loadPreview(id);
      }
    });
  };

  loadPreview = id => {
    const draft = this.state.drafts.find(item => item.id === id);

    if (!draft) {
      return;
    }

    this.setState(previous => ({
      drafts: previous.drafts.map(item => (
        item.id === id ? { ...item, previewStatus: 'loading', preview: null } : item
      )),
    }));

    this.props.resolveEmoji(draft.emoji).then(resolved => {
      if (!this.mounted || !this.state.previewIds[id]) {
        return;
      }

      const detail = resolved && resolved.detail ? resolved.detail : {};
      const image = detail.image || {};
      let native = null;

      if (resolved && resolved.reference && resolved.reference.kind === 'unicode') {
        native = resolved.reference.native;
      } else if (draft.emoji && draft.emoji.kind === 'unicode') {
        native = draft.emoji.native;
      }

      const src = image.src || null;
      const available = Boolean(src || native);

      this.setState(previous => ({
        drafts: previous.drafts.map(item => (
          item.id === id
            ? {
              ...item,
              previewStatus: available ? 'ready' : 'unavailable',
              preview: available ? { src, native } : null,
            }
            : item
        )),
      }));
    }).catch(() => {
      if (!this.mounted || !this.state.previewIds[id]) {
        return;
      }

      this.setState(previous => ({
        drafts: previous.drafts.map(item => (
          item.id === id ? { ...item, previewStatus: 'unavailable', preview: null } : item
        )),
      }));
    });
  };

  kindLabel(draft) {
    const emoji = draft.emoji || {};

    if (emoji.kind === 'unicode') {
      return this.text('unicode');
    }

    if (emoji.scope === 'remote') {
      return this.text('remote');
    }

    return this.text('local');
  }

  detailFlags(draft) {
    const detail = draft.detail || {};
    const flags = [];

    if (detail.state === 'unavailable') {
      flags.push(this.text('unavailable'));
    }

    if (detail.disabled) {
      flags.push(this.text('disabled'));
    }

    if (detail.state === 'unfetched') {
      flags.push(this.text('unfetched'));
    }

    return flags;
  }

  renderRule(draft) {
    const dirty = isDirty(draft);
    const previewOpen = Boolean(this.state.previewIds[draft.id]);
    const detailPath = detailPathForReference(draft.emoji);
    const flags = this.detailFlags(draft);

    return (
      <article key={draft.id} className={classNames('ems-rule', { 'ems-rule--dirty': dirty })} data-mute-id={draft.id}>
        <header className='ems-rule-head'>
          <div>
            <div className='ems-identity'>{identityText(draft)}</div>
            <div className='ems-meta'>
              <span>{this.kindLabel(draft)}</span>
              {flags.map(flag => <span key={flag}>{flag}</span>)}
              {dirty && <span className='ems-dirty'>{this.text('dirty')}</span>}
            </div>
          </div>
          <div className='ems-rule-actions'>
            <button type='button' className='ems-button' onClick={() => this.togglePreview(draft.id)}>
              {this.text(previewOpen ? 'hidePreview' : 'showPreview')}
            </button>
            {detailPath && (
              <a className='ems-button' href={`/web${detailPath}`}>{this.text('openDetails')}</a>
            )}
            <button type='button' className='ems-button ems-danger' disabled={draft.removing} onClick={() => this.handleRemove(draft.id)}>
              {this.text(draft.removing ? 'removing' : 'remove')}
            </button>
          </div>
        </header>

        {previewOpen && (
          <div className='ems-preview' data-preview='open'>
            {draft.previewStatus === 'loading' && <p>{this.text('previewLoading')}</p>}
            {draft.previewStatus === 'unavailable' && <p>{this.text('previewUnavailable')}</p>}
            {draft.previewStatus === 'ready' && draft.preview && draft.preview.src && (
              <img src={draft.preview.src} alt='' draggable='false' />
            )}
            {draft.previewStatus === 'ready' && draft.preview && !draft.preview.src && draft.preview.native && (
              <span className='ems-preview-native' aria-hidden='true'>{draft.preview.native}</span>
            )}
          </div>
        )}

        <label className='ems-field'>
          <span>{this.text('replacement')}</span>
          <input
            type='text'
            value={draft.replacement}
            onChange={event => this.handleReplacement(draft.id, event)}
            maxLength={256}
          />
        </label>

        <fieldset className='ems-effects'>
          <legend>{this.text('effects')}</legend>
          {EFFECT_KEYS.map(key => (
            <label key={key} className='ems-check'>
              <input
                type='checkbox'
                checked={Boolean(draft.effects[key])}
                onChange={event => this.handleEffect(draft.id, key, event)}
              />
              <span>{this.text({
                replace_in_text: 'replaceInText',
                reject_reactions_to_own_posts: 'rejectOwn',
                hide_reactions: 'hideReactions',
                hide_in_picker: 'hideInPicker',
              }[key])}</span>
            </label>
          ))}
        </fieldset>

        {(draft.conflict || draft.error) && (
          <div className='ems-alert' role='alert'>
            <p>{draft.conflict ? this.text('conflict') : this.text('saveError')}</p>
            {draft.conflict && (
              <button type='button' className='ems-button' onClick={() => this.handleReloadRule(draft.id)}>
                {this.text('reloadRule')}
              </button>
            )}
          </div>
        )}

        <div className='ems-rule-foot'>
          <button type='button' className='ems-button' disabled={!dirty || draft.saving} onClick={() => this.handleDiscard(draft.id)}>
            {this.text('discard')}
          </button>
          <button type='button' className='ems-button ems-primary' disabled={!dirty || draft.saving} onClick={() => this.handleSave(draft.id)}>
            {this.text(draft.saving ? 'saving' : 'save')}
          </button>
        </div>
      </article>
    );
  }

  render() {
    const { status, drafts, revealed, query, error } = this.state;
    const filtered = drafts.filter(draft => matchesQuery(draft, query.trim().toLowerCase()));

    if (status === 'loading') {
      return <div className='emoji-mute-settings'><p>{this.text('loading')}</p></div>;
    }

    if (status === 'error') {
      return (
        <div className='emoji-mute-settings'>
          <p>{this.text('loadError')}</p>
          <button type='button' className='ems-button ems-primary' onClick={this.load}>{this.text('retry')}</button>
          {error && error.message && <p className='ems-hint'>{error.message}</p>}
        </div>
      );
    }

    return (
      <div className='emoji-mute-settings'>
        <header className='ems-page-head'>
          <div>
            <h2 className='ems-heading'>{this.text('title')}</h2>
            <p className='ems-subtitle'>{this.text('subtitle')}</p>
            <p className='ems-hint'>{this.text('appliedNote')}</p>
            <p className='ems-hint'>{this.text('count', { count: drafts.length })}</p>
          </div>
          <div className='ems-head-actions'>
            <button type='button' className='ems-button ems-primary' onClick={this.handleReveal} aria-expanded={revealed}>
              {this.text(revealed ? 'hideList' : 'reveal', { count: drafts.length })}
            </button>
          </div>
        </header>

        {!revealed && (
          <p className='ems-collapsed-note'>{this.text('previewHidden')}</p>
        )}

        {revealed && (
          <React.Fragment>
            <label className='ems-field ems-search'>
              <span className='visually-hidden'>{this.text('search')}</span>
              <input
                type='search'
                value={query}
                onChange={this.handleQuery}
                placeholder={this.text('search')}
              />
            </label>

            {drafts.length === 0 && <p>{this.text('empty')}</p>}
            {drafts.length > 0 && filtered.length === 0 && <p>{this.text('empty')}</p>}

            <div className='ems-list'>
              {filtered.map(draft => this.renderRule(draft))}
            </div>
          </React.Fragment>
        )}
      </div>
    );
  }

}

export default injectIntl(EmojiMuteSettings);
