import React from 'react';
import { connect } from 'react-redux';
import Status from '../components/status';
import { makeGetStatus, makeGetPictureInPicture } from '../selectors';
import {
  replyCompose,
  quoteCompose,
  mentionCompose,
  directCompose,
  addReference,
  removeReference,
} from '../actions/compose';
import {
  reblog,
  favourite,
  bookmark,
  unreblog,
  unfavourite,
  unbookmark,
  pin,
  unpin,
  addEmojiReaction,
  removeEmojiReaction,
} from '../actions/interactions';
import {
  muteStatus,
  unmuteStatus,
  deleteStatus,
  expireStatus,
  hideStatus,
  revealStatus,
  toggleStatusCollapse,
} from '../actions/statuses';
import {
  followAccount,
  unfollowAccount,
  subscribeAccount,
  unsubscribeAccount,
  unmuteAccount,
  unblockAccount,
} from '../actions/accounts';
import {
  blockDomain,
  unblockDomain,
} from '../actions/domain_blocks';

import { initMuteModal } from '../actions/mutes';
import { initBlockModal } from '../actions/blocks';
import { initBoostModal } from '../actions/boosts';
import { initReport } from '../actions/reports';
import { openModal } from '../actions/modal';
import { deployPictureInPicture } from '../actions/picture_in_picture';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import { boostModal, deleteModal, followModal, unfollowModal, subscribeModal, unsubscribeModal, confirmDomainBlock } from '../initial_state';
import { showAlertForError } from '../actions/alerts';
import { List as ImmutableList } from 'immutable';
import { me, maxReactionsPerAccount } from 'mastodon/initial_state';

const messages = defineMessages({
  deleteConfirm: { id: 'confirmations.delete.confirm', defaultMessage: 'Delete' },
  deleteMessage: { id: 'confirmations.delete.message', defaultMessage: 'Are you sure you want to delete this status?' },
  redraftConfirm: { id: 'confirmations.redraft.confirm', defaultMessage: 'Delete & redraft' },
  redraftMessage: { id: 'confirmations.redraft.message', defaultMessage: 'Are you sure you want to delete this status and re-draft it? Favourites and boosts will be lost, and replies to the original post will be orphaned.' },
  expireConfirm: { id: 'confirmations.expire.confirm', defaultMessage: 'Expire' },
  expireMessage: { id: 'confirmations.expire.message', defaultMessage: 'Are you sure you want to expire this status?' },
  replyConfirm: { id: 'confirmations.reply.confirm', defaultMessage: 'Reply' },
  replyMessage: { id: 'confirmations.reply.message', defaultMessage: 'Replying now will overwrite the message you are currently composing. Are you sure you want to proceed?' },
  quoteConfirm: { id: 'confirmations.quote.confirm', defaultMessage: 'Quote' },
  quoteMessage: { id: 'confirmations.quote.message', defaultMessage: 'Quoting now will overwrite the message you are currently composing. Are you sure you want to proceed?' },
  blockDomainConfirm: { id: 'confirmations.domain_block.confirm', defaultMessage: 'Hide entire domain' },
  blockDomainPassphrase: { id: 'confirmations.domain_block.passphrase', defaultMessage: 'block' },
  followConfirm: { id: 'confirmations.follow.confirm', defaultMessage: 'Follow' },
  unfollowConfirm: { id: 'confirmations.unfollow.confirm', defaultMessage: 'Unfollow' },
  subscribeConfirm: { id: 'confirmations.subscribe.confirm', defaultMessage: 'Subscribe' },
  unsubscribeConfirm: { id: 'confirmations.unsubscribe.confirm', defaultMessage: 'Unsubscribe' },
});

const makeMapStateToProps = () => {
  const getStatus = makeGetStatus();
  const getPictureInPicture = makeGetPictureInPicture();
  const getProper = (status) => status.get('reblog', null) !== null && typeof status.get('reblog') === 'object' ? status.get('reblog') : status;

  const mapStateToProps = (state, props) => {
    const status = getStatus(state, props);
    const id = !!status ? getProper(status).get('id') : null;

    return {
      status,
      pictureInPicture: getPictureInPicture(state, props),
      id,
      referenced: state.getIn(['compose', 'references']).has(id),
      contextReferenced: state.getIn(['compose', 'context_references']).has(id),
      emojiReactions: !!status ? status.get('emoji_reactions', ImmutableList()) : ImmutableList(),
    };
  };

  return mapStateToProps;
};

