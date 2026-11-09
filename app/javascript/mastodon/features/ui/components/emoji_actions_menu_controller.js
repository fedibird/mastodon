import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { defineMessages, injectIntl } from 'react-intl';
import Overlay from 'react-overlays/Overlay';
import { DropdownMenu } from 'mastodon/components/dropdown_menu';
import { me } from 'mastodon/initial_state';
import { syncEmojiMutes } from 'mastodon/actions/emoji_mutes';
import { currentEmojiMutes } from 'mastodon/features/emoji/emoji_mute_store';
import { notifySavedPersonalEmojiSet } from 'mastodon/features/emoji/emoji_stock_source';
import { openEmojiActions, setEmojiActionsListener, emojiActionsEventName } from 'mastodon/features/emoji/emoji_actions/bus';
import {
  createEmojiMute,
  deleteEmojiMute,
  resolveEmojiReference,
  loadPersonalEmojiSetDocument,
  appendPersonalCategoryItem,
} from 'mastodon/features/emoji/emoji_actions/api';
import {
  createMuteAndSync,
  deleteMuteAndSync,
  retryMuteSync,
} from 'mastodon/features/emoji/emoji_actions/mute_follow_up';
import {
  captureMenuSession,
  isCurrentMenuSession,
} from 'mastodon/features/emoji/emoji_actions/menu_session';
import {
  beginMuteMutation,
  endMuteMutation,
  getMuteMutationFlight,
  isMuteMutationInFlight,
} from 'mastodon/features/emoji/emoji_actions/mutation_flight';
import {
  clearPendingMuteSync,
  getPendingMuteSync,
  muteFromPendingOrStore,
  notePendingMuteSync,
} from 'mastodon/features/emoji/emoji_actions/pending_sync';
import {
  datasetFromReference,
  detailPathForReference,
  findMuteForReference,
  referenceFromDataset,
  referenceFromStockItem,
  referenceLabel,
  referencesEqual,
} from 'mastodon/features/emoji/emoji_actions/reference';

const messages = defineMessages({
  detail: { id: 'emoji_actions.detail', defaultMessage: 'Emoji details' },
  mute: { id: 'emoji_actions.mute', defaultMessage: 'Mute emoji' },
  unmute: { id: 'emoji_actions.unmute', defaultMessage: 'Unmute emoji' },
  manageMute: { id: 'emoji_actions.manage_mute', defaultMessage: 'Change mute settings' },
  muted: { id: 'emoji_actions.muted', defaultMessage: 'Muted' },
  addToCategory: { id: 'emoji_actions.add_to_category', defaultMessage: 'Add to {name}' },
  alreadyInCategory: { id: 'emoji_actions.already_in_category', defaultMessage: 'Already in {name}' },
  noCategories: { id: 'emoji_actions.no_categories', defaultMessage: 'No personal categories yet' },
  loading: { id: 'emoji_actions.loading', defaultMessage: 'Loading…' },
  muteFailed: { id: 'emoji_actions.mute_failed', defaultMessage: 'Could not mute this emoji' },
  unmuteFailed: { id: 'emoji_actions.unmute_failed', defaultMessage: 'Could not unmute this emoji' },
  addFailed: { id: 'emoji_actions.add_failed', defaultMessage: 'Could not add this emoji' },
  addConflict: { id: 'emoji_actions.add_conflict', defaultMessage: 'Personal set changed. Try again.' },
  muteSuccess: { id: 'emoji_actions.mute_success', defaultMessage: 'Muted {label}' },
  unmuteSuccess: { id: 'emoji_actions.unmute_success', defaultMessage: 'Unmuted {label}' },
  addSuccess: { id: 'emoji_actions.add_success', defaultMessage: 'Added to {name}' },
  openSettings: { id: 'emoji_actions.open_mute_settings', defaultMessage: 'Open mute settings' },
  retry: { id: 'emoji_actions.retry', defaultMessage: 'Try again' },
  resolveFailed: { id: 'emoji_actions.resolve_failed', defaultMessage: 'Could not load emoji actions' },
  syncFailed: { id: 'emoji_actions.sync_failed', defaultMessage: 'Saved, but the mute list could not refresh' },
  retrySync: { id: 'emoji_actions.retry_sync', defaultMessage: 'Refresh mute list' },
});

