import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import IconButton from '../../../components/icon_button';
import ImmutablePropTypes from 'react-immutable-proptypes';
import DropdownMenuContainer from '../../../containers/dropdown_menu_container';
import { defineMessages, injectIntl } from 'react-intl';
import { me, isStaff, show_quote_button, show_share_button, enableReaction, enableStatusReference, maxReferences, matchVisibilityOfReferences, addReferenceModal, disablePost, disableReactions, disableBlock, disableDomainBlock, disableReport, hideListOfEmojiReactionsToPosts, hideListOfFavouritesToPosts, hideListOfReblogsToPosts, hideListOfReferredByToPosts } from '../../../initial_state';
import classNames from 'classnames';
import ReactionPickerDropdownContainer from 'mastodon/containers/reaction_picker_dropdown_container';
import { openModal } from '../../../actions/modal';

const messages = defineMessages({
  expire: { id: 'status.expire', defaultMessage: 'Expire' },
  delete: { id: 'status.delete', defaultMessage: 'Delete' },
  redraft: { id: 'status.redraft', defaultMessage: 'Delete & re-draft' },
  direct: { id: 'status.direct', defaultMessage: 'Direct message @{name}' },
  showMemberList: { id: 'status.show_member_list', defaultMessage: 'Show member list' },
  mention: { id: 'status.mention', defaultMessage: 'Mention @{name}' },
  reply: { id: 'status.reply', defaultMessage: 'Reply' },
  reference: { id: 'status.reference', defaultMessage: 'Reference' },
  reblog: { id: 'status.reblog', defaultMessage: 'Boost' },
  reblog_private: { id: 'status.reblog_private', defaultMessage: 'Boost with original visibility' },
  cancel_reblog_private: { id: 'status.cancel_reblog_private', defaultMessage: 'Unboost' },
  cannot_quote: { id: 'status.cannot_quote', defaultMessage: 'This post cannot be quoted' },
  cannot_reblog: { id: 'status.cannot_reblog', defaultMessage: 'This post cannot be boosted' },
  quote: { id: 'status.quote', defaultMessage: 'Quote' },
  favourite: { id: 'status.favourite', defaultMessage: 'Favourite' },
  bookmark: { id: 'status.bookmark', defaultMessage: 'Bookmark' },
  emoji_reaction: { id: 'status.emoji_reaction', defaultMessage: 'Emoji reaction' },
  emoji_reaction_disable: { id: 'status.emoji_reaction_disable', defaultMessage: 'Emoji reaction' },
  emoji_reaction_expired: { id: 'status.emoji_reaction_expired', defaultMessage: 'Emoji reaction' },
  emoji_reaction_limit_reatched: { id: 'status.emoji_reaction_limit_reatched', defaultMessage: 'Emoji reaction' },
  show_reblogs: { id: 'status.show_reblogs', defaultMessage: 'Show boosted users' },
  show_favourites: { id: 'status.show_favourites', defaultMessage: 'Show favourited users' },
  show_emoji_reactions: { id: 'status.show_emoji_reactions', defaultMessage: 'Show emoji reactioned users' },
  show_referred_by_statuses: { id: 'status.show_referred_by_statuses', defaultMessage: 'Show referred by statuses' },
  more: { id: 'status.more', defaultMessage: 'More' },
  mute: { id: 'status.mute', defaultMessage: 'Mute @{name}' },
  muteConversation: { id: 'status.mute_conversation', defaultMessage: 'Mute conversation' },
  unmuteConversation: { id: 'status.unmute_conversation', defaultMessage: 'Unmute conversation' },
  block: { id: 'status.block', defaultMessage: 'Block @{name}' },
  report: { id: 'status.report', defaultMessage: 'Report @{name}' },
  share: { id: 'status.share', defaultMessage: 'Share' },
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
class ActionBar extends React.PureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    status: ImmutablePropTypes.map.isRequired,
    dispatch: PropTypes.func.isRequired,
    referenced: PropTypes.bool,
    contextReferenced: PropTypes.bool,
    relationship: ImmutablePropTypes.map,
    referenceCountLimit: PropTypes.bool,
    selected: PropTypes.bool,
    composePrivacy: PropTypes.string,
    onReply: PropTypes.func.isRequired,
    onReblog: PropTypes.func.isRequired,
    onQuote: PropTypes.func.isRequired,
    onFavourite: PropTypes.func.isRequired,
    onBookmark: PropTypes.func.isRequired,
    onAddReference: PropTypes.func,
    onRemoveReference: PropTypes.func,
    onDelete: PropTypes.func.isRequired,
    onExpire: PropTypes.func.isRequired,
    onDirect: PropTypes.func.isRequired,
    onMemberList: PropTypes.func.isRequired,
    onMention: PropTypes.func.isRequired,
    onMute: PropTypes.func,
    onUnmute: PropTypes.func,
    onBlock: PropTypes.func,
    onUnblock: PropTypes.func,
    onBlockDomain: PropTypes.func,
    onUnblockDomain: PropTypes.func,
    onMuteConversation: PropTypes.func,
    onReport: PropTypes.func,
    onPin: PropTypes.func,
    onEmbed: PropTypes.func,
    intl: PropTypes.object.isRequired,
    addEmojiReaction: PropTypes.func.isRequired,
    removeEmojiReaction: PropTypes.func.isRequired,
    emojiReactioned: PropTypes.bool,
    reactionLimitReached: PropTypes.bool,
  };

  handleReplyClick = () => {
    this.props.onReply(this.props.status);
  }

  handleReblogClick = (e) => {
    this.props.onReblog(this.props.status, e);
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

  handleQuoteClick = () => {
    this.props.onQuote(this.props.status, this.context.router.history);
  }

  handleFavouriteClick = () => {
    this.props.onFavourite(this.props.status);
  }

  handleBookmarkClick = (e) => {
    this.props.onBookmark(this.props.status, e);
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

  handleDirectClick = () => {
    this.props.onDirect(this.props.status.get('account'), this.context.router.history);
  }

  handleMemberListClick = () => {
    this.props.onMemberList(this.props.status, this.context.router.history);
  }

  handleMentionClick = () => {
    this.props.onMention(this.props.status.get('account'), this.context.router.history);
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

  handleConversationMuteClick = () => {
    this.props.onMuteConversation(this.props.status);
  }

  handleReport = () => {
    this.props.onReport(this.props.status);
  }

  handlePinClick = () => {
    this.props.onPin(this.props.status);
  }

  handleShare = () => {
    navigator.share({
      text: this.props.status.get('search_index'),
      url: this.props.status.get('url'),
    });
  }

  handleEmbed = () => {
    this.props.onEmbed(this.props.status);
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
    const { status, relationship, intl, referenced, contextReferenced, referenceCountLimit, emojiReactioned, reactionLimitReached } = this.props;

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
    const [ , domain ]       = account.get('acct').split('@');

    const expires_at = status.get('expires_at');
    const expires_date = expires_at && new Date(expires_at);
    const expired = expires_date && expires_date.getTime() < intl.now();

    const showReblogCount = !hideListOfReblogsToPosts && reblogsCount > 0;
    const showFavouritCount = !hideListOfFavouritesToPosts && favouritesCount > 0;
    const showEmojiReactionCount = !hideListOfEmojiReactionsToPosts && enableReaction && !status.get('emoji_reactions').isEmpty();
    const showStatusReferredByCount = !hideListOfReferredByToPosts && enableStatusReference && referredByCount > 0;

    let menu = [];

    if (publicStatus && !expired) {
      menu.push({ text: intl.formatMessage(messages.copy), action: this.handleCopy });

      if (!domain) {
        menu.push({ text: intl.formatMessage(messages.embed), action: this.handleEmbed });
      }
    }

    if (showReblogCount || showFavouritCount || showEmojiReactionCount || showStatusReferredByCount) {
      menu.push(null);
    }

    if (showReblogCount) {
      menu.push({ text: intl.formatMessage(messages.show_reblogs), action: this.handleReblogs });
    }

    if (showFavouritCount) {
      menu.push({ text: intl.formatMessage(messages.show_favourites), action: this.handleFavourites });
    }

    if (showEmojiReactionCount) {
      menu.push({ text: intl.formatMessage(messages.show_emoji_reactions), action: this.handleEmojiReactions });
    }

    if (showStatusReferredByCount) {
      menu.push({ text: intl.formatMessage(messages.show_referred_by_statuses), action: this.handleReferredByStatuses });
    }

    if (domain) {
      menu.push(null);
      menu.push({ text: intl.formatMessage(messages.openDomainTimeline, { domain }), action: this.handleOpenDomainTimeline });
    }

    menu.push(null);

    if (writtenByMe) {
      if (pinnableStatus && !expired) {
        menu.push({ text: intl.formatMessage(status.get('pinned') ? messages.unpin : messages.pin), action: this.handlePinClick });
        menu.push(null);
      }

      if (limitedByMe) {
        menu.push({ text: intl.formatMessage(messages.showMemberList), action: this.handleMemberListClick });
        menu.push(null);
      }

      if (!expired) {
        menu.push({ text: intl.formatMessage(mutingConversation ? messages.unmuteConversation : messages.muteConversation), action: this.handleConversationMuteClick });
        menu.push(null);
      }

      menu.push({ text: intl.formatMessage(messages.expire), action: this.handleExpireClick });
      menu.push({ text: intl.formatMessage(messages.delete), action: this.handleDeleteClick });

      if (!disablePost) {
        menu.push({ text: intl.formatMessage(messages.redraft), action: this.handleRedraftClick });
      }
    } else {
      if (!disablePost) {
        menu.push({ text: intl.formatMessage(messages.mention, { name: status.getIn(['account', 'username']) }), action: this.handleMentionClick });
        menu.push({ text: intl.formatMessage(messages.direct, { name: status.getIn(['account', 'username']) }), action: this.handleDirectClick });
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

      if (!disableReport) {
        menu.push({ text: intl.formatMessage(messages.report, { name: status.getIn(['account', 'username']) }), action: this.handleReport });
      }

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
        menu.push({ text: intl.formatMessage(messages.admin_account, { name: status.getIn(['account', 'username']) }), href: `/admin/accounts/${status.getIn(['account', 'id'])}` });
        menu.push({ text: intl.formatMessage(messages.admin_status), href: `/admin/accounts/${status.getIn(['account', 'id'])}/statuses/${status.get('id')}` });
      }
    }

    const shareButton = ('share' in navigator) && show_share_button && publicStatus && (
      <div className='detailed-status__button'><IconButton disabled={expired} title={intl.formatMessage(messages.share)} icon='share-alt' onClick={this.handleShare} /></div>
    );

    let replyIcon;
    if (status.get('in_reply_to_id', null) === null) {
      replyIcon = 'reply';
    } else {
      replyIcon = 'reply-all';
    }

    const reblogPrivate = status.getIn(['account', 'id']) === me && status.get('visibility') === 'private';

    let reblogTitle;
    if (reblogged) {
      reblogTitle = intl.formatMessage(messages.cancel_reblog_private);
    } else if (publicStatus) {
      reblogTitle = intl.formatMessage(messages.reblog);
    } else if (reblogPrivate) {
      reblogTitle = intl.formatMessage(messages.reblog_private);
    } else {
      reblogTitle = intl.formatMessage(messages.cannot_reblog);
    }

    const referenceDisabled = expired || !referenced && referenceCountLimit || ['limited', 'direct', 'personal'].includes(status.get('visibility'));

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
      <div className='detailed-status__action-bar'>
        <div className='detailed-status__button'><IconButton disabled={disablePost || expired} title={intl.formatMessage(messages.reply)} icon={status.get('in_reply_to_account_id') === status.getIn(['account', 'id']) ? 'reply' : replyIcon} onClick={this.handleReplyClick} /></div>
        {enableStatusReference && me && <div className='detailed-status__button'><IconButton className={classNames('link-icon', { referenced, 'context-referenced': contextReferenced })} animate disabled={disablePost || referenceDisabled} active={referenced} pressed={referenced} title={intl.formatMessage(messages.reference)} icon='link' onClick={this.handleReferenceClick} /></div>}
        <div className='detailed-status__button'><IconButton className={classNames({ reblogPrivate })} disabled={disableReactions || !publicStatus && !reblogPrivate || expired} active={reblogged} title={reblogTitle} icon='retweet' onClick={this.handleReblogClick} /></div>
        <div className='detailed-status__button'><IconButton className='star-icon' animate active={favourited} disabled={disableReactions || !favourited && expired} title={intl.formatMessage(messages.favourite)} icon='star' onClick={this.handleFavouriteClick} /></div>
        {show_quote_button && <div className='detailed-status__button'><IconButton disabled={disablePost || !publicStatus || expired} title={!publicStatus ? intl.formatMessage(messages.cannot_quote) : intl.formatMessage(messages.quote)} icon='quote-right' onClick={this.handleQuoteClick} /></div>}
        {shareButton}
        <div className='detailed-status__button'><IconButton className='bookmark-icon' active={bookmarked} disabled={!bookmarked && expired} title={intl.formatMessage(messages.bookmark)} icon='bookmark' onClick={this.handleBookmarkClick} /></div>

        {enableReaction && <div className='detailed-status__action-bar-dropdown'>
          <ReactionPickerDropdownContainer
            disabled={disableReactions || expired || reactionLimitReached}
            active={emojiReactioned}
            className='status__action-bar-button'
            status={status}
            title={emojiReactionMessage}
            icon='smile-o'
            size={18}
            direction='right'
            onPickEmoji={this.handleEmojiPick}
            onRemoveEmoji={this.handleEmojiRemove}
            reactionLimitReached={reactionLimitReached}
          />
        </div>}

        <div className='detailed-status__action-bar-dropdown'>
          <DropdownMenuContainer size={18} icon='ellipsis-h' status={status} items={menu} direction='left' title={intl.formatMessage(messages.more)} />
        </div>
      </div>
    );
  }

}
