import React from 'react';
import { createPortal } from 'react-dom';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { defineMessages, injectIntl } from 'react-intl';
import Overlay from 'react-overlays/Overlay';
import { DropdownMenu } from 'mastodon/components/dropdown_menu';
import { emojiActionsDisablePersonalRemove, emojiMuteDisableActions, emojiPickerDisableActions, emojiPickerDisablePersonal, emojiPreviewClickAction, me } from 'mastodon/initial_state';
import { syncEmojiMutes } from 'mastodon/actions/emoji_mutes';
import { addEmojiReaction, removeEmojiReaction } from 'mastodon/actions/interactions';
import { currentEmojiMutes } from 'mastodon/features/emoji/emoji_mute_store';
import { notifySavedPersonalEmojiSet, personalEmojiDocumentIsCurrent, personalEmojiStockGeneration } from 'mastodon/features/emoji/emoji_stock_source';
import { closeModal, openModal } from 'mastodon/actions/modal';
import { enableEmojiMuteLoading } from 'mastodon/actions/emoji_mutes';
import { currentEmojiMuteBoot, emojiMuteConfirmation } from 'mastodon/features/emoji/emoji_mute_availability';
import { closeDropdownMenu } from 'mastodon/actions/dropdown_menu';
import {
  openEmojiActions,
  setEmojiActionsListener,
  setEmojiActionsSlideListeners,
  emojiActionsEventName,
  normalizeReactionContext,
  peekEmojiActionsSlideGesture,
} from 'mastodon/features/emoji/emoji_actions/bus';
import {
  createEmojiMute,
  deleteEmojiMute,
  resolveEmojiReference,
  loadPersonalEmojiSetDocument,
  appendPersonalCategoryItem,
  removePersonalCategoryItem,
} from 'mastodon/features/emoji/emoji_actions/api';
import {
  clearEmojiActionsSlideHighlight,
  hitTestEmojiActionsMenuItem,
  setEmojiActionsSlideHighlight,
} from 'mastodon/features/emoji/emoji_actions/slide_select';
import { navigateAfterPickerClose as scheduleNavigateAfterPickerClose } from 'mastodon/features/emoji/emoji_actions/navigate_after_picker_close';
import { LONG_PRESS_CLICK_SUPPRESS_MS } from 'mastodon/features/emoji/long_press';
import {
  createMuteAndSync,
  deleteMuteAndSync,
  retryMuteSync,
} from 'mastodon/features/emoji/emoji_actions/mute_follow_up';
import {
  captureMenuSession,
  canApplyMutationToOpenMenu,
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
  copyTextForReference,
  datasetFromReference,
  detailPathForReference,
  findMuteForReference,
  referenceFromDataset,
  referenceFromStockItem,
  referenceLabel,
  referencesEqual,
} from 'mastodon/features/emoji/emoji_actions/reference';
import { getEmojiActionsOverlayRoot } from 'mastodon/features/emoji/emoji_actions/overlay_root';
import { copyText } from 'mastodon/utils/clipboard';
import Icon from 'mastodon/components/icon';
import classNames from 'classnames';
import { buildEmojiActionsPreview, positionEmojiActionsPreview } from 'mastodon/features/emoji/emoji_actions/preview';

const messages = defineMessages({
  detail: { id: 'emoji_actions.detail', defaultMessage: 'Emoji details' },
  copy: { id: 'emoji_actions.copy', defaultMessage: 'Copy emoji' },
  copySuccess: { id: 'emoji_actions.copy_success', defaultMessage: 'Copied' },
  copyFailed: { id: 'emoji_actions.copy_failed', defaultMessage: 'Could not copy' },
  reactSame: { id: 'emoji_actions.react_same', defaultMessage: 'React with this emoji' },
  reactRemove: { id: 'emoji_actions.react_remove', defaultMessage: 'Remove this reaction' },
  mute: { id: 'emoji_actions.mute', defaultMessage: 'Mute emoji' },
  unmute: { id: 'emoji_actions.unmute', defaultMessage: 'Unmute emoji' },
  manageMute: { id: 'emoji_actions.manage_mute', defaultMessage: 'Change mute settings' },
  muted: { id: 'emoji_actions.muted', defaultMessage: 'Muted' },
  addToCategory: { id: 'emoji_actions.add_to_category', defaultMessage: 'Add to {name}' },
  alreadyInCategory: { id: 'emoji_actions.already_in_category', defaultMessage: 'Already in {name}' },
  removeFromCategory: { id: 'emoji_actions.remove_from_category', defaultMessage: 'Remove from {name}' },
  noCategories: { id: 'emoji_actions.no_categories', defaultMessage: 'No personal categories yet' },
  loading: { id: 'emoji_actions.loading', defaultMessage: 'Loading…' },
  muteFailed: { id: 'emoji_actions.mute_failed', defaultMessage: 'Could not mute this emoji' },
  unmuteFailed: { id: 'emoji_actions.unmute_failed', defaultMessage: 'Could not unmute this emoji' },
  addFailed: { id: 'emoji_actions.add_failed', defaultMessage: 'Could not add this emoji' },
  addConflict: { id: 'emoji_actions.add_conflict', defaultMessage: 'Personal set changed. Try again.' },
  removeFailed: { id: 'emoji_actions.remove_failed', defaultMessage: 'Could not remove this emoji' },
  removeConflict: { id: 'emoji_actions.remove_conflict', defaultMessage: 'Personal set changed. Try again.' },
  muteSuccess: { id: 'emoji_actions.mute_success', defaultMessage: 'Muted {label}' },
  unmuteSuccess: { id: 'emoji_actions.unmute_success', defaultMessage: 'Unmuted {label}' },
  muteConfirm: { id: 'emoji_actions.mute_confirm', defaultMessage: 'Mute this emoji?' },
  muteFirstEnable: { id: 'emoji_actions.mute_first_enable', defaultMessage: 'Mute this emoji? Emoji muting is off, so saving this also turns it on.' },
  muteReenable: { id: 'emoji_actions.mute_reenable', defaultMessage: 'Emoji muting is turned off. Saving this mute turns it back on and applies your saved rules.' },
  unmuteConfirm: { id: 'emoji_actions.unmute_confirm', defaultMessage: 'Unmute this emoji? Saved rules stay until you remove them.' },
  addSuccess: { id: 'emoji_actions.add_success', defaultMessage: 'Added to {name}' },
  removeSuccess: { id: 'emoji_actions.remove_success', defaultMessage: 'Removed from {name}' },
  personalRefreshFailed: { id: 'emoji_actions.personal_refresh_failed', defaultMessage: 'Saved, but the personal set could not refresh' },
  personalConflictRefresh: { id: 'emoji_actions.personal_conflict_refresh', defaultMessage: 'The personal set changed. Reload it before trying again.' },
  retryPersonalRefresh: { id: 'emoji_actions.retry_personal_refresh', defaultMessage: 'Refresh personal set' },
  openSettings: { id: 'emoji_actions.open_mute_settings', defaultMessage: 'Open mute settings' },
  retry: { id: 'emoji_actions.retry', defaultMessage: 'Try again' },
  resolveFailed: { id: 'emoji_actions.resolve_failed', defaultMessage: 'Could not load emoji actions' },
  resolveUnavailable: { id: 'emoji_actions.resolve_unavailable', defaultMessage: 'This emoji is unavailable or was deleted' },
  resolveInvalid: { id: 'emoji_actions.resolve_invalid', defaultMessage: 'Could not identify this emoji' },
  resolveContextFailed: { id: 'emoji_actions.resolve_context_failed', defaultMessage: 'Could not verify this post context' },
  syncFailed: { id: 'emoji_actions.sync_failed', defaultMessage: 'Saved, but the mute list could not refresh' },
  retrySync: { id: 'emoji_actions.retry_sync', defaultMessage: 'Refresh mute list' },
});

