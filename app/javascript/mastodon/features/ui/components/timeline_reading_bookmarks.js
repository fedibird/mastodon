import React from 'react';
import PropTypes from 'prop-types';
import { defineMessages, injectIntl } from 'react-intl';

import {
  bookmarkLimitReached,
  bookmarkPresentation,
  bookmarksForScope,
} from '../../../reading_bookmarks/place';

const messages = defineMessages({
  title: { id: 'timeline.reading_bookmarks', defaultMessage: 'Reading bookmarks' },
  close: { id: 'timeline.reading_bookmarks_close', defaultMessage: 'Close reading bookmarks' },
  name: { id: 'timeline.reading_bookmarks_name', defaultMessage: 'Bookmark name' },
  save: { id: 'timeline.reading_bookmarks_save', defaultMessage: 'Save this position' },
  saving: { id: 'timeline.reading_bookmarks_saving', defaultMessage: 'Saving…' },
  hint: { id: 'timeline.reading_bookmarks_hint', defaultMessage: 'Saves the post visible in history at the moment you save. The live column, a window, and search text are not saved.' },
  scopeColumn: { id: 'timeline.reading_bookmarks_scope_column', defaultMessage: 'This timeline' },
  scopeAll: { id: 'timeline.reading_bookmarks_scope_all', defaultMessage: 'All timelines' },
  empty: { id: 'timeline.reading_bookmarks_empty', defaultMessage: 'No bookmarks for this timeline yet.' },
  emptyAll: { id: 'timeline.reading_bookmarks_empty_all', defaultMessage: 'No bookmarks yet.' },
  list: { id: 'timeline.reading_bookmarks_list', defaultMessage: 'Saved positions' },
  return: { id: 'timeline.reading_bookmarks_return', defaultMessage: 'Return' },
  rename: { id: 'timeline.reading_bookmarks_rename', defaultMessage: 'Rename' },
  renameSave: { id: 'timeline.reading_bookmarks_rename_save', defaultMessage: 'Save name' },
  remove: { id: 'timeline.reading_bookmarks_remove', defaultMessage: 'Delete' },
  removeConfirm: { id: 'timeline.reading_bookmarks_remove_confirm', defaultMessage: 'Delete this bookmark?' },
  removeYes: { id: 'timeline.reading_bookmarks_remove_yes', defaultMessage: 'Delete bookmark' },
  cancel: { id: 'timeline.reading_bookmarks_cancel', defaultMessage: 'Cancel' },
  limit: { id: 'timeline.reading_bookmarks_limit', defaultMessage: '50 bookmarks is the limit. Delete one before saving another.' },
  duplicate: { id: 'timeline.reading_bookmarks_duplicate', defaultMessage: 'You already have a bookmark with that name.' },
  invalidName: { id: 'timeline.reading_bookmarks_invalid_name', defaultMessage: 'Use 1 to 100 characters, without a blank name.' },
  network: { id: 'timeline.reading_bookmarks_network', defaultMessage: 'The request failed.' },
  conflict: { id: 'timeline.reading_bookmarks_conflict', defaultMessage: 'That bookmark changed somewhere else. The list was reloaded.' },
  saved: { id: 'timeline.reading_bookmarks_saved', defaultMessage: 'Saved “{name}”.' },
  renamed: { id: 'timeline.reading_bookmarks_renamed', defaultMessage: 'Renamed to “{name}”.' },
  deleted: { id: 'timeline.reading_bookmarks_deleted', defaultMessage: 'Deleted “{name}”.' },
  historyClosed: { id: 'timeline.reading_bookmarks_history_closed', defaultMessage: 'Open history first. A bookmark saves the history pane, not the live column.' },
  noAnchor: { id: 'timeline.reading_bookmarks_no_anchor', defaultMessage: 'History is not showing a post to save.' },
  unavailable: { id: 'timeline.reading_bookmarks_unavailable', defaultMessage: 'Could not return to that post. History was put back.' },
  exact: { id: 'timeline.reading_bookmarks_exact', defaultMessage: 'Returned to the saved post.' },
  nearby: { id: 'timeline.reading_bookmarks_nearby', defaultMessage: 'Returned near the saved post. The exact row was not the one opened.' },
  uncertain: { id: 'timeline.reading_bookmarks_uncertain', defaultMessage: 'That post is outside the retained range, or its place in this timeline is unknown. History was not moved.' },
  userScroll: { id: 'timeline.reading_bookmarks_user_scroll', defaultMessage: 'Scrolling kept the position you moved to.' },
  stale: { id: 'timeline.reading_bookmarks_stale', defaultMessage: 'Ignored an outdated return.' },
  protected: { id: 'timeline.reading_bookmarks_protected', defaultMessage: 'Automatic resume is in progress. The bookmark was not applied.' },
  different: { id: 'timeline.reading_bookmarks_different', defaultMessage: 'This bookmark belongs to {where}. Open that timeline to return to it. This column was not moved.' },
  another: { id: 'timeline.reading_bookmarks_another', defaultMessage: 'another timeline' },
  missing: { id: 'timeline.reading_bookmarks_missing', defaultMessage: 'That timeline is gone or no longer open to you. Its name is hidden.' },
  anchorUnchecked: { id: 'timeline.reading_bookmarks_anchor_unchecked', defaultMessage: 'Checked again when you return' },
  anchorVisible: { id: 'timeline.reading_bookmarks_anchor_visible', defaultMessage: 'Post was visible when saved' },
  anchorMissing: { id: 'timeline.reading_bookmarks_anchor_missing', defaultMessage: 'Saved post was not available' },
  retention: { id: 'timeline.reading_bookmarks_retention', defaultMessage: 'Only the latest 2000 posts are kept. Outside that range the result is uncertain, not a proof the post was absent.' },
  sourceHome: { id: 'timeline.reading_bookmarks_source_home', defaultMessage: 'Home' },
  sourceLimited: { id: 'timeline.reading_bookmarks_source_limited', defaultMessage: 'Limited' },
  sourceList: { id: 'timeline.reading_bookmarks_source_list', defaultMessage: 'List' },
  sourceHashtag: { id: 'timeline.reading_bookmarks_source_hashtag', defaultMessage: 'Hashtag' },
  sourcePublic: { id: 'timeline.reading_bookmarks_source_public', defaultMessage: 'Public' },
  sourceDomain: { id: 'timeline.reading_bookmarks_source_domain', defaultMessage: 'Domain' },
  sourceGroup: { id: 'timeline.reading_bookmarks_source_group', defaultMessage: 'Group' },
  sourcePersonal: { id: 'timeline.reading_bookmarks_source_personal', defaultMessage: 'Personal' },
  splitUnavailable: { id: 'timeline.reading_bookmarks_split_unavailable', defaultMessage: 'History is unavailable while another column is split.' },
});