const mergeProps = ({ status, pictureInPicture, referenced, contextReferenced, emojiReactions }, dispatchProps, ownProps) => {
  const myCount = emojiReactions.count((emojiReaction) => emojiReaction.get('account_ids', ImmutableList()).includes(me));

  return {
    ...ownProps,
    ...dispatchProps,
    status,
    pictureInPicture,
    referenced,
    contextReferenced,
    emojiReactioned: myCount > 0,
    reactionLimitReached: myCount >= maxReactionsPerAccount,
  };
};

const mapDispatchToProps = (dispatch, { intl }) => ({

  onReply (status, router) {
    dispatch((_, getState) => {
      let state = getState();

      if (state.getIn(['compose', 'text']).trim().length !== 0 && state.getIn(['compose', 'dirty'])) {
        dispatch(openModal('CONFIRM', {
          message: intl.formatMessage(messages.replyMessage),
          confirm: intl.formatMessage(messages.replyConfirm),
          onConfirm: () => dispatch(replyCompose(status, router)),
        }));
      } else {
        dispatch(replyCompose(status, router));
      }
    });
  },

  onModalReblog (status, privacy) {
    if (status.get('reblogged')) {
      dispatch(unreblog(status));
    } else {
      dispatch(reblog(status, privacy));
    }
  },

  onReblog (status, e) {
    if ((e && e.shiftKey) ^ !boostModal) {
      this.onModalReblog(status);
    } else {
      dispatch(initBoostModal({ status, onReblog: this.onModalReblog }));
    }
  },

  onQuote (status, router) {
    dispatch((_, getState) => {
      let state = getState();

      if (state.getIn(['compose', 'text']).trim().length !== 0 && state.getIn(['compose', 'dirty'])) {
        dispatch(openModal('CONFIRM', {
          message: intl.formatMessage(messages.quoteMessage),
          confirm: intl.formatMessage(messages.quoteConfirm),
          onConfirm: () => dispatch(quoteCompose(status, router)),
        }));
      } else {
        dispatch(quoteCompose(status, router));
      }
    });
  },

  onFavourite (status) {
    if (status.get('favourited')) {
      dispatch(unfavourite(status));
    } else {
      dispatch(favourite(status));
    }
  },

  onBookmark (status) {
    if (status.get('bookmarked')) {
      dispatch(unbookmark(status));
    } else {
      dispatch(bookmark(status));
    }
  },

  onPin (status) {
    if (status.get('pinned')) {
      dispatch(unpin(status));
    } else {
      dispatch(pin(status));
    }
  },

  onEmbed (status) {
    dispatch(openModal('EMBED', {
      url: status.get('url'),
      onError: error => dispatch(showAlertForError(error)),
    }));
  },

  onDelete (status, history, withRedraft = false) {
    if (!deleteModal) {
      dispatch(deleteStatus(status.get('id'), history, withRedraft));
    } else {
      dispatch(openModal('CONFIRM', {
        message: intl.formatMessage(withRedraft ? messages.redraftMessage : messages.deleteMessage),
        confirm: intl.formatMessage(withRedraft ? messages.redraftConfirm : messages.deleteConfirm),
        onConfirm: () => dispatch(deleteStatus(status.get('id'), history, withRedraft)),
      }));
    }
  },

  onExpire (status) {
    if (!deleteModal) {
      dispatch(expireStatus(status.get('id')));
    } else {
      dispatch(openModal('CONFIRM', {
        message: intl.formatMessage(messages.expireMessage),
        confirm: intl.formatMessage(messages.expireConfirm),
        onConfirm: () => dispatch(expireStatus(status.get('id'))),
      }));
    }
  },

  onDirect (account, router) {
    dispatch(directCompose(account, router));
  },

  onMemberList (status, history) {
    history.push(`/statuses/${status.get('id')}/mentions`);
  },

  onMention (account, router) {
    dispatch(mentionCompose(account, router));
  },

  onOpenMedia (statusId, media, index) {
    dispatch(openModal('MEDIA', { statusId, media, index }));
  },

  onOpenVideo (statusId, media, options) {
    dispatch(openModal('VIDEO', { statusId, media, options }));
  },

  onBlock (status) {
    const account = status.get('account');
    dispatch(initBlockModal(account));
  },

  onUnblock (account) {
    dispatch(unblockAccount(account.get('id')));
  },

  onReport (status) {
    dispatch(initReport(status.get('account'), status));
  },

  onMute (account) {
    dispatch(initMuteModal(account));
  },

  onUnmute (account) {
    dispatch(unmuteAccount(account.get('id')));
  },

  onMuteConversation (status) {
    if (status.get('muted')) {
      dispatch(unmuteStatus(status.get('id')));
    } else {
      dispatch(muteStatus(status.get('id')));
    }
  },

  onToggleHidden (status) {
    if (status.get('hidden')) {
      dispatch(revealStatus(status.get('id')));
    } else {
      dispatch(hideStatus(status.get('id')));
    }
  },

  onToggleCollapsed (status, isCollapsed) {
    dispatch(toggleStatusCollapse(status.get('id'), isCollapsed));
  },

  onBlockDomain (domain) {
    dispatch(openModal('CONFIRM', {
      message: <FormattedMessage id='confirmations.domain_block.message' defaultMessage='Are you really, really sure you want to block the entire {domain}? In most cases a few targeted blocks or mutes are sufficient and preferable. You will not see content from that domain in any public timelines or your notifications. Your followers from that domain will be removed.' values={{ domain: <strong>{domain}</strong> }} />,
      confirm: intl.formatMessage(messages.blockDomainConfirm),
      onConfirm: () => dispatch(blockDomain(domain)),
      passphrase: confirmDomainBlock && intl.formatMessage(messages.blockDomainPassphrase),
      destructive: true,
    }));
  },

  onUnblockDomain (domain) {
    dispatch(unblockDomain(domain));
  },

  deployPictureInPicture (status, type, mediaProps) {
    dispatch(deployPictureInPicture(status.get('id'), status.getIn(['account', 'id']), type, mediaProps));
  },

  onFollow (account) {
    if (account.getIn(['relationship', 'following']) || account.getIn(['relationship', 'requested'])) {
      if (unfollowModal) {
        dispatch(openModal('CONFIRM', {
          message: <FormattedMessage id='confirmations.unfollow.message' defaultMessage='Are you sure you want to unfollow {name}?' values={{ name: <strong>@{account.get('acct')}</strong> }} />,
          confirm: intl.formatMessage(messages.unfollowConfirm),
          onConfirm: () => dispatch(unfollowAccount(account.get('id'))),
        }));
      } else {
        dispatch(unfollowAccount(account.get('id')));
      }
    } else {
      if (followModal) {
        dispatch(openModal('CONFIRM', {
          message: <FormattedMessage id='confirmations.follow.message' defaultMessage='Are you sure you want to follow {name}?' values={{ name: <strong>@{account.get('acct')}</strong> }} />,
          confirm: intl.formatMessage(messages.followConfirm),
          onConfirm: () => dispatch(followAccount(account.get('id'))),
        }));
      } else {
        dispatch(followAccount(account.get('id')));
      }
    }
  },

  onSubscribe (account) {
    if (account.getIn(['relationship', 'subscribing', '-1'], new Map).size > 0) {
      if (unsubscribeModal) {
        dispatch(openModal('CONFIRM', {
          message: <FormattedMessage id='confirmations.unsubscribe.message' defaultMessage='Are you sure you want to unsubscribe {name}?' values={{ name: <strong>@{account.get('acct')}</strong> }} />,
          confirm: intl.formatMessage(messages.unsubscribeConfirm),
          onConfirm: () => dispatch(unsubscribeAccount(account.get('id'))),
        }));
      } else {
        dispatch(unsubscribeAccount(account.get('id')));
      }
    } else {
      if (subscribeModal) {
        dispatch(openModal('CONFIRM', {
          message: <FormattedMessage id='confirmations.subscribe.message' defaultMessage='Are you sure you want to subscribe {name}?' values={{ name: <strong>@{account.get('acct')}</strong> }} />,
          confirm: intl.formatMessage(messages.subscribeConfirm),
          onConfirm: () => dispatch(subscribeAccount(account.get('id'))),
        }));
      } else {
        dispatch(subscribeAccount(account.get('id')));
      }
    }
  },

  onAddToList (account){
    dispatch(openModal('LIST_ADDER', {
      accountId: account.get('id'),
    }));
  },

  addEmojiReaction (status, name, domain, url, static_url) {
    dispatch(addEmojiReaction(status, name, domain, url, static_url));
  },

  removeEmojiReaction (status, name) {
    dispatch(removeEmojiReaction(status, name));
  },

  onAddReference (id, change) {
    dispatch(addReference(id, change));
  },

  onRemoveReference (id) {
    dispatch(removeReference(id));
  },

});

export default injectIntl(connect(makeMapStateToProps, mapDispatchToProps, mergeProps)(Status));