// Codes that mean the emoji itself is gone / not in catalog. Path must be
// emoji.* — the same code on context.* is a different failure.
const EMOJI_UNAVAILABLE_CODES = {
  unavailable_emoji: true,
  invalid_unicode: true,
};

const isContextErrorPath = path => typeof path === 'string' && (path === 'context' || path.indexOf('context.') === 0);

const isEmojiErrorPath = path => typeof path === 'string' && (path === 'emoji' || path.indexOf('emoji.') === 0);

const resolveErrorEntries = error => {
  if (!error || !Array.isArray(error.errors)) {
    return [];
  }

  return error.errors.filter(entry => entry && typeof entry === 'object');
};

const hasContextResolveError = error => resolveErrorEntries(error).some(entry => isContextErrorPath(entry.path));

const hasUnavailableEmojiError = error => {
  if (!error) {
    return false;
  }

  if (error.status === 404) {
    return true;
  }

  return resolveErrorEntries(error).some(entry => (
    EMOJI_UNAVAILABLE_CODES[entry.code] && (!entry.path || isEmojiErrorPath(entry.path))
  ));
};

// Map resolve API failures to i18n. Never surface the server's English
// `Invalid emoji reference` string in the menu. context.* invalid_id is not
// the same as an unavailable emoji.
export function resolveErrorMessage(intl, error) {
  if (!error) {
    return intl.formatMessage(messages.resolveFailed);
  }

  if (hasUnavailableEmojiError(error)) {
    return intl.formatMessage(messages.resolveUnavailable);
  }

  if (hasContextResolveError(error)) {
    return intl.formatMessage(messages.resolveContextFailed);
  }

  if (error.status === 422) {
    return intl.formatMessage(messages.resolveInvalid);
  }

  return intl.formatMessage(messages.resolveFailed);
}

// Unavailable / deleted emoji: no retry. Context or transient failures: retry.
export function isResolveErrorRetryable(error) {
  if (!error) {
    return true;
  }

  if (hasUnavailableEmojiError(error)) {
    return false;
  }

  return true;
}