const SOURCE_MESSAGE = {
  home: 'sourceHome',
  limited: 'sourceLimited',
  list: 'sourceList',
  hashtag: 'sourceHashtag',
  public: 'sourcePublic',
  domain: 'sourceDomain',
  group: 'sourceGroup',
  personal: 'sourcePersonal',
};

const NOTICE = {
  limit: 'limit',
  duplicate_name: 'duplicate',
  invalid_name: 'invalidName',
  network: 'network',
  conflict: 'conflict',
  history_closed: 'historyClosed',
  no_reading_anchor: 'noAnchor',
  unavailable: 'unavailable',
  missing: 'missing',
  not_accessible: 'missing',
  exact: 'exact',
  nearby: 'nearby',
  uncertain: 'uncertain',
  user_scroll: 'userScroll',
  stale: 'stale',
  protected: 'protected',
  resume_protected: 'protected',
  split_unavailable: 'splitUnavailable',
  not_found: 'unavailable',
  not_in_source: 'unavailable',
  not_visible: 'unavailable',
  filtered: 'unavailable',
  not_loaded: 'unavailable',
};

const savedAt = (value) => {
  const time = Date.parse(value || '');

  if (Number.isNaN(time)) {
    return '';
  }

  try {
    return new Intl.DateTimeFormat(undefined, { dateStyle: 'medium', timeStyle: 'short' }).format(time);
  } catch (error) {
    return new Date(time).toISOString().slice(0, 16);
  }
};