// Pure menu builder for tests. Mutating actions require an explicit resolve
// payload — a missing actions object is not treated as allowed.
export function buildEmojiActionMenuItems({
  intl,
  reference,
  resolved,
  mute,
  categories,
  status,
  notice,
  error,
  syncError,
  pendingSyncRevision,
  busy,
  onMute,
  onUnmute,
  onAddToCategory,
  onRetry,
  onRetrySync,
}) {
  const items = [];

  if (notice) {
    items.push({ text: notice, disabled: true });
  }

  if (status === 'loading') {
    items.push({ text: intl.formatMessage(messages.loading), disabled: true });
    return items;
  }

  const detailPath = detailPathForReference(reference);

  if (detailPath) {
    items.push({
      text: intl.formatMessage(messages.detail),
      to: detailPath,
    });
  }

  if (syncError || pendingSyncRevision) {
    items.push({
      text: intl.formatMessage(messages.syncFailed),
      disabled: true,
    });
    items.push({
      text: intl.formatMessage(messages.retrySync),
      action: onRetrySync,
      disabled: busy,
    });
  }

  const actions = resolved && resolved.actions ? resolved.actions : null;

  if (!actions) {
    if (error) {
      items.push({ text: error.message || intl.formatMessage(messages.resolveFailed), disabled: true });
    }

    items.push({
      text: intl.formatMessage(messages.retry),
      action: onRetry,
    });
    items.push(null, {
      text: intl.formatMessage(messages.openSettings),
      href: '/settings/custom_emojis/mutes',
      target: '_self',
    });
    return items;
  }

  const canAdd = Boolean(actions.add_to_personal_category && actions.add_to_personal_category.allowed);
  const canMute = Boolean(actions.mute && actions.mute.allowed);
  const syncBlocked = Boolean(syncError || pendingSyncRevision);

  if (mute) {
    items.push({
      text: intl.formatMessage(messages.muted),
      disabled: true,
    });
    items.push({
      text: intl.formatMessage(messages.manageMute),
      href: '/settings/custom_emojis/mutes',
      to: null,
      target: '_self',
    });
    items.push({
      text: intl.formatMessage(messages.unmute),
      action: onUnmute,
      dangerous: true,
      disabled: busy || syncBlocked,
    });
  } else if (canMute) {
    items.push({
      text: intl.formatMessage(messages.mute),
      action: onMute,
      dangerous: true,
      disabled: busy || syncBlocked,
    });
  }

  if (canAdd) {
    items.push(null);

    if (!categories || categories.length === 0) {
      items.push({
        text: intl.formatMessage(messages.noCategories),
        disabled: true,
      });
    } else {
      categories.forEach(category => {
        const present = Array.isArray(category.items)
          && category.items.some(item => {
            let itemReference = item;

            if (item && item.reference) {
              itemReference = item.reference;
            } else if (item && item.selection) {
              itemReference = referenceFromStockItem(item);
            }

            return referencesEqual(itemReference, reference);
          });
        const name = category.name || category.id;

        items.push({
          text: intl.formatMessage(present ? messages.alreadyInCategory : messages.addToCategory, { name }),
          action: present ? null : () => onAddToCategory(category),
          disabled: present || busy,
        });
      });
    }
  }

  items.push(null, {
    text: intl.formatMessage(messages.openSettings),
    href: '/settings/custom_emojis/mutes',
    target: '_self',
  });

  return items;
}

const popperConfig = {
  strategy: 'fixed',
};

const isActionsTarget = element => {
  if (!element || element.nodeType !== Node.ELEMENT_NODE) {
    return null;
  }

  return element.closest('[data-emoji-actions="1"]');
};

