import React from 'react';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { connect } from 'react-redux';
import PropTypes from 'prop-types';
import IconButton from './icon_button';
import DropdownMenuContainer from '../containers/dropdown_menu_container';
import { defineMessages, injectIntl } from 'react-intl';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { me, isStaff, show_bookmark_button, show_quote_button, show_share_button, enableReaction, compactReaction, enableStatusReference, maxReferences, matchVisibilityOfReferences, addReferenceModal, disablePost, disableReactions, disableBlock, disableDomainBlock } from '../initial_state';
import classNames from 'classnames';
import { openModal } from '../actions/modal';

import ReactionPickerDropdownContainer from '../containers/reaction_picker_dropdown_container';

const messages = defineMessages({
  expire: { id: 'status.expire', defaultMessage: 'Expire' },
  delete: { id: 'status.delete', defaultMessage: 'Delete' },
  redraft: { id: 'status.redraft', defaultMessage: 'Delete & re-draft' },
  direct: { id: 'status.direct', defaultMessage: 'Direct message @{name}' },
  showMemberList: { id: 'status.show_member_list', defaultMessage: 'Show member list' },
  mention: { id: 'status.mention', defaultMessage: 'Mention @{name}' },
  mute: { id: 'account.mute', defaultMessage: 'Mute @{name}' },
  block: { id: 'account.block', defaultMessage: 'Block @{name}' },
  reply: { id: 'status.reply', defaultMessage: 'Reply' },
  share: { id: 'status.share', defaultMessage: 'Share' },
  more: { id: 'status.more', defaultMessage: 'More' },
  replyAll: { id: 'status.replyAll', defaultMessage: 'Reply to thread' },
  reference: { id: 'status.reference', defaultMessage: 'Reference' },
  reblog: { id: 'status.reblog', defaultMessage: 'Boost' },
  reblog_private: { id: 'status.reblog_private', defaultMessage: 'Boost with original visibility' },
  cancel_reblog_private: { id: 'status.cancel_reblog_private', defaultMessage: 'Unboost' },
  cannot_quote: { id: 'status.cannot_quote', defaultMessage: 'This post cannot be quoted' },
  cannot_reblog: { id: 'status.cannot_reblog', defaultMessage: 'This post cannot be boosted' },
  quote: { id: 'status.quote', defaultMessage: 'Quote' },
  favourite: { id: 'status.favourite', defaultMessage: 'Favourite' },
  bookmark: { id: 'status.bookmark', defaultMessage: 'Bookmark' },
  removeBookmark: { id: 'status.remove_bookmark', defaultMessage: 'Remove bookmark' },
  emoji_reaction: { id: 'status.emoji_reaction', defaultMessage: 'Emoji reaction' },
  emoji_reaction_disable: { id: 'status.emoji_reaction_disable', defaultMessage: 'Emoji reaction' },
  emoji_reaction_expired: { id: 'status.emoji_reaction_expired', defaultMessage: 'Emoji reaction' },
  emoji_reaction_limit_reatched: { id: 'status.emoji_reaction_limit_reatched', defaultMessage: 'Emoji reaction' },
  open: { id: 'status.open', defaultMessage: 'Expand this status' },
  show_reblogs: { id: 'status.show_reblogs', defaultMessage: 'Show boosted users' },
  show_favourites: { id: 'status.show_favourites', defaultMessage: 'Show favourited users' },
  show_emoji_reactions: { id: 'status.show_emoji_reactions', defaultMessage: 'Show emoji reactioned users' },
  show_referred_by_statuses: { id: 'status.show_referred_by_statuses', defaultMessage: 'Show referred by statuses' },
  report: { id: 'status.report', defaultMessage: 'Report @{name}' },
  muteConversation: { id: 'status.mute_conversation', defaultMessage: 'Mute conversation' },
  unmuteConversation: { id: 'status.unmute_conversation', defaultMessage: 'Unmute conversation' },
  pin: { id: 'status.pin', defaultMessage: 'Pin on profile' },
  unpin: { id: 'status.unpin', defaultMessage: 'Unpin from profile' },
  embed: { id: 'status.embed', defaultMessage: 'Embed' },
  admin_account: { id: 'status.admin_account', defaultMessage: 'Open moderation interface for @{name}' },
  admin_status: { id: 'status.admin_status', defaultMessage: 'Open this status in the moderation interface' },
  copy: { id: 'status.copy', defaultMessage: 'Copy link to status' },
  blockDomain: { id: 'account.block_domain', defaultMessage: 'Block domain {domain}' },
  unblockDomain: { id: 'account.unblock_domain', defaultMessage: 'Unblock domain {domain}' },
  openDomainTimeline: { id: 'account.open_domain_timeline', defaultMessage: 'Open {domain} timeline' },
  unmute: { id: 'account.unmute', defaultMessage: 'Unmute @{name}' },
  unblock: { id: 'account.unblock', defaultMessage: 'Unblock @{name}' },
  visibilityMatchMessage: { id: 'visibility.match_message', defaultMessage: 'Do you want to match the visibility of the post to the reference?' },
  visibilityKeepMessage: { id: 'visibility.keep_message', defaultMessage: 'Do you want to keep the visibility of the post to the reference?' },
  visibilityChange: { id: 'visibility.change', defaultMessage: 'Change' },
  visibilityKeep: { id: 'visibility.keep', defaultMessage: 'Keep' },
});

