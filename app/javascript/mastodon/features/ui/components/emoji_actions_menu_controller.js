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
  datasetFromReference,
  detailPathForReference,
  findMuteForReference,
  referenceFromDataset,
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
});

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

    const element = detail.anchor || null;

    this.setState({
      element,
      reference: detail.reference,
      resolved: null,
      mute: findMuteForReference(currentEmojiMutes(), detail.reference),
      categories: null,
      personalRevision: null,
      status: 'loading',
      notice: null,
      error: null,
      busy: false,
      statusId: detail.status_id || null,
      accountId: detail.account_id || null,
    }, this.loadMenuData);
  };

  handleClose = () => {
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

  loadMenuData = () => {
    const { reference, statusId, accountId } = this.state;

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
      if (!this.state.reference || !referencesEqual(this.state.reference, reference)) {
        return;
      }

      const categories = personal && Array.isArray(personal.categories) ? personal.categories : [];
      const nextReference = resolved && resolved.reference ? resolved.reference : reference;

      this.setState({
        resolved: resolved && !resolved.error ? resolved : null,
        reference: nextReference,
        mute: findMuteForReference(currentEmojiMutes(), nextReference),
        categories,
        personalRevision: personal ? personal.revision : null,
        status: 'ready',
        error: resolved && resolved.error ? resolved.error : null,
      });
    }).catch(() => {
      if (!this.state.reference || !referencesEqual(this.state.reference, reference)) {
        return;
      }

      this.setState({ status: 'ready', error: new Error('Could not load emoji actions') });
    });
  };

  categoryContains(category, reference) {
    if (!category || !Array.isArray(category.items)) {
      return false;
    }

    return category.items.some(item => referencesEqual(item, reference));
  }

  menuItems() {
    const { intl } = this.props;
    const { reference, resolved, mute, categories, status, notice, error } = this.state;
    const items = [];

    if (notice) {
      items.push({ text: notice, disabled: true });
    }

    if (error && status === 'ready') {
      items.push({ text: error.message || intl.formatMessage(messages.muteFailed), disabled: true });
    }

    if (status === 'loading') {
      items.push({ text: intl.formatMessage(messages.loading), disabled: true });
      return items;
    }

    const actions = resolved && resolved.actions ? resolved.actions : null;
    const canAdd = !actions || (actions.add_to_personal_category && actions.add_to_personal_category.allowed);
    const detailPath = detailPathForReference(reference);

    if (detailPath) {
      items.push({
        text: intl.formatMessage(messages.detail),
        to: detailPath,
      });
    }

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
        action: this.handleUnmute,
        dangerous: true,
      });
    } else if (!actions || (actions.mute && actions.mute.allowed)) {
      items.push({
        text: intl.formatMessage(messages.mute),
        action: this.handleMute,
        dangerous: true,
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
          const present = this.categoryContains(category, reference);
          const name = category.name || category.id;

          items.push({
            text: intl.formatMessage(present ? messages.alreadyInCategory : messages.addToCategory, { name }),
            action: present ? null : () => this.handleAddToCategory(category),
            disabled: present || this.state.busy,
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

  handleMute = () => {
    const { intl, onSyncMutes } = this.props;
    const { reference } = this.state;

    if (!reference || this.state.busy) {
      return;
    }

    this.setState({ busy: true, error: null, notice: null });

    createEmojiMute(reference).then(response => {
      return onSyncMutes({ changed: { revision: response.revision } }).then(() => response);
    }).then(response => {
      this.setState({
        busy: false,
        mute: response.emoji_mute || findMuteForReference(currentEmojiMutes(), reference),
        notice: intl.formatMessage(messages.muteSuccess, { label: referenceLabel(reference) }),
      });
    }).catch(error => {
      this.setState({
        busy: false,
        error,
        notice: null,
      });
    });
  };

  handleUnmute = () => {
    const { intl, onSyncMutes } = this.props;
    const { mute, reference } = this.state;

    if (!mute || this.state.busy) {
      return;
    }

    this.setState({ busy: true, error: null, notice: null });

    deleteEmojiMute(mute.id, mute.revision).then(response => {
      return onSyncMutes({ changed: { revision: response.revision } }).then(() => response);
    }).then(() => {
      this.setState({
        busy: false,
        mute: null,
        notice: intl.formatMessage(messages.unmuteSuccess, { label: referenceLabel(reference) }),
      });
    }).catch(error => {
      this.setState({
        busy: false,
        error,
        notice: null,
      });
    });
  };

  handleAddToCategory = category => {
    const { intl } = this.props;
    const { reference, personalRevision } = this.state;

    if (!category || !reference || this.state.busy) {
      return;
    }

    this.setState({ busy: true, error: null, notice: null });

    appendPersonalCategoryItem(category.id, reference, personalRevision).then(document => {
      if (document && document.operation && document.operation.added) {
        notifySavedPersonalEmojiSet(document);
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

export { datasetFromReference, openEmojiActions };
export default injectIntl(connect(null, mapDispatchToProps)(EmojiActionsMenuController));