class EmojiActionsMenuController extends React.PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    intl: PropTypes.object.isRequired,
    signedIn: PropTypes.bool,
    onSyncMutes: PropTypes.func.isRequired,
  };

  state = {
    element: null,
    reference: null,
    resolved: null,
    mute: null,
    categories: null,
    personalRevision: null,
    status: 'idle',
    notice: null,
    error: null,
    syncError: null,
    pendingSyncRevision: null,
    busy: false,
    statusId: null,
    accountId: null,
  };

  componentDidMount() {
    this.unlisten = setEmojiActionsListener(this.handleOpen);
    document.addEventListener(emojiActionsEventName(), this.handleDomEvent);
    document.addEventListener('contextmenu', this.handleContextMenu, true);
    document.addEventListener('keydown', this.handleKeyDown, true);
  }

  componentWillUnmount() {
    if (this.unlisten) {
      this.unlisten();
    }

    document.removeEventListener(emojiActionsEventName(), this.handleDomEvent);
    document.removeEventListener('contextmenu', this.handleContextMenu, true);
    document.removeEventListener('keydown', this.handleKeyDown, true);
  }

  isSignedIn() {
    if (typeof this.props.signedIn === 'boolean') {
      return this.props.signedIn;
    }

    return !!me;
  }

  handleDomEvent = event => {
    if (event && event.detail) {
      this.handleOpen(event.detail);
    }
  };

  handleOpen = detail => {
    if (!detail || !detail.reference || !this.isSignedIn()) {
      return;
    }

    this.loadGeneration = (this.loadGeneration || 0) + 1;
    const generation = this.loadGeneration;
    const element = detail.anchor || null;
    const pending = getPendingMuteSync(detail.reference);
    const flight = getMuteMutationFlight(detail.reference);
    const storeMute = findMuteForReference(currentEmojiMutes(), detail.reference);

    this.setState({
      element,
      reference: detail.reference,
      resolved: null,
      mute: muteFromPendingOrStore(detail.reference, storeMute),
      categories: null,
      personalRevision: null,
      status: 'loading',
      notice: null,
      error: null,
      syncError: pending ? (pending.syncError || new Error('sync pending')) : null,
      pendingSyncRevision: pending ? pending.revision : null,
      // In-flight POST/DELETE survives close; keep busy so Mute cannot re-fire.
      busy: Boolean(flight),
      statusId: detail.status_id || null,
      accountId: detail.account_id || null,
    }, () => {
      this.loadMenuData(generation);

      if (pending && !flight) {
        // Re-open retries sync only — never re-runs the saved POST/DELETE.
        // Defer so the pending revision from this open is visible to retry.
        Promise.resolve().then(() => {
          if (this.loadGeneration === generation) {
            this.handleRetrySync();
          }
        }).catch(() => {});
      }
    });
  };

  handleClose = () => {
    // Keep module-level pending sync; only clear the visible menu chrome.
    this.setState({
      element: null,
      reference: null,
      resolved: null,
      mute: null,
      categories: null,
      personalRevision: null,
      status: 'idle',
      notice: null,
      error: null,
      syncError: null,
      pendingSyncRevision: null,
      busy: false,
      statusId: null,
      accountId: null,
    });
  };

  findTarget = () => this.state.element;

  openFromElement = (element, event) => {
    const reference = referenceFromDataset(element.dataset);

    if (!reference) {
      return;
    }

    if (event) {
      event.preventDefault();
      event.stopPropagation();
    }

    openEmojiActions(reference, {
      anchor: element,
      status_id: element.dataset.emojiStatusId || null,
      account_id: element.dataset.emojiAccountId || null,
      source: element.dataset.emojiSource || 'dataset',
    });
  };

  handleContextMenu = event => {
    if (!this.isSignedIn()) {
      return;
    }

    const target = isActionsTarget(event.target);

    if (!target) {
      return;
    }

    this.openFromElement(target, event);
  };

  handleKeyDown = event => {
    if (!this.isSignedIn()) {
      return;
    }

    const isMenuKey = event.key === 'ContextMenu' || (event.key === 'F10' && event.shiftKey);

    if (!isMenuKey) {
      return;
    }

    const origin = event.target && event.target.nodeType === Node.ELEMENT_NODE
      ? event.target
      : event.target && event.target.parentElement;
    const target = isActionsTarget(origin);

    if (!target) {
      return;
    }

    this.openFromElement(target, event);
  };

  loadMenuData = generation => {
    const { reference, statusId, accountId } = this.state;
    const requestGeneration = generation || this.loadGeneration;

    if (!reference) {
      return;
    }

    const context = {};

    if (statusId) {
      context.status_id = statusId;
    }

    if (accountId) {
      context.account_id = accountId;
    }

    Promise.all([
      resolveEmojiReference(reference, context).catch(error => ({ error })),
      loadPersonalEmojiSetDocument().catch(() => null),
    ]).then(([resolved, personal]) => {
      if (requestGeneration !== this.loadGeneration) {
        return;
      }

      const categories = personal && Array.isArray(personal.categories) ? personal.categories : [];
      const failed = !resolved || resolved.error;
      const nextReference = !failed && resolved.reference ? resolved.reference : reference;
      const pending = getPendingMuteSync(nextReference);
      const storeMute = findMuteForReference(currentEmojiMutes(), nextReference);

      this.setState({
        resolved: failed ? null : resolved,
        reference: nextReference,
        mute: muteFromPendingOrStore(nextReference, storeMute),
        categories,
        personalRevision: personal ? personal.revision : null,
        status: 'ready',
        error: failed ? (resolved && resolved.error) || new Error('Could not load emoji actions') : null,
        syncError: pending ? (pending.syncError || this.state.syncError || new Error('sync pending')) : null,
        pendingSyncRevision: pending ? pending.revision : null,
      });
    }).catch(() => {
      if (requestGeneration !== this.loadGeneration) {
        return;
      }

      this.setState({ status: 'ready', resolved: null, error: new Error('Could not load emoji actions') });
    });
  };

  handleRetry = () => {
    this.loadGeneration = (this.loadGeneration || 0) + 1;
    const generation = this.loadGeneration;

    this.setState({ status: 'loading', error: null, notice: null, resolved: null }, () => {
      this.loadMenuData(generation);
    });
  };

  menuItems() {
    const { intl } = this.props;
    const {
      reference,
      resolved,
      mute,
      categories,
      status,
      notice,
      error,
      syncError,
      pendingSyncRevision,
      busy,
    } = this.state;

    return buildEmojiActionMenuItems({
      intl,
      reference,
      resolved,
      mute,
      categories,
      status,
      notice,
      error,
      syncError,
      pendingSyncRevision,
      busy,
      onMute: this.handleMute,
      onUnmute: this.handleUnmute,
      onAddToCategory: this.handleAddToCategory,
      onRetry: this.handleRetry,
      onRetrySync: this.handleRetrySync,
    });
  }

  handleMute = () => {
    const { intl, onSyncMutes } = this.props;
    const { reference } = this.state;

    if (!reference || this.state.busy || this.state.pendingSyncRevision || isMuteMutationInFlight(reference) || getPendingMuteSync(reference)) {
      return;
    }

    if (!beginMuteMutation(reference, 'mute')) {
      return;
    }

    const session = captureMenuSession(this.loadGeneration, reference);

    this.setState({ busy: true, error: null, notice: null, syncError: null });

    createMuteAndSync({
      createMute: createEmojiMute,
      syncMutes: onSyncMutes,
      reference,
    }).then(result => {
      const savedMute = result.response.emoji_mute
        || findMuteForReference(currentEmojiMutes(), reference);

      if (result.synced) {
        clearPendingMuteSync(reference);
      } else {
        notePendingMuteSync({
          reference,
          revision: result.response.revision,
          mute: savedMute,
          operation: 'mute',
          syncError: result.syncError,
        });
      }

      endMuteMutation(reference);

      if (!isCurrentMenuSession(session, { loadGeneration: this.loadGeneration, reference: this.state.reference })) {
        return;
      }

      if (result.synced) {
        this.setState({
          busy: false,
          mute: findMuteForReference(currentEmojiMutes(), reference) || savedMute,
          notice: intl.formatMessage(messages.muteSuccess, { label: referenceLabel(reference) }),
          syncError: null,
          pendingSyncRevision: null,
        });
        return;
      }

      this.setState({
        busy: false,
        mute: savedMute,
        notice: intl.formatMessage(messages.muteSuccess, { label: referenceLabel(reference) }),
        syncError: result.syncError,
        pendingSyncRevision: result.response.revision || null,
        error: null,
      });
    }).catch(error => {
      endMuteMutation(reference);

      if (!isCurrentMenuSession(session, { loadGeneration: this.loadGeneration, reference: this.state.reference })) {
        return;
      }

      this.setState({
        busy: false,
        error,
        notice: null,
        syncError: null,
        pendingSyncRevision: null,
      });
    });
  };

  handleUnmute = () => {
    const { intl, onSyncMutes } = this.props;
    const { mute, reference } = this.state;

    if (!mute || this.state.busy || this.state.pendingSyncRevision || isMuteMutationInFlight(reference) || getPendingMuteSync(reference)) {
      return;
    }

    if (!beginMuteMutation(reference, 'unmute')) {
      return;
    }

    const session = captureMenuSession(this.loadGeneration, reference);

    this.setState({ busy: true, error: null, notice: null, syncError: null });

    deleteMuteAndSync({
      deleteMute: deleteEmojiMute,
      syncMutes: onSyncMutes,
      mute,
    }).then(result => {
      if (result.synced) {
        clearPendingMuteSync(reference);
      } else {
        notePendingMuteSync({
          reference,
          revision: result.response.revision,
          mute: null,
          operation: 'unmute',
          syncError: result.syncError,
        });
      }

      endMuteMutation(reference);

      if (!isCurrentMenuSession(session, { loadGeneration: this.loadGeneration, reference: this.state.reference })) {
        return;
      }

      if (result.synced) {
        this.setState({
          busy: false,
          mute: null,
          notice: intl.formatMessage(messages.unmuteSuccess, { label: referenceLabel(reference) }),
          syncError: null,
          pendingSyncRevision: null,
        });
        return;
      }

      this.setState({
        busy: false,
        mute: null,
        notice: intl.formatMessage(messages.unmuteSuccess, { label: referenceLabel(reference) }),
        syncError: result.syncError,
        pendingSyncRevision: result.response.revision || null,
        error: null,
      });
    }).catch(error => {
      endMuteMutation(reference);

      if (!isCurrentMenuSession(session, { loadGeneration: this.loadGeneration, reference: this.state.reference })) {
        return;
      }

      this.setState({
        busy: false,
        error,
        notice: null,
        syncError: null,
        pendingSyncRevision: null,
      });
    });
  };

  handleRetrySync = () => {
    const { onSyncMutes } = this.props;
    const { reference } = this.state;
    const pending = getPendingMuteSync(reference) || {
      revision: this.state.pendingSyncRevision,
      reference,
    };

    if (this.state.busy || !pending.revision) {
      return;
    }

    const session = captureMenuSession(this.loadGeneration, reference);

    this.setState({ busy: true, syncError: null });

    retryMuteSync({
      syncMutes: onSyncMutes,
      revision: pending.revision,
    }).then(() => {
      clearPendingMuteSync(reference);

      if (!isCurrentMenuSession(session, { loadGeneration: this.loadGeneration, reference: this.state.reference })) {
        return;
      }

      this.setState({
        busy: false,
        syncError: null,
        pendingSyncRevision: null,
        mute: findMuteForReference(currentEmojiMutes(), reference),
      });
    }).catch(syncError => {
      notePendingMuteSync({
        reference,
        revision: pending.revision,
        mute: pending.mute,
        operation: pending.operation || (this.state.mute ? 'mute' : 'unmute'),
        syncError,
      });

      if (!isCurrentMenuSession(session, { loadGeneration: this.loadGeneration, reference: this.state.reference })) {
        return;
      }

      this.setState({
        busy: false,
        syncError,
        pendingSyncRevision: pending.revision || null,
      });
    });
  };

  handleAddToCategory = category => {
    const { intl } = this.props;
    const { reference, personalRevision } = this.state;

    if (!category || !reference || this.state.busy) {
      return;
    }

    const session = captureMenuSession(this.loadGeneration, reference);

    this.setState({ busy: true, error: null, notice: null });

    appendPersonalCategoryItem(category.id, reference, personalRevision).then(document => {
      if (document && document.operation && document.operation.added) {
        notifySavedPersonalEmojiSet(document);
      }

      if (!isCurrentMenuSession(session, { loadGeneration: this.loadGeneration, reference: this.state.reference })) {
        return;
      }

      this.setState({
        busy: false,
        personalRevision: document.revision,
        categories: document.categories,
        notice: intl.formatMessage(
          document.operation && document.operation.added === false ? messages.alreadyInCategory : messages.addSuccess,
          { name: category.name || category.id },
        ),
      });
    }).catch(error => {
      if (!isCurrentMenuSession(session, { loadGeneration: this.loadGeneration, reference: this.state.reference })) {
        return;
      }

      const message = error && error.code === 'conflict'
        ? intl.formatMessage(messages.addConflict)
        : intl.formatMessage(messages.addFailed);

      this.setState({
        busy: false,
        error,
        notice: message,
      });
    });
  };

  handleItemClick = event => {
    if (event.type === 'click' && event.button !== 0) {
      return;
    }

    if (event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) {
      return;
    }

    const index = Number(event.currentTarget.getAttribute('data-index'));
    const item = this.menuItems()[index];

    event.preventDefault();
    event.stopPropagation();

    if (!item || item.disabled) {
      return;
    }

    if (typeof item.action === 'function') {
      item.action(event);
      return;
    }

    this.handleClose();

    if (item.to && this.context.router) {
      this.context.router.history.push(item.to);
      return;
    }

    if (item.href) {
      window.location.assign(item.href);
    }
  };

  render() {
    if (!this.state.element || !this.state.reference) {
      return null;
    }

    return (
      <Overlay show offset={[5, 5]} placement='bottom' flip target={this.findTarget} popperConfig={popperConfig}>
        {({ props, arrowProps, placement }) => (
          <div {...props}>
            <div className={`dropdown-animation dropdown-menu ${placement}`}>
              <div className={`dropdown-menu__arrow ${placement}`} {...arrowProps} />
              <DropdownMenu
                items={this.menuItems()}
                onClose={this.handleClose}
                onItemClick={this.handleItemClick}
              />
            </div>
          </div>
        )}
      </Overlay>
    );
  }

}

const mapDispatchToProps = dispatch => ({
  onSyncMutes(options) {
    return dispatch(syncEmojiMutes(options));
  },
});

export { datasetFromReference, openEmojiActions, EmojiActionsMenuController, isCurrentMenuSession, captureMenuSession };
export default injectIntl(connect(null, mapDispatchToProps)(EmojiActionsMenuController));