export const readingBookmarkNotice = (intl, notice) => {
  if (!notice) {
    return null;
  }

  if (notice.type === 'saved') {
    return intl.formatMessage(messages.saved, { name: notice.name });
  }

  if (notice.type === 'renamed') {
    return intl.formatMessage(messages.renamed, { name: notice.name });
  }

  if (notice.type === 'deleted') {
    return intl.formatMessage(messages.deleted, { name: notice.name });
  }

  if (notice.type === 'different_source') {
    return intl.formatMessage(messages.different, { where: notice.where || intl.formatMessage(messages.another) });
  }

  const key = NOTICE[notice.type] || NOTICE[notice.reason] || 'network';

  return intl.formatMessage(messages[key]);
};

const sourceTitle = (intl, view) => {
  const generic = SOURCE_MESSAGE[view.source] ? intl.formatMessage(messages[SOURCE_MESSAGE[view.source]]) : intl.formatMessage(messages.another);

  if (view.sourceLabel) {
    return `${generic}: ${view.sourceLabel}`;
  }

  return generic;
};

class TimelineReadingBookmarksPanel extends React.PureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    panelId: PropTypes.string.isRequired,
    contract: PropTypes.object,
    onClose: PropTypes.func.isRequired,
    onCapture: PropTypes.func.isRequired,
    onList: PropTypes.func.isRequired,
    onCreate: PropTypes.func.isRequired,
    onRename: PropTypes.func.isRequired,
    onDelete: PropTypes.func.isRequired,
    onRestore: PropTypes.func.isRequired,
  };

  state = {
    bookmarks: [],
    loaded: false,
    scope: 'column',
    name: '',
    busy: false,
    notice: null,
    editingId: null,
    draft: '',
    confirmDeleteId: null,
  };

  listRequest = 0;

  actionRequest = 0;

  componentDidMount () {
    if (this.nameNode) {
      this.nameNode.focus();
    }

    this.refresh();
  }

  componentWillUnmount () {
    this.unmounted = true;
    this.listRequest += 1;
    this.actionRequest += 1;
  }

  setNameNode = (node) => {
    this.nameNode = node;
  };

  refresh = () => {
    const request = ++this.listRequest;

    return Promise.resolve(this.props.onList()).then(rows => {
      if (this.unmounted || request !== this.listRequest) {
        return;
      }

      this.setState({ bookmarks: Array.isArray(rows) ? rows : [], loaded: true });
    }).catch(() => {
      if (this.unmounted || request !== this.listRequest) {
        return;
      }

      this.setState({ loaded: true, notice: { type: 'network' } });
    });
  };

  isImeEnter = (event) => {
    const native = event.nativeEvent || {};

    return this.composing || event.keyCode === 229 || event.which === 229 || native.isComposing || native.keyCode === 229;
  };

  handleComposition = (event) => {
    const starting = event.type === 'compositionstart';

    this.composing = starting;
    this.imeJustEnded = !starting;
  };

  handleKeyDown = (event) => {
    if (event.key === 'Escape') {
      event.preventDefault();
      event.stopPropagation();
      this.props.onClose();
      return;
    }

    if (event.key === 'Enter' && (this.isImeEnter(event) || this.imeJustEnded)) {
      event.preventDefault();
      event.stopPropagation();
      this.imeJustEnded = false;
    }
  };

  handleName = (event) => {
    this.setState({ name: event.target.value, notice: null });
  };

  showColumnScope = () => {
    this.setState({ scope: 'column', notice: null });
  };

  showAllScope = () => {
    this.setState({ scope: 'all', notice: null });
  };

  bookmarkFrom = (event) => this.state.bookmarks.find(item => item.id === event.currentTarget.getAttribute('data-bookmark-id'));

  handleRestoreClick = (event) => {
    const bookmark = this.bookmarkFrom(event);

    if (bookmark) {
      this.handleRestore(bookmark);
    }
  };

  handleRenameClick = (event) => {
    const bookmark = this.bookmarkFrom(event);

    if (bookmark) {
      this.startRename(bookmark);
    }
  };

  handleRenameSaveClick = (event) => {
    const bookmark = this.bookmarkFrom(event);

    if (bookmark) {
      this.saveRename(bookmark);
    }
  };

  handleRenameCancel = () => {
    this.setState({ editingId: null, draft: '' });
  };

  handleDeleteClick = (event) => {
    const bookmark = this.bookmarkFrom(event);

    if (bookmark) {
      this.askDelete(bookmark);
    }
  };

  handleDeleteConfirm = (event) => {
    const bookmark = this.bookmarkFrom(event);

    if (bookmark) {
      this.saveDelete(bookmark);
    }
  };

  handleDeleteCancel = () => {
    this.setState({ confirmDeleteId: null });
  };

  applyFailure = (error, action) => {
    if (this.unmounted || action !== this.actionRequest) {
      return;
    }

    const reason = error && error.reason ? error.reason : 'network';

    if (reason === 'conflict' || reason === 'limit') {
      this.refresh();
    }

    this.setState({ busy: false, notice: { type: reason } });
  };

  handleSave = (event) => {
    event.preventDefault();

    if (this.state.busy || this.composing || this.imeJustEnded) {
      this.imeJustEnded = false;
      return;
    }

    if (bookmarkLimitReached(this.state.bookmarks)) {
      this.setState({ notice: { type: 'limit' } });
      return;
    }

    const captured = this.props.onCapture();

    if (!captured || !captured.ok) {
      this.setState({ notice: { type: captured && captured.reason ? captured.reason : 'no_reading_anchor' } });
      return;
    }

    const action = ++this.actionRequest;

    this.setState({ busy: true, notice: null });
    Promise.resolve(this.props.onCreate({ name: this.state.name, anchor: captured.anchor })).then(row => {
      if (this.unmounted || action !== this.actionRequest) {
        return;
      }

      if (!row || !row.id) {
        this.setState({ busy: false, notice: { type: 'network' } });
        return;
      }

      this.setState(state => ({
        busy: false,
        name: '',
        notice: { type: 'saved', name: row.name },
        bookmarks: [row].concat(state.bookmarks.filter(item => item.id !== row.id)),
      }));
    }).catch(error => this.applyFailure(error, action));
  };

  startRename = (bookmark) => {
    this.setState({ editingId: bookmark.id, draft: bookmark.name, confirmDeleteId: null, notice: null });
  };

  handleDraft = (event) => {
    this.setState({ draft: event.target.value });
  };

  saveRename = (bookmark) => {
    if (this.state.busy || this.composing || this.imeJustEnded) {
      this.imeJustEnded = false;
      return;
    }

    const action = ++this.actionRequest;
    const name = this.state.draft;

    this.setState({ busy: true, notice: null });
    Promise.resolve(this.props.onRename(bookmark, name)).then(row => {
      if (this.unmounted || action !== this.actionRequest) {
        return;
      }

      if (!row || !row.id) {
        this.setState({ busy: false, notice: { type: 'network' } });
        return;
      }

      this.setState(state => ({
        busy: false,
        editingId: null,
        draft: '',
        notice: { type: 'renamed', name: row.name },
        bookmarks: state.bookmarks.map(item => item.id === row.id ? row : item),
      }));
    }).catch(error => this.applyFailure(error, action));
  };

  askDelete = (bookmark) => {
    this.setState({ confirmDeleteId: bookmark.id, editingId: null, notice: null });
  };

  saveDelete = (bookmark) => {
    if (this.state.busy) {
      return;
    }

    const action = ++this.actionRequest;

    this.setState({ busy: true, notice: null });
    Promise.resolve(this.props.onDelete(bookmark)).then(() => {
      if (this.unmounted || action !== this.actionRequest) {
        return;
      }

      this.setState(state => ({
        busy: false,
        confirmDeleteId: null,
        notice: { type: 'deleted', name: bookmark.name },
        bookmarks: state.bookmarks.filter(item => item.id !== bookmark.id),
      }));
    }).catch(error => this.applyFailure(error, action));
  };

  handleRestore = (bookmark) => {
    if (this.state.busy) {
      return;
    }

    const action = ++this.actionRequest;
    const view = bookmarkPresentation(bookmark);

    this.setState({ busy: true, notice: null });
    Promise.resolve(this.props.onRestore(bookmark)).then(result => {
      if (this.unmounted || action !== this.actionRequest) {
        return;
      }

      const reason = result && result.reason;
      let place = result && result.place ? result.place : (reason || 'unavailable');

      if (reason === 'network' && result && result.rollback) {
        place = 'unavailable';
      } else if (reason === 'missing' || reason === 'not_accessible' || reason === 'network' || reason === 'uncertain' || reason === 'resume_protected') {
        place = reason;
      }

      const where = view.sourceState === 'available' ? sourceTitle(this.props.intl, view) : null;

      this.setState({
        busy: false,
        notice: {
          type: place,
          reason: result && result.reason,
          where: place === 'different_source' ? (where || this.props.intl.formatMessage(messages.another)) : null,
        },
      });
    }).catch(() => this.applyFailure({ reason: 'network' }, action));
  };

  renderRow = (bookmark) => {
    const { intl, panelId } = this.props;
    const view = bookmarkPresentation(bookmark);
    const editing = this.state.editingId === bookmark.id;
    const confirming = this.state.confirmDeleteId === bookmark.id;
    const when = savedAt(view.updatedAt);
    let anchor = intl.formatMessage(messages.anchorUnchecked);

    if (view.anchorState === 'visible') {
      anchor = intl.formatMessage(messages.anchorVisible);
    } else if (view.anchorState === 'not_found') {
      anchor = intl.formatMessage(messages.anchorMissing);
    }

    const retained = view.limitations.some(item => item.indexOf('retention_') === 0);

    return (
      <li key={bookmark.id} className='timeline-bookmarks__item'>
        {editing ? (
          <div className='timeline-bookmarks__row'>
            <label htmlFor={`${panelId}-rename-${bookmark.id}`}>{intl.formatMessage(messages.rename)}</label>
            <input
              id={`${panelId}-rename-${bookmark.id}`}
              className='setting-text'
              value={this.state.draft}
              maxLength={100}
              onChange={this.handleDraft}
              onCompositionStart={this.handleComposition}
              onCompositionEnd={this.handleComposition}
            />
            <div className='timeline-bookmarks__actions'>
              <button type='button' className='timeline-bookmarks__go' data-bookmark-id={bookmark.id} onClick={this.handleRenameSaveClick}>
                {intl.formatMessage(messages.renameSave)}
              </button>
              <button type='button' className='timeline-bookmarks__close' onClick={this.handleRenameCancel}>
                {intl.formatMessage(messages.cancel)}
              </button>
            </div>
          </div>
        ) : (
          <div className='timeline-bookmarks__row'>
            <span className='timeline-bookmarks__name'>{view.name}</span>
            <span className='timeline-bookmarks__meta'>{sourceTitle(intl, view)}{when ? ` · ${when}` : ''}</span>
            <span className='timeline-bookmarks__meta'>
              {view.sourceState === 'available' ? anchor : intl.formatMessage(messages.missing)}
              {retained ? ` ${intl.formatMessage(messages.retention)}` : ''}
            </span>
          </div>
        )}
        {confirming && (
          <div className='timeline-bookmarks__actions'>
            <span>{intl.formatMessage(messages.removeConfirm)}</span>
            <button type='button' className='timeline-bookmarks__go' data-bookmark-id={bookmark.id} onClick={this.handleDeleteConfirm}>
              {intl.formatMessage(messages.removeYes)}
            </button>
            <button type='button' className='timeline-bookmarks__close' onClick={this.handleDeleteCancel}>
              {intl.formatMessage(messages.cancel)}
            </button>
          </div>
        )}
        {!editing && !confirming && (
          <div className='timeline-bookmarks__actions'>
            <button type='button' className='timeline-bookmarks__go' data-bookmark-id={bookmark.id} onClick={this.handleRestoreClick}>
              {intl.formatMessage(messages.return)}
            </button>
            <button type='button' className='timeline-bookmarks__close' data-bookmark-id={bookmark.id} onClick={this.handleRenameClick}>
              {intl.formatMessage(messages.rename)}
            </button>
            <button type='button' className='timeline-bookmarks__close' data-bookmark-id={bookmark.id} onClick={this.handleDeleteClick}>
              {intl.formatMessage(messages.remove)}
            </button>
          </div>
        )}
      </li>
    );
  };

  render () {
    const { intl, panelId } = this.props;
    const rows = bookmarksForScope(this.state.bookmarks, this.props.contract, this.state.scope);
    const limited = bookmarkLimitReached(this.state.bookmarks);
    const feedback = readingBookmarkNotice(intl, this.state.notice);
    const empty = this.state.scope === 'all' ? messages.emptyAll : messages.empty;

    return (
      <div
        id={panelId}
        className='timeline-bookmarks'
        role='dialog'
        aria-label={intl.formatMessage(messages.title)}
        aria-busy={this.state.busy ? 'true' : 'false'}
        onKeyDown={this.handleKeyDown}
      >
        <form onSubmit={this.handleSave}>
          <p className='timeline-bookmarks__note'>{intl.formatMessage(messages.hint)}</p>
          <div className='timeline-bookmarks__row'>
            <label htmlFor={`${panelId}-name`}>{intl.formatMessage(messages.name)}</label>
            <input
              id={`${panelId}-name`}
              className='setting-text'
              ref={this.setNameNode}
              value={this.state.name}
              maxLength={100}
              onChange={this.handleName}
              onCompositionStart={this.handleComposition}
              onCompositionEnd={this.handleComposition}
            />
          </div>
          <div className='timeline-bookmarks__actions'>
            <button type='submit' className='timeline-bookmarks__go' disabled={this.state.busy || limited}>
              {intl.formatMessage(this.state.busy ? messages.saving : messages.save)}
            </button>
            <button type='button' className='timeline-bookmarks__close' onClick={this.props.onClose}>
              {intl.formatMessage(messages.close)}
            </button>
          </div>
        </form>
        {feedback && <p className='timeline-bookmarks__result' role='status' aria-live='polite'>{feedback}</p>}
        <div className='timeline-bookmarks__actions' role='group' aria-label={intl.formatMessage(messages.list)}>
          <button type='button' className='timeline-bookmarks__close' aria-pressed={this.state.scope === 'column' ? 'true' : 'false'} onClick={this.showColumnScope}>
            {intl.formatMessage(messages.scopeColumn)}
          </button>
          <button type='button' className='timeline-bookmarks__close' aria-pressed={this.state.scope === 'all' ? 'true' : 'false'} onClick={this.showAllScope}>
            {intl.formatMessage(messages.scopeAll)}
          </button>
        </div>
        {limited && <p className='timeline-bookmarks__note'>{intl.formatMessage(messages.limit)}</p>}
        {this.state.loaded && rows.length === 0 && <p className='timeline-bookmarks__note'>{intl.formatMessage(empty)}</p>}
        <ul className='timeline-bookmarks__list' aria-label={intl.formatMessage(messages.list)}>
          {rows.map(this.renderRow)}
        </ul>
      </div>
    );
  }

}

export default injectIntl(TimelineReadingBookmarksPanel);