// Pure menu builder for tests. Mutating actions require an explicit resolve
// payload — a missing actions object is not treated as allowed.
export function buildEmojiActionMenuItems({
  intl,
  reference,
  resolved,
  mute,
  categories,
  personalEnabled = true,
  muteActionsEnabled = true,
  status,
  notice,
  error,
  syncError,
  pendingSyncRevision,
  busy,
  reaction,
  source = null,
  onReactSame,
  onCopy,
  onMute,
  onUnmute,
  onAddToCategory,
  onRemoveFromCategory,
  personalRemoveDisabled = false,
  personalRefreshFailed = false,
  onRetryPersonalRefresh,
  onRetry,
  onRetrySync,
}) {
  const items = [];

  if (notice) {
    items.push({ text: notice, icon: 'info-circle', disabled: true });
  }

  if (status === 'loading') {
    items.push({ text: intl.formatMessage(messages.loading), icon: 'spinner', disabled: true });
    return items;
  }

  if (reaction) {
    const reactDisabled = Boolean(
      reaction.disabled
      || (!reaction.my_reaction && reaction.reaction_limit_reached),
    );

    items.push({
      text: intl.formatMessage(reaction.my_reaction ? messages.reactRemove : messages.reactSame),
      icon: reaction.my_reaction ? 'minus-circle' : 'smile-o',
      action: onReactSame,
      disabled: reactDisabled || busy || typeof onReactSame !== 'function',
    });
  }

  const detailPath = detailPathForReference(reference);

  if (detailPath && source !== 'emoji_detail') {
    items.push({
      text: intl.formatMessage(messages.detail),
      icon: 'info-circle',
      to: detailPath,
    });
  }

  const copyTextValue = copyTextForReference(reference, resolved);

  if (copyTextValue) {
    items.push({
      text: intl.formatMessage(messages.copy),
      icon: 'clone',
      action: onCopy,
      disabled: busy || typeof onCopy !== 'function',
    });
  }

  if (syncError || pendingSyncRevision) {
    items.push({
      text: intl.formatMessage(messages.syncFailed),
      icon: 'exclamation-circle',
      disabled: true,
    });
    items.push({
      text: intl.formatMessage(messages.retrySync),
      icon: 'refresh',
      action: onRetrySync,
      disabled: busy,
    });
  }

  const actions = resolved && resolved.actions ? resolved.actions : null;

  if (!actions) {
    if (error) {
      items.push({ text: resolveErrorMessage(intl, error), icon: 'exclamation-triangle', disabled: true });
    }

    // Copy / detail / react may already be present; retry only when useful.
    if (isResolveErrorRetryable(error)) {
      items.push({
        text: intl.formatMessage(messages.retry),
        icon: 'refresh',
        action: onRetry,
      });
    }

    items.push(null, {
      text: intl.formatMessage(messages.openSettings),
      icon: 'cog',
      href: '/settings/custom_emojis/mutes',
      target: '_self',
    });
    return items;
  }

  const canAdd = Boolean(personalEnabled && actions.add_to_personal_category && actions.add_to_personal_category.allowed);
  const canMute = Boolean(actions.mute && actions.mute.allowed);
  const syncBlocked = Boolean(syncError || pendingSyncRevision);

  if (mute) {
    items.push({
      text: intl.formatMessage(messages.muted),
      icon: 'check-circle',
      disabled: true,
    });

    if (muteActionsEnabled) {
      items.push({
        text: intl.formatMessage(messages.manageMute),
        icon: 'sliders',
        href: '/settings/custom_emojis/mutes',
        to: null,
        target: '_self',
      });
      items.push({
        text: intl.formatMessage(messages.unmute),
        icon: 'volume-up',
        action: onUnmute,
        dangerous: true,
        disabled: busy || syncBlocked,
      });
    }
  } else if (muteActionsEnabled && canMute) {
    items.push({
      text: intl.formatMessage(messages.mute),
      icon: 'volume-off',
      action: onMute,
      dangerous: true,
      disabled: busy || syncBlocked,
    });
  }

  if (canAdd && personalRefreshFailed) {
    items.push(null, {
      text: intl.formatMessage(messages.retryPersonalRefresh),
      icon: 'refresh',
      action: onRetryPersonalRefresh,
      disabled: busy || typeof onRetryPersonalRefresh !== 'function',
    });
  } else if (canAdd) {
    items.push(null);

    if (!categories || categories.length === 0) {
      items.push({
        text: intl.formatMessage(messages.noCategories),
        icon: 'folder-open-o',
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
        let textId = messages.addToCategory;
        let icon = 'plus-circle';
        let action = () => onAddToCategory(category);
        let disabled = busy;

        if (present && personalRemoveDisabled) {
          textId = messages.alreadyInCategory;
          icon = 'check-circle';
          action = null;
          disabled = true;
        } else if (present) {
          textId = messages.removeFromCategory;
          icon = 'minus-circle';
          action = typeof onRemoveFromCategory === 'function' ? () => onRemoveFromCategory(category) : null;
          disabled = busy || action === null;
        }

        items.push({
          text: intl.formatMessage(textId, { name }),
          icon,
          action,
          disabled,
        });
      });
    }
  }

  items.push(null, {
    text: intl.formatMessage(messages.openSettings),
    icon: 'cog',
    href: '/settings/custom_emojis/mutes',
    target: '_self',
  });

  return items;
}

// Icons are added only to this menu; other dropdowns retain their own markup.
function renderEmojiActionMenuItem(option, index, { onClick, onKeyPress, setRef }) {
  if (option === null) {
    return <li key={'sep-' + index} className='dropdown-menu__separator' />;
  }

  const { text, href = '#', target = '_blank', method, dangerous, disabled, icon } = option;
  const isDisabled = Boolean(disabled);

  return (
    <li
      key={index}
      className={classNames('dropdown-menu__item', {
        'dropdown-menu__item--dangerous': dangerous,
        'dropdown-menu__item--disabled': isDisabled,
      })}
    >
      <a
        href={isDisabled || href === null ? undefined : href}
        target={isDisabled ? undefined : target}
        data-method={isDisabled ? undefined : method}
        rel='noopener noreferrer'
        role='button'
        tabIndex={isDisabled ? '-1' : '0'}
        aria-disabled={isDisabled ? 'true' : undefined}
        ref={setRef}
        onClick={onClick}
        onKeyPress={isDisabled ? undefined : onKeyPress}
        data-index={index}
      >
        <span className='emoji-actions-menu__item-icon' aria-hidden='true'>
          {icon && <Icon id={icon} fixedWidth />}
        </span>
        <span className='emoji-actions-menu__item-label'>{text}</span>
      </a>
    </li>
  );
}
const popperConfig = {
  strategy: 'fixed',
};