const mapStateToProps = (state, { status }) => ({
  relationship: state.getIn(['relationships', status.getIn(['account', 'id'])]),
  referenceCountLimit: state.getIn(['compose', 'references']).size >= maxReferences,
  selected: state.getIn(['compose', 'references']).has(status.get('id')),
  composePrivacy: state.getIn(['compose', 'privacy']),
});

export default @connect(mapStateToProps)
@injectIntl
class StatusActionBar extends ImmutablePureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    status: ImmutablePropTypes.map.isRequired,
    expired: PropTypes.bool,
    referenced: PropTypes.bool,
    contextReferenced: PropTypes.bool,
    relationship: ImmutablePropTypes.map,
    referenceCountLimit: PropTypes.bool,
    selected: PropTypes.bool,
    composePrivacy: PropTypes.string,
    contextType: PropTypes.string,
    onReply: PropTypes.func,
    onFavourite: PropTypes.func,
    onReblog: PropTypes.func,
    onQuote: PropTypes.func,
    onDelete: PropTypes.func,
    onExpire: PropTypes.func,
    onDirect: PropTypes.func,
    onMemberList: PropTypes.func,
    onMention: PropTypes.func,
    onMute: PropTypes.func,
    onUnmute: PropTypes.func,
    onBlock: PropTypes.func,
    onUnblock: PropTypes.func,
    onBlockDomain: PropTypes.func,
    onUnblockDomain: PropTypes.func,
    onReport: PropTypes.func,
    onEmbed: PropTypes.func,
    onMuteConversation: PropTypes.func,
    onPin: PropTypes.func,
    onBookmark: PropTypes.func,
    onAddReference: PropTypes.func,
    onRemoveReference: PropTypes.func,
    withDismiss: PropTypes.bool,
    scrollKey: PropTypes.string,
    intl: PropTypes.object.isRequired,
    addEmojiReaction: PropTypes.func,
    removeEmojiReaction: PropTypes.func,
    emojiReactioned: PropTypes.bool,
    reactionLimitReached: PropTypes.bool,
  };

  static defaultProps = {
    expired: false,
  };

  // Avoid checking props that are functions (and whose equality will always
  // evaluate to false. See react-immutable-pure-component for usage.
  updateOnProps = [
    'status',
    'relationship',
    'withDismiss',
    'referenced',
    'contextReferenced',
    'referenceCountLimit',
  ]

  handleReplyClick = () => {
    if (me) {
      this.props.onReply(this.props.status, this.context.router.history);
    } else {
      this._openInteractionDialog('reply');
    }
  }

  handleShareClick = () => {
    navigator.share({
      text: this.props.status.get('search_index'),
      url: this.props.status.get('url'),
    }).catch((e) => {
      if (e.name !== 'AbortError') console.error(e);
    });
  }

  handleFavouriteClick = () => {
    if (me) {
      this.props.onFavourite(this.props.status);
    } else {
      this._openInteractionDialog('favourite');
    }
  }

  handleReblogClick = e => {
    if (me) {
      this.props.onReblog(this.props.status, e);
    } else {
      this._openInteractionDialog('reblog');
    }
  }

  handleReferenceClick = (e) => {
    const { dispatch, intl, status, selected, composePrivacy, onAddReference, onRemoveReference } = this.props;
    const id = status.get('id');

    if (selected) {
      onRemoveReference(id);
    } else {
      if (status.get('visibility') === 'private' && ['public', 'unlisted'].includes(composePrivacy)) {
        if (!addReferenceModal || e && e.shiftKey) {
          onAddReference(id, true);
        } else {
          dispatch(openModal('CONFIRM', {
            message: intl.formatMessage(matchVisibilityOfReferences ? messages.visibilityMatchMessage : messages.visibilityKeepMessage),
            confirm: intl.formatMessage(matchVisibilityOfReferences ? messages.visibilityChange : messages.visibilityKeep),
            onConfirm:   () => onAddReference(id, matchVisibilityOfReferences),
            secondary: intl.formatMessage(matchVisibilityOfReferences ? messages.visibilityKeep : messages.visibilityChange),
            onSecondary: () => onAddReference(id, !matchVisibilityOfReferences),
          }));
        }
      } else {
        onAddReference(id, true);
      }
    }
  }

  _openInteractionDialog = type => {
    window.open(`/interact/${this.props.status.get('id')}?type=${type}`, 'mastodon-intent', 'width=445,height=600,resizable=no,menubar=no,status=no,scrollbars=yes');
  }

  handleBookmarkClick = () => {
    this.props.onBookmark(this.props.status);
  }

  handleQuoteClick = () => {
    this.props.onQuote(this.props.status, this.context.router.history);
  }

  handleDeleteClick = () => {
    this.props.onDelete(this.props.status, this.context.router.history);
  }

  handleRedraftClick = () => {
    this.props.onDelete(this.props.status, this.context.router.history, true);
  }

  handleExpireClick = () => {
    this.props.onExpire(this.props.status);
  }

  handlePinClick = () => {
    this.props.onPin(this.props.status);
  }

  handleMentionClick = () => {
    this.props.onMention(this.props.status.get('account'), this.context.router.history);
  }

  handleDirectClick = () => {
    this.props.onDirect(this.props.status.get('account'), this.context.router.history);
  }

  handleMemberListClick = () => {
    this.props.onMemberList(this.props.status, this.context.router.history);
  }

  handleMuteClick = () => {
    const { status, relationship, onMute, onUnmute } = this.props;
    const account = status.get('account');

    if (relationship && relationship.get('muting')) {
      onUnmute(account);
    } else {
      onMute(account);
    }
  }

  handleBlockClick = () => {
    const { status, relationship, onBlock, onUnblock } = this.props;
    const account = status.get('account');

    if (relationship && relationship.get('blocking')) {
      onUnblock(account);
    } else {
      onBlock(status);
    }
  }

  handleBlockDomain = () => {
    const { status, onBlockDomain } = this.props;
    const account = status.get('account');

    onBlockDomain(account.get('acct').split('@')[1]);
  }

  handleUnblockDomain = () => {
    const { status, onUnblockDomain } = this.props;
    const account = status.get('account');

    onUnblockDomain(account.get('acct').split('@')[1]);
  }

  handleOpenDomainTimeline = () => {
    const { status } = this.props;
    const account = status.get('account');

    this.context.router.history.push(`/timelines/public/domain/${account.get('acct').split('@')[1]}`);
  }

  handleOpen = () => {
    this.context.router.history.push(`/statuses/${this.props.status.get('id')}`);
  }

  handleEmbed = () => {
    this.props.onEmbed(this.props.status);
  }

  handleReport = () => {
    this.props.onReport(this.props.status);
  }

  handleConversationMuteClick = () => {
    this.props.onMuteConversation(this.props.status);
  }

  handleCopy = () => {
    const url      = this.props.status.get('url');
    const textarea = document.createElement('textarea');

    textarea.textContent    = url;
    textarea.style.position = 'fixed';

    document.body.appendChild(textarea);

    try {
      textarea.select();
      document.execCommand('copy');
    } catch (e) {

    } finally {
      document.body.removeChild(textarea);
    }
  }

  handleReblogs = () => {
    this.context.router.history.push(`/statuses/${this.props.status.get('id')}/reblogs`);
  }

  handleFavourites = () => {
    this.context.router.history.push(`/statuses/${this.props.status.get('id')}/favourites`);
  }

  handleEmojiReactions = () => {
    this.context.router.history.push(`/statuses/${this.props.status.get('id')}/emoji_reactions`);
  }

  handleReferredByStatuses = () => {
    this.context.router.history.push(`/statuses/${this.props.status.get('id')}/referred_by`);
  }

  handleEmojiPick = data => {
    const { addEmojiReaction, status } = this.props;
    addEmojiReaction(status, data.native.replace(/:/g, ''), null, null, null);
  }

  handleEmojiRemove = () => {
    const { removeEmojiReaction, status } = this.props;
    removeEmojiReaction(status);
  }

  render () {
    const { status, relationship, intl, withDismiss, scrollKey, expired, referenced, contextReferenced, referenceCountLimit, contextType, emojiReactioned, reactionLimitReached } = this.props;

    const anonymousAccess    = !me;
    const publicStatus       = ['public', 'unlisted'].includes(status.get('visibility'));
    const pinnableStatus     = ['public', 'unlisted', 'private'].includes(status.get('visibility'));
    const mutingConversation = status.get('muted');
    const account            = status.get('account');
    const writtenByMe        = status.getIn(['account', 'id']) === me;
    const limitedByMe        = status.get('visibility') === 'limited' && status.get('circle_id');
    const reblogged          = status.get('reblogged');
    const favourited         = status.get('favourited');
    const bookmarked         = status.get('bookmarked');
    const reblogsCount       = status.get('reblogs_count');
    const referredByCount    = status.get('status_referred_by_count');
    const favouritesCount    = status.get('favourites_count');
    const [ _, domain ]      = account.get('acct').split('@');

    let menu = [];

    menu.push({ text: intl.formatMessage(messages.open), action: this.handleOpen });

    if (publicStatus && !expired) {
      menu.push({ text: intl.formatMessage(messages.copy), action: this.handleCopy });

      if (!domain) {
        menu.push({ text: intl.formatMessage(messages.embed), action: this.handleEmbed });
      }
    }

    if (reblogsCount > 0 || favouritesCount > 0 || !status.get('emoji_reactions').isEmpty()) {
      menu.push(null);
    }

    if (reblogsCount > 0) {
      menu.push({ text: intl.formatMessage(messages.show_reblogs), action: this.handleReblogs });
    }

    if (favouritesCount > 0) {
      menu.push({ text: intl.formatMessage(messages.show_favourites), action: this.handleFavourites });
    }

    if (!status.get('emoji_reactions').isEmpty()) {
      menu.push({ text: intl.formatMessage(messages.show_emoji_reactions), action: this.handleEmojiReactions });
    }

    if (enableStatusReference && referredByCount > 0) {
      menu.push({ text: intl.formatMessage(messages.show_referred_by_statuses), action: this.handleReferredByStatuses });
    }

    if (domain) {
      menu.push(null);
      menu.push({ text: intl.formatMessage(messages.openDomainTimeline, { domain }), action: this.handleOpenDomainTimeline });
    }

    menu.push(null);

    if (!show_bookmark_button) {
      menu.push({ text: intl.formatMessage(bookmarked ? messages.removeBookmark : messages.bookmark), action: this.handleBookmarkClick });
    }

    if (writtenByMe && pinnableStatus && !expired) {
      menu.push({ text: intl.formatMessage(status.get('pinned') ? messages.unpin : messages.pin), action: this.handlePinClick });
    }

    if (!show_bookmark_button || writtenByMe && publicStatus && !expired) {
      menu.push(null);
    }

    if (writtenByMe && limitedByMe) {
      menu.push({ text: intl.formatMessage(messages.showMemberList), action: this.handleMemberListClick });
      menu.push(null);
    }

    if ((writtenByMe || withDismiss) && !expired) {
      menu.push({ text: intl.formatMessage(mutingConversation ? messages.unmuteConversation : messages.muteConversation), action: this.handleConversationMuteClick });
      menu.push(null);
    }

    if (writtenByMe) {
      menu.push({ text: intl.formatMessage(messages.expire), action: this.handleExpireClick });
      menu.push({ text: intl.formatMessage(messages.delete), action: this.handleDeleteClick });
      if (!disablePost) {
        menu.push({ text: intl.formatMessage(messages.redraft), action: this.handleRedraftClick });
      }
    } else {
      if (!disablePost) {
        menu.push({ text: intl.formatMessage(messages.mention, { name: account.get('username') }), action: this.handleMentionClick });
        menu.push({ text: intl.formatMessage(messages.direct, { name: account.get('username') }), action: this.handleDirectClick });
        menu.push(null);
      }

      if (relationship && relationship.get('muting')) {
        menu.push({ text: intl.formatMessage(messages.unmute, { name: account.get('username') }), action: this.handleMuteClick });
      } else {
        menu.push({ text: intl.formatMessage(messages.mute, { name: account.get('username') }), action: this.handleMuteClick });
      }

      if (relationship && relationship.get('blocking')) {
        menu.push({ text: intl.formatMessage(messages.unblock, { name: account.get('username') }), action: this.handleBlockClick });
      } else if (!disableBlock) {
        menu.push({ text: intl.formatMessage(messages.block, { name: account.get('username') }), action: this.handleBlockClick });
      }

      menu.push({ text: intl.formatMessage(messages.report, { name: account.get('username') }), action: this.handleReport });

      if (domain) {
        if (relationship && relationship.get('domain_blocking')) {
          menu.push(null);
          menu.push({ text: intl.formatMessage(messages.unblockDomain, { domain }), action: this.handleUnblockDomain });
        } else if (!disableDomainBlock) {
          menu.push(null);
          menu.push({ text: intl.formatMessage(messages.blockDomain, { domain }), action: this.handleBlockDomain });
        }
      }

      if (isStaff) {
        menu.push(null);
        menu.push({ text: intl.formatMessage(messages.admin_account, { name: account.get('username') }), href: `/admin/accounts/${status.getIn(['account', 'id'])}` });
        menu.push({ text: intl.formatMessage(messages.admin_status), href: `/admin/accounts/${status.getIn(['account', 'id'])}/statuses/${status.get('id')}` });
      }
    }

    let replyIcon;
    let replyTitle;
    if (status.get('in_reply_to_id', null) === null) {
      replyIcon = 'reply';
      replyTitle = intl.formatMessage(messages.reply);
    } else {
      replyIcon = 'reply-all';
      replyTitle = intl.formatMessage(messages.replyAll);
    }

    const reblogPrivate = status.getIn(['account', 'id']) === me && status.get('visibility') === 'private';

    let reblogTitle = '';
    if (reblogged) {
      reblogTitle = intl.formatMessage(messages.cancel_reblog_private);
    } else if (publicStatus) {
      reblogTitle = intl.formatMessage(messages.reblog);
    } else if (reblogPrivate) {
      reblogTitle = intl.formatMessage(messages.reblog_private);
    } else {
      reblogTitle = intl.formatMessage(messages.cannot_reblog);
    }

    const shareButton = ('share' in navigator) && show_share_button && publicStatus && (
      <IconButton className='status__action-bar-button' disabled={expired} title={intl.formatMessage(messages.share)} icon='share-alt' onClick={this.handleShareClick} />
    );

    const referenceDisabled = expired || !referenced && referenceCountLimit || ['limited', 'direct', 'personal'].includes(status.get('visibility'));

    const reactionsCounter = compactReaction && contextType !== 'thread' && status.get('emoji_reactions_count') > 0 ? status.get('emoji_reactions_count') : undefined;

    const emojiReactionMessage = (() => {
      if (disableReactions) {
        return intl.formatMessage(messages.emoji_reaction_disable);
      } else if (expired) {
        return intl.formatMessage(messages.emoji_reaction_expired);
      } else if (reactionLimitReached) {
        return intl.formatMessage(messages.emoji_reaction_limit_reatched);
      } else {
        return intl.formatMessage(messages.emoji_reaction);
      }
    })();

    return (
      <div className='status__action-bar'>
        <IconButton className='status__action-bar-button' disabled={disablePost || expired} title={replyTitle} icon={status.get('in_reply_to_account_id') === status.getIn(['account', 'id']) ? 'reply' : replyIcon} onClick={this.handleReplyClick} counter={status.get('replies_count')} obfuscateCount />
        {enableStatusReference && me && <IconButton className={classNames('status__action-bar-button link-icon', { referenced, 'context-referenced': contextReferenced })} animate disabled={disablePost || referenceDisabled} active={referenced} pressed={referenced} title={intl.formatMessage(messages.reference)} icon='link' onClick={this.handleReferenceClick} />}
        <IconButton className={classNames('status__action-bar-button', { reblogPrivate })} disabled={disableReactions || !publicStatus && !reblogPrivate || expired}  active={reblogged} pressed={reblogged} title={reblogTitle} icon='retweet' onClick={this.handleReblogClick} />
        <IconButton className='status__action-bar-button star-icon' animate disabled={disableReactions || !favourited && expired} active={favourited} pressed={favourited} title={intl.formatMessage(messages.favourite)} icon='star' onClick={this.handleFavouriteClick} />
        {show_quote_button && <IconButton className='status__action-bar-button' disabled={disablePost || anonymousAccess || !publicStatus || expired} title={!publicStatus ? intl.formatMessage(messages.cannot_quote) : intl.formatMessage(messages.quote)} icon='quote-right' onClick={this.handleQuoteClick} />}
        {shareButton}
        {show_bookmark_button && <IconButton className='status__action-bar-button bookmark-icon' disabled={!bookmarked && expired} active={bookmarked} pressed={bookmarked} title={intl.formatMessage(bookmarked ? messages.removeBookmark : messages.bookmark)} icon='bookmark' onClick={this.handleBookmarkClick} />}

        {enableReaction && <div className={classNames('status__action-bar-dropdown', { 'icon-button--with-counter': reactionsCounter })}>
          <ReactionPickerDropdownContainer
            scrollKey={scrollKey}
            disabled={disableReactions || expired || anonymousAccess || reactionLimitReached}
            active={emojiReactioned}
            className='status__action-bar-button'
            status={status}
            title={emojiReactionMessage}
            icon='smile-o'
            size={18}
            direction='right'
            counter={reactionsCounter}
            onPickEmoji={this.handleEmojiPick}
            onRemoveEmoji={this.handleEmojiRemove}
            reactionLimitReached={reactionLimitReached}
          />
        </div>}

        <div className='status__action-bar-dropdown'>
          <DropdownMenuContainer
            scrollKey={scrollKey}
            disabled={anonymousAccess}
            status={status}
            items={menu}
            icon='ellipsis-h'
            size={18}
            direction='right'
            title={intl.formatMessage(messages.more)}
          />
        </div>
      </div>
    );
  }

}