// Action-menu suppression is a gesture policy, not a picker availability policy.
// Handle both explicit bus sources and delegated DOM targets (e.g. a nested
// custom emoji that still exposes a global data-emoji-actions marker).
const isPickerActionSource = (source, anchor) => (
  source === 'standard_picker' ||
  source === 'personal_picker' ||
  Boolean(anchor && anchor.closest && anchor.closest('.emoji-picker-shell'))
);

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
    layout: PropTypes.string,
    openDropdownId: PropTypes.oneOfType([PropTypes.string, PropTypes.number]),
    onSyncMutes: PropTypes.func.isRequired,
    onCloseReactionModal: PropTypes.func,
    onCloseDropdown: PropTypes.func,
    onAddEmojiReaction: PropTypes.func,
    onRemoveEmojiReaction: PropTypes.func,
    onConfirm: PropTypes.func,
    onEmojiMuteEnabled: PropTypes.func,
    getStatus: PropTypes.func,
    previewClickAction: PropTypes.oneOf(['none', 'close', 'detail', 'copy']),
    muteActionsEnabled: PropTypes.bool,
  };

  static defaultProps = {
    previewClickAction: emojiPreviewClickAction,
    muteActionsEnabled: !emojiMuteDisableActions,
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
    personalRefreshFailed: false,
    personalRefreshReason: null,
    statusId: null,
    accountId: null,
    source: null,
    reaction: null,
    previewPosition: null,
  };

  componentDidMount() {
    this.unlisten = setEmojiActionsListener(this.handleOpen);
    this.unlistenSlide = setEmojiActionsSlideListeners({
      onMove: this.handleSlideMove,
      onRelease: this.handleSlideRelease,
      onCancel: this.handleSlideCancel,
    });
    document.addEventListener(emojiActionsEventName(), this.handleDomEvent);
    document.addEventListener('contextmenu', this.handleContextMenu, true);
    document.addEventListener('keydown', this.handleKeyDown, true);
    window.addEventListener('resize', this.handlePreviewResize);
  }

  componentWillUnmount() {
    if (this.unlisten) {
      this.unlisten();
    }

    if (this.unlistenSlide) {
      this.unlistenSlide();
    }

    this.clearSlideHighlight();
    this.clearSlideClickSwallow();
    this.cancelPendingDetailNavigation();
    document.removeEventListener(emojiActionsEventName(), this.handleDomEvent);
    document.removeEventListener('contextmenu', this.handleContextMenu, true);
    document.removeEventListener('keydown', this.handleKeyDown, true);
    window.removeEventListener('resize', this.handlePreviewResize);
    this.cancelPreviewPlacement();
  }

  componentDidUpdate() {
    // The menu starts with a short loading list and is re-positioned by
    // Popper after its async actions arrive. Never show a preview while
    // those sizes are changing. Reveal it once, after two animation frames.
    if (this.state.status === 'ready' && this.state.source !== 'emoji_detail' &&
        this.state.previewPosition === null && this.previewNode) {
      this.schedulePreviewPlacement();
    }
  }

  setMenuNode = node => {
    this.menuNode = node;
  };

  setPreviewNode = node => {
    this.previewNode = node;
  };

  cancelPreviewPlacement = () => {
    if (this.previewPlacementFrame !== null && this.previewPlacementFrame !== undefined) {
      cancelAnimationFrame(this.previewPlacementFrame);
    }
    this.previewPlacementFrame = null;
    this.previewPlacementScheduled = false;
  };

  schedulePreviewPlacement = () => {
    if (this.previewPlacementScheduled || !this.previewNode || !this.menuNode) {
      return;
    }

    const generation = this.loadGeneration;
    const element = this.state.element;
    this.previewPlacementScheduled = true;
    this.previewPlacementFrame = requestAnimationFrame(() => {
      // Wait for Popper's placement/flip calculations to settle after the
      // final async menu item list is committed.
      this.previewPlacementFrame = requestAnimationFrame(() => {
        this.previewPlacementFrame = null;
        this.previewPlacementScheduled = false;
        if (generation !== this.loadGeneration || element !== this.state.element ||
            this.state.status !== 'ready' || this.state.previewPosition !== null) {
          return;
        }

        const menuRect = this.menuNode?.getBoundingClientRect();
        const previewRect = this.previewNode?.getBoundingClientRect();
        if (!menuRect?.height || !previewRect?.height) {
          // A detached privacy portal or unlaid-out menu must not trigger a
          // continuous update loop. Keep the preview hidden for this session.
          this.setState({ previewPosition: false });
          return;
        }

        const position = positionEmojiActionsPreview(menuRect, previewRect, {
          width: window.innerWidth, height: window.innerHeight,
        });
        // Snapshot the location exactly once. Subsequent state updates and
        // image loads must not re-anchor a preview in front of the user.
        this.setState({ previewPosition: position ? {
          left: menuRect.left + position.left,
          top: menuRect.top + position.top,
        } : false });
      });
    });
  };

  handlePreviewResize = () => {
    if (!this.state.element || this.state.source === 'emoji_detail') {
      return;
    }

    this.cancelPreviewPlacement();
    // Hide first; then measure and reveal at the new viewport position.
    this.setState({ previewPosition: null });
  };
  clearSlideHighlight = () => {
    clearEmojiActionsSlideHighlight(this.slideHighlightEl);
    this.slideHighlightEl = null;
  };

  clearSlideClickSwallow = () => {
    if (this.slideClickSwallowTimer !== null && this.slideClickSwallowTimer !== undefined) {
      clearTimeout(this.slideClickSwallowTimer);
      this.slideClickSwallowTimer = null;
    }

    if (this.slideClickSwallow) {
      document.removeEventListener('click', this.slideClickSwallow, true);
      this.slideClickSwallow = null;
    }
  };

  armSlideClickSwallow = () => {
    this.clearSlideClickSwallow();
    const until = Date.now() + LONG_PRESS_CLICK_SUPPRESS_MS;
    // Only the original long-press host should have its trailing synthetic
    // click swallowed — never menu items, unrelated buttons, or keyboard.
    const anchor = this.state.element;

    this.slideClickSwallow = event => {
      if (event.detail === 0) {
        this.clearSlideClickSwallow();
        return;
      }

      if (Date.now() >= until) {
        this.clearSlideClickSwallow();
        return;
      }

      const path = typeof event.composedPath === 'function' ? event.composedPath() : [];
      const relatedToAnchor = Boolean(anchor) && (
        event.target === anchor
        || (typeof anchor.contains === 'function' && anchor.contains(event.target))
        || path.indexOf(anchor) !== -1
      );

      if (!relatedToAnchor) {
        this.clearSlideClickSwallow();
        return;
      }

      event.preventDefault();
      event.stopPropagation();
      this.clearSlideClickSwallow();
    };

    document.addEventListener('click', this.slideClickSwallow, true);
    this.slideClickSwallowTimer = setTimeout(() => {
      this.clearSlideClickSwallow();
    }, LONG_PRESS_CLICK_SUPPRESS_MS);
  };

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
    if (!detail || !detail.reference || !this.isSignedIn() ||
        (emojiPickerDisableActions && isPickerActionSource(detail.source, detail.anchor))) {
      return;
    }

    this.loadGeneration = (this.loadGeneration || 0) + 1;
    const generation = this.loadGeneration;
    const element = detail.anchor || null;
    const pending = getPendingMuteSync(detail.reference);
    const flight = getMuteMutationFlight(detail.reference);
    const storeMute = findMuteForReference(currentEmojiMutes(), detail.reference);

    this.slideActivated = false;
    this.clearSlideHighlight();
    this.clearSlideClickSwallow();
    this.cancelPendingDetailNavigation();
    this.cancelPreviewPlacement();

    // Bind slide activation only to the long-press gesture that opened this menu.
    const pendingGesture = detail.slideGestureId
      ? { gestureId: detail.slideGestureId, anchor: element }
      : peekEmojiActionsSlideGesture(element);
    this.slideGestureId = pendingGesture && pendingGesture.gestureId
      ? pendingGesture.gestureId
      : null;
    this.slideGestureGeneration = generation;

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
      personalRefreshFailed: false,
      personalRefreshReason: null,
      statusId: detail.status_id || null,
      accountId: detail.account_id || null,
      source: detail.source || null,
      reaction: detail.source === 'reaction' ? (detail.reaction || null) : null,
      previewPosition: null,
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
    this.cancelPreviewPlacement();
    this.slideActivated = false;
    this.slideGestureId = null;
    this.slideGestureGeneration = null;
    this.clearSlideHighlight();
    this.clearSlideClickSwallow();
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
      personalRefreshFailed: false,
      personalRefreshReason: null,
      statusId: null,
      accountId: null,
      source: null,
      reaction: null,
      previewPosition: null,
    });
  };

  isSlideGestureCurrent = (payload = {}) => {
    if (!this.slideGestureId || !payload.gestureId) {
      return false;
    }

    if (payload.gestureId !== this.slideGestureId) {
      return false;
    }

    if (this.slideGestureGeneration !== this.loadGeneration) {
      return false;
    }

    if (!this.state.element || !this.state.reference) {
      return false;
    }

    // Fail-closed when the host cell was removed / replaced (Nimble rebuild,
    // status unmount). Stale document pointerup must not hit-test the menu.
    if (this.state.element.isConnected === false) {
      return false;
    }

    // Anchor must still be the open menu's host when provided.
    if (payload.anchor && payload.anchor !== this.state.element) {
      return false;
    }

    return true;
  };

  handleSlideCancel = (payload = {}) => {
    if (!payload.gestureId || payload.gestureId !== this.slideGestureId) {
      return;
    }

    if (this.slideGestureGeneration !== this.loadGeneration) {
      return;
    }

    this.clearSlideHighlight();
  };

  handleSlideMove = (payload = {}) => {
    if (!this.isSlideGestureCurrent(payload)) {
      // Matching id but stale (disconnected / generation) — drop our highlight.
      if (payload.gestureId && payload.gestureId === this.slideGestureId) {
        this.clearSlideHighlight();
      }
      return;
    }

    if (this.state.status === 'loading') {
      this.clearSlideHighlight();
      return;
    }

    const item = hitTestEmojiActionsMenuItem(payload.clientX, payload.clientY);
    this.slideHighlightEl = setEmojiActionsSlideHighlight(this.slideHighlightEl, item);
  };

  handleSlideRelease = (payload = {}) => {
    if (!this.isSlideGestureCurrent(payload) || this.slideActivated) {
      this.clearSlideHighlight();
      return false;
    }

    if (this.state.status === 'loading' || this.state.busy) {
      this.clearSlideHighlight();
      return false;
    }

    const el = hitTestEmojiActionsMenuItem(payload.clientX, payload.clientY);
    this.clearSlideHighlight();

    if (!el) {
      // Outside the menu: leave it open for a follow-up tap.
      return false;
    }

    const index = Number(el.getAttribute('data-index'));
    const item = this.menuItems()[index];

    if (!item || item.disabled) {
      return false;
    }

    this.slideActivated = true;
    this.armSlideClickSwallow();
    this.activateMenuItem(item);
    return true;
  };

  shouldClosePickerForDetail = () => {
    const { source } = this.state;
    const { layout } = this.props;

    if (source !== 'standard_picker' && source !== 'personal_picker') {
      return false;
    }

    return layout === 'mobile' || layout === 'single-column';
  };

  closePickerSurfaces = () => {
    const { openDropdownId, onCloseReactionModal, onCloseDropdown } = this.props;

    if (typeof onCloseReactionModal === 'function') {
      onCloseReactionModal();
    }

    if (openDropdownId && typeof onCloseDropdown === 'function') {
      onCloseDropdown(openDropdownId);
    }
  };

  cancelPendingDetailNavigation = () => {
    if (typeof this.cancelDetailNavigation === 'function') {
      this.cancelDetailNavigation();
      this.cancelDetailNavigation = null;
    }
  };

  navigateAfterPickerClose = path => {
    const history = this.context.router && this.context.router.history;

    this.cancelPendingDetailNavigation();
    this.cancelDetailNavigation = scheduleNavigateAfterPickerClose(history, path);
  };

  activateMenuItem = (item, event = null) => {
    if (!item || item.disabled) {
      return;
    }

    if (typeof item.action === 'function') {
      item.action(event);
      return;
    }

    const path = item.to;
    const closePicker = Boolean(path) && this.shouldClosePickerForDetail();

    this.handleClose();

    if (path && this.context.router) {
      if (closePicker) {
        // Arm POP wait before close so ModalRoot's goBack is observed.
        this.navigateAfterPickerClose(path);
        this.closePickerSurfaces();
      } else {
        this.context.router.history.push(path);
      }
      return;
    }

    if (item.href) {
      window.location.assign(item.href);
    }
  };

  findTarget = () => this.state.element;

  openFromElement = (element, event) => {
    const source = element.dataset.emojiSource || 'dataset';

    if (emojiPickerDisableActions && isPickerActionSource(source, element)) {
      return;
    }

    const reference = referenceFromDataset(element.dataset);

    if (!reference) {
      return;
    }

    if (event) {
      event.preventDefault();
      event.stopPropagation();
    }
    const reaction = source === 'reaction' ? normalizeReactionContext({
      name: element.dataset.emojiReactionName,
      domain: element.dataset.emojiReactionDomain || null,
      url: element.dataset.emojiReactionUrl || null,
      static_url: element.dataset.emojiReactionStaticUrl || null,
      my_reaction: element.dataset.emojiMyReaction === '1',
      reaction_limit_reached: element.dataset.emojiReactionLimitReached === '1',
      disabled: element.dataset.emojiReactionDisabled === '1',
    }) : null;

    openEmojiActions(reference, {
      anchor: element,
      status_id: element.dataset.emojiStatusId || null,
      account_id: element.dataset.emojiAccountId || null,
      source,
      reaction,
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

    // iOS can emit a late synthetic contextmenu after a completed long press.
    // Do not reopen/reposition an already open menu for the same gesture.
    if (Date.now() < Number(target.dataset.emojiLongPressUntil || 0)) {
      event.preventDefault();
      event.stopPropagation();
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

    // Keep detail, copy, and mute while avoiding personal-set network requests.
    const personalRequest = emojiPickerDisablePersonal
      ? Promise.resolve(null)
      : loadPersonalEmojiSetDocument().catch(() => null);

    Promise.all([
      resolveEmojiReference(reference, context).catch(error => ({ error })),
      personalRequest,
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
    this.cancelPreviewPlacement();
    this.loadGeneration = (this.loadGeneration || 0) + 1;
    const generation = this.loadGeneration;

    this.setState({ status: 'loading', error: null, notice: null, resolved: null, previewPosition: null }, () => {
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
      reaction,
    } = this.state;

    return buildEmojiActionMenuItems({
      intl,
      reference,
      resolved,
      mute,
      categories,
      personalEnabled: !emojiPickerDisablePersonal,
      muteActionsEnabled: this.props.muteActionsEnabled,
      status,
      notice,
      error,
      syncError,
      pendingSyncRevision,
      busy,
      reaction,
      source: this.state.source,
      onReactSame: this.handleReactSame,
      onCopy: this.handleCopy,
      onMute: this.handleMute,
      onUnmute: this.handleUnmute,
      onAddToCategory: this.handleAddToCategory,
      onRemoveFromCategory: this.handleRemoveFromCategory,
      personalRemoveDisabled: emojiActionsDisablePersonalRemove,
      personalRefreshFailed: this.state.personalRefreshFailed,
      onRetryPersonalRefresh: this.handleRetryPersonalRefresh,
      onRetry: this.handleRetry,
      onRetrySync: this.handleRetrySync,
    });
  }

  handleCopy = () => {
    const { intl } = this.props;
    const { reference, resolved } = this.state;
    const text = copyTextForReference(reference, resolved);

    if (!text) {
      return;
    }

    copyText(text).then(() => {
      if (!referencesEqual(reference, this.state.reference)) {
        return;
      }

      this.setState({ notice: intl.formatMessage(messages.copySuccess), error: null });
    }).catch(() => {
      if (!referencesEqual(reference, this.state.reference)) {
        return;
      }

      this.setState({ notice: intl.formatMessage(messages.copyFailed) });
    });
  };

  handleReactSame = () => {
    const { getStatus, onAddEmojiReaction, onRemoveEmojiReaction } = this.props;
    const { reaction, statusId } = this.state;

    if (!reaction || !statusId || typeof getStatus !== 'function') {
      return;
    }

    const status = getStatus(statusId);

    if (!status) {
      return;
    }

    if (reaction.my_reaction) {
      if (typeof onRemoveEmojiReaction === 'function') {
        onRemoveEmojiReaction(status, reaction.name);
      }
    } else if (typeof onAddEmojiReaction === 'function') {
      onAddEmojiReaction(
        status,
        reaction.name,
        reaction.domain,
        reaction.url,
        reaction.static_url,
      );
    }

    this.handleClose();
  };

  confirmMuteAction = (decision, enable, preservedReference) => {
    const { intl } = this.props;
    const reference = preservedReference || this.state.reference;
    let messageId = messages.muteConfirm;

    if (decision.reason === 'reenable') {
      messageId = messages.muteReenable;
    } else if (decision.reason === 'first_enable') {
      messageId = messages.muteFirstEnable;
    }

    this.handleClose();
    this.props.onConfirm({
      message: intl.formatMessage(messageId),
      confirm: intl.formatMessage(messages.mute),
      onConfirm: () => {
        if (this.state.reference && !referencesEqual(this.state.reference, reference)) {
          return;
        }

        this.persistMute({ enable, reference });
      },
    });
  };

  handleMute = () => {
    const decision = emojiMuteConfirmation({ operation: 'mute' });

    if (decision.required) {
      this.confirmMuteAction(decision, decision.reenable);
      return;
    }

    this.persistMute({ enable: false });
  };

  persistMute = ({ enable, reference: capturedReference } = {}) => {
    const { intl, onSyncMutes } = this.props;
    const reference = capturedReference || this.state.reference;

    if (capturedReference && this.state.reference && !referencesEqual(this.state.reference, capturedReference)) {
      return;
    }

    if (!this.props.muteActionsEnabled || !reference || this.state.busy || this.state.pendingSyncRevision || isMuteMutationInFlight(reference) || getPendingMuteSync(reference)) {
      return;
    }

    const activate = currentEmojiMuteBoot().availability !== 'enabled';

    if (!beginMuteMutation(reference, 'mute')) {
      return;
    }

    const session = captureMenuSession(this.loadGeneration, reference);

    this.setState({ busy: true, error: null, notice: null, syncError: null });

    createMuteAndSync({
      createMute: createEmojiMute,
      syncMutes: onSyncMutes,
      reference,
      enable: enable === true,
      onEnabled: () => {
        if (activate && typeof this.props.onEmojiMuteEnabled === 'function') {
          this.props.onEmojiMuteEnabled();
        }
      },
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

      // Same identity may have been closed and reopened (new generation). Apply
      // there; never paint into a different emoji's open menu.
      if (!canApplyMutationToOpenMenu(session, { reference: this.state.reference })) {
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

      const reenable = !enable && error && Array.isArray(error.errors) && error.errors.some(item => item && item.code === 'reenable_required');
      const openReference = this.state.reference;
      const closedForThisEmoji = !openReference && session && referencesEqual(session.reference, reference);

      if (reenable && (canApplyMutationToOpenMenu(session, { reference: openReference }) || closedForThisEmoji)) {
        this.setState({ busy: false, error: null });
        this.confirmMuteAction({ reason: 'reenable' }, true, reference);
        return;
      }

      if (!canApplyMutationToOpenMenu(session, { reference: this.state.reference })) {
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
    const decision = emojiMuteConfirmation({ operation: 'unmute' });
    const mute = this.state.mute;
    const reference = this.state.reference;

    if (decision.required) {
      const { intl } = this.props;

      this.handleClose();
      this.props.onConfirm({
        message: intl.formatMessage(messages.unmuteConfirm),
        confirm: intl.formatMessage(messages.unmute),
        onConfirm: () => {
          if (this.state.reference && !referencesEqual(this.state.reference, reference)) {
            return;
          }

          if (this.state.mute && mute && this.state.mute.id !== mute.id) {
            return;
          }

          this.persistUnmute({ mute, reference });
        },
      });
      return;
    }

    this.persistUnmute();
  };

  persistUnmute = ({ mute: capturedMute, reference: capturedReference } = {}) => {
    const { intl, onSyncMutes } = this.props;
    const mute = capturedMute || this.state.mute;
    const reference = capturedReference || this.state.reference;

    if (capturedReference && this.state.reference && !referencesEqual(this.state.reference, capturedReference)) {
      return;
    }

    if (!this.props.muteActionsEnabled || !mute || this.state.busy || this.state.pendingSyncRevision || isMuteMutationInFlight(reference) || getPendingMuteSync(reference)) {
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

      if (!canApplyMutationToOpenMenu(session, { reference: this.state.reference })) {
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

      if (!canApplyMutationToOpenMenu(session, { reference: this.state.reference })) {
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

  sessionCurrent = session => isCurrentMenuSession(session, {
    loadGeneration: this.loadGeneration,
    reference: this.state.reference,
  });

  applyPersonalDocument = (session, document, notice) => {
    if (!this.sessionCurrent(session) || !document || !Array.isArray(document.categories)) {
      return false;
    }

    this.setState({
      busy: false,
      error: null,
      personalRefreshFailed: false,
      personalRefreshReason: null,
      personalRevision: document.revision,
      categories: document.categories,
      notice,
    });
    return true;
  };

  // Stock decides whether a response is current. Generation movement alone does
  // not. A rejected or no-op document is replaced by a fresh read. Refresh
  // failure stays on an explicit reload and does not resend the old revision.
  finishPersonalCategoryMutation = ({
    session,
    stockGeneration,
    document,
    changed,
    successMessage,
  }) => {
    const stockMoved = personalEmojiStockGeneration() !== stockGeneration;
    const published = changed ? notifySavedPersonalEmojiSet(document) === true : false;
    const unchangedIsCurrent = !changed && !stockMoved && personalEmojiDocumentIsCurrent(document);

    if (!this.sessionCurrent(session)) {
      return;
    }

    if (published || unchangedIsCurrent) {
      this.applyPersonalDocument(session, document, successMessage);
      return;
    }

    this.reloadPersonalDocument(session, {
      notice: successMessage,
      allowDocument: published ? document : null,
      reason: 'saved',
    });
  };

  reloadPersonalDocument = (session, { notice, allowDocument, reason }) => {
    loadPersonalEmojiSetDocument().then(latest => {
      if (!this.sessionCurrent(session)) {
        return;
      }

      if (!latest || !Array.isArray(latest.categories)) {
        this.failPersonalRefresh(session, allowDocument, notice, reason);
        return;
      }

      this.applyPersonalDocument(session, latest, notice);
    }).catch(() => {
      this.failPersonalRefresh(session, allowDocument, notice, reason);
    });
  };

  failPersonalRefresh = (session, allowDocument, notice, reason) => {
    if (!this.sessionCurrent(session)) {
      return;
    }

    if (allowDocument && this.applyPersonalDocument(session, allowDocument, notice)) {
      return;
    }

    const conflict = reason === 'conflict' || this.state.personalRefreshReason === 'conflict';
    this.setState({
      busy: false,
      personalRefreshFailed: true,
      personalRefreshReason: conflict ? 'conflict' : 'saved',
      notice: this.props.intl.formatMessage(conflict ? messages.personalConflictRefresh : messages.personalRefreshFailed),
      error: new Error('Could not refresh personal set'),
    });
  };

  recoverPersonalConflict = (session, message) => {
    this.reloadPersonalDocument(session, { notice: message, allowDocument: null, reason: 'conflict' });
  };

  handleRetryPersonalRefresh = () => {
    if (this.state.busy || !this.state.reference) {
      return;
    }

    const session = captureMenuSession(this.loadGeneration, this.state.reference);
    const reason = this.state.personalRefreshReason === 'conflict' ? 'conflict' : 'saved';

    this.setState({ busy: true, error: null });
    this.reloadPersonalDocument(session, { notice: null, allowDocument: null, reason });
  };

  handleAddToCategory = category => {
    const { intl } = this.props;
    const { reference, personalRevision } = this.state;

    if (emojiPickerDisablePersonal || this.state.personalRefreshFailed || !category || !reference || this.state.busy) {
      return;
    }

    const session = captureMenuSession(this.loadGeneration, reference);
    const stockGeneration = personalEmojiStockGeneration();

    this.setState({ busy: true, error: null, notice: null });

    appendPersonalCategoryItem(category.id, reference, personalRevision).then(document => {
      const changed = Boolean(document && document.operation && document.operation.added);

      this.finishPersonalCategoryMutation({
        session,
        stockGeneration,
        document,
        changed,
        successMessage: intl.formatMessage(
          document && document.operation && document.operation.added === false ? messages.alreadyInCategory : messages.addSuccess,
          { name: category.name || category.id },
        ),
      });
    }).catch(error => {
      if (!this.sessionCurrent(session)) {
        return;
      }

      if (error && error.code === 'conflict') {
        this.recoverPersonalConflict(session, intl.formatMessage(messages.addConflict));
        return;
      }

      this.setState({
        busy: false,
        personalRefreshFailed: false,
        error,
        notice: intl.formatMessage(messages.addFailed),
      });
    });
  };

  handleRemoveFromCategory = category => {
    const { intl } = this.props;
    const { reference, personalRevision } = this.state;

    if (emojiActionsDisablePersonalRemove || emojiPickerDisablePersonal || this.state.personalRefreshFailed || !category || !reference || this.state.busy) {
      return;
    }

    const session = captureMenuSession(this.loadGeneration, reference);
    const stockGeneration = personalEmojiStockGeneration();

    this.setState({ busy: true, error: null, notice: null });

    removePersonalCategoryItem(category.id, reference, personalRevision).then(document => {
      this.finishPersonalCategoryMutation({
        session,
        stockGeneration,
        document,
        changed: Boolean(document && document.operation && document.operation.removed),
        successMessage: intl.formatMessage(messages.removeSuccess, { name: category.name || category.id }),
      });
    }).catch(error => {
      if (!this.sessionCurrent(session)) {
        return;
      }

      if (error && error.code === 'conflict') {
        this.recoverPersonalConflict(session, intl.formatMessage(messages.removeConflict));
        return;
      }

      this.setState({
        busy: false,
        personalRefreshFailed: false,
        error,
        notice: intl.formatMessage(messages.removeFailed),
      });
    });
  };

  // A preview is outside the dropdown's DOM. Its full hit area must be treated
  // as inside the open menu so touchend/click cannot dismiss the menu first.
  isPreviewEvent = event => Boolean(this.previewNode && this.previewNode.contains(event.target));

  stopPreviewPointer = event => {
    event.stopPropagation();
  };

  handlePreviewContextMenu = event => {
    event.preventDefault();
    event.stopPropagation();
  };

  handlePreviewClick = event => {
    event.preventDefault();
    event.stopPropagation();

    switch (this.props.previewClickAction) {
    case 'close':
      this.handleClose();
      break;
    case 'detail': {
      const path = detailPathForReference(this.state.reference);
      if (path) {
        this.activateMenuItem({ to: path });
      }
      break;
    }
    case 'copy':
      if (!this.state.busy) {
        this.handleCopy();
      }
      break;
    default:
      // The default behavior is intentionally inert, without click-through.
      break;
    }
  };

  handleItemClick = event => {
    if (event.type === 'click' && event.button !== 0) {
      return;
    }

    if (event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) {
      return;
    }

    // Menu item clicks are always intentional (pointer or keyboard). The
    // slide synthetic-click swallow is document+anchor scoped only — never
    // block a fresh item activation here.

    const index = Number(event.currentTarget.getAttribute('data-index'));
    const item = this.menuItems()[index];

    event.preventDefault();
    event.stopPropagation();

    this.activateMenuItem(item, event);
  };

  render() {
    if (!this.state.element || !this.state.reference) {
      return null;
    }

    const preview = this.state.source === 'emoji_detail' || this.state.status !== 'ready' ? null : buildEmojiActionsPreview(
      this.state.reference, this.state.resolved, this.state.element,
    );

    return (
      <React.Fragment>
        <Overlay
          key={this.loadGeneration}
          show
          offset={[5, 5]}
          placement='bottom'
          flip
          target={this.findTarget}
          container={getEmojiActionsOverlayRoot}
          popperConfig={popperConfig}
        >
          {({ props, arrowProps, placement }) => (
            <div
              {...props}
              data-emoji-actions-menu='1'
              className='emoji-actions-menu-portal'
              style={{ ...(props.style || {}), pointerEvents: 'auto' }}
            >
              <div className={`dropdown-animation dropdown-menu ${placement}`} ref={this.setMenuNode}>
                <div className={`dropdown-menu__arrow ${placement}`} {...arrowProps} />
                <DropdownMenu
                  items={this.menuItems()}
                  renderItem={renderEmojiActionMenuItem}
                  onClose={this.handleClose}
                  onItemClick={this.handleItemClick}
                  isEventInside={this.isPreviewEvent}
                />
              </div>
            </div>
          )}
        </Overlay>
        {preview && createPortal(
          <div
            className='emoji-actions-menu__preview'
            aria-hidden='true'
            ref={this.setPreviewNode}
            onMouseDown={this.stopPreviewPointer}
            onPointerDown={this.stopPreviewPointer}
            onTouchStart={this.stopPreviewPointer}
            onTouchEnd={this.stopPreviewPointer}
            onContextMenu={this.handlePreviewContextMenu}
            onClick={this.handlePreviewClick}
            style={this.state.previewPosition === null ? { visibility: 'hidden', left: 0, top: 0 } : this.state.previewPosition || { display: 'none' }}
          >
            <div className='emoji-actions-menu__preview-media'>
              {preview.imageSrc ? (
                <img src={preview.imageSrc} alt='' draggable='false' />
              ) : (
                <span>{preview.native}</span>
              )}
            </div>
            {(preview.name || preview.shortcode) && (
              <div className='emoji-actions-menu__preview-meta'>
                {preview.name && <div className='emoji-actions-menu__preview-name' title={preview.name}>{preview.name}</div>}
                {preview.shortcode && <div className='emoji-actions-menu__preview-shortcode' title={preview.shortcode}>{preview.shortcode}</div>}
              </div>
            )}
          </div>,
          getEmojiActionsOverlayRoot(),
        )}
      </React.Fragment>
    );
  }

}

const mapStateToProps = state => ({
  getStatus: id => (id ? state.getIn(['statuses', id]) : null),
  layout: state.getIn(['meta', 'layout']),
  openDropdownId: state.getIn(['dropdown_menu', 'openId']),
});

const mapDispatchToProps = dispatch => ({
  onSyncMutes(options) {
    return dispatch(syncEmojiMutes(options));
  },
  onCloseReactionModal() {
    dispatch(closeModal('REACTION'));
  },
  onCloseDropdown(id) {
    dispatch(closeDropdownMenu(id));
  },
  onAddEmojiReaction(status, name, domain, url, staticUrl) {
    return dispatch(addEmojiReaction(status, name, domain, url, staticUrl));
  },
  onRemoveEmojiReaction(status, name) {
    return dispatch(removeEmojiReaction(status, name));
  },
  onConfirm(props) {
    dispatch(openModal('CONFIRM', props));
  },
  onEmojiMuteEnabled() {
    dispatch(enableEmojiMuteLoading());
  },
});

export {
  datasetFromReference,
  openEmojiActions,
  EmojiActionsMenuController,
  isCurrentMenuSession,
  canApplyMutationToOpenMenu,
  captureMenuSession,
};
export default injectIntl(connect(mapStateToProps, mapDispatchToProps)(EmojiActionsMenuController));
