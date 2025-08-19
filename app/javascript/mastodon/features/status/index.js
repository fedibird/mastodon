import React from 'react';
import { connect } from 'react-redux';
import PropTypes from 'prop-types';
import classNames from 'classnames';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { List as ImmutableList } from 'immutable';
import { createSelector } from 'reselect';
import { fetchStatus } from '../../actions/statuses';
import MissingIndicator from '../../components/missing_indicator';
import DetailedStatus from './components/detailed_status';
import ActionBar from './components/action_bar';
import Column from '../ui/components/column';
import {
  favourite,
  unfavourite,
  bookmark,
  unbookmark,
  reblog,
  unreblog,
  pin,
  unpin,
  addEmojiReaction,
  removeEmojiReaction,
} from '../../actions/interactions';
import {
  replyCompose,
  quoteCompose,
  mentionCompose,
  directCompose,
  addReference,
  removeReference,
} from '../../actions/compose';
import {
  muteStatus,
  unmuteStatus,
  deleteStatus,
  expireStatus,
  hideStatus,
  revealStatus,
} from '../../actions/statuses';
import {
  unblockAccount,
  unmuteAccount,
} from '../../actions/accounts';
import {
  blockDomain,
  unblockDomain,
} from '../../actions/domain_blocks';
import { initMuteModal } from '../../actions/mutes';
import { initBlockModal } from '../../actions/blocks';
import { initBoostModal } from '../../actions/boosts';
import { initReport } from '../../actions/reports';
import { makeGetStatus, makeGetPictureInPicture } from '../../selectors';
import ScrollContainer from 'mastodon/containers/scroll_container';
import ColumnBackButton from '../../components/column_back_button';
import ColumnHeader from '../../components/column_header';
import StatusContainer from '../../containers/status_container';
import { openModal } from '../../actions/modal';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { HotKeys } from 'react-hotkeys';
import { boostModal, deleteModal, confirmDomainBlock, enableStatusReference } from '../../initial_state';
import { attachFullscreenListener, detachFullscreenListener, isFullscreen } from '../ui/util/fullscreen';
import { textForScreenReader, defaultMediaVisibility } from '../../components/status';
import Icon from 'mastodon/components/icon';
import DetailedHeaderContaier from './containers/header_container';
import { defaultColumnWidth, me, maxReactionsPerAccount } from 'mastodon/initial_state';
import { changeSetting } from '../../actions/settings';
import { changeColumnParams } from '../../actions/columns';

const messages = defineMessages({
  deleteConfirm: { id: 'confirmations.delete.confirm', defaultMessage: 'Delete' },
  deleteMessage: { id: 'confirmations.delete.message', defaultMessage: 'Are you sure you want to delete this status?' },
  redraftConfirm: { id: 'confirmations.redraft.confirm', defaultMessage: 'Delete & redraft' },
  redraftMessage: { id: 'confirmations.redraft.message', defaultMessage: 'Are you sure you want to delete this status and re-draft it? Favourites and boosts will be lost, and replies to the original post will be orphaned.' },
  expireConfirm: { id: 'confirmations.expire.confirm', defaultMessage: 'Expire' },
  expireMessage: { id: 'confirmations.expire.message', defaultMessage: 'Are you sure you want to expire this status?' },
  revealAll: { id: 'status.show_more_all', defaultMessage: 'Show more for all' },
  hideAll: { id: 'status.show_less_all', defaultMessage: 'Show less for all' },
  detailedStatus: { id: 'status.detailed_status', defaultMessage: 'Detailed conversation view' },
  replyConfirm: { id: 'confirmations.reply.confirm', defaultMessage: 'Reply' },
  replyMessage: { id: 'confirmations.reply.message', defaultMessage: 'Replying now will overwrite the message you are currently composing. Are you sure you want to proceed?' },
  quoteConfirm: { id: 'confirmations.quote.confirm', defaultMessage: 'Quote' },
  quoteMessage: { id: 'confirmations.quote.message', defaultMessage: 'Quoting now will overwrite the message you are currently composing. Are you sure you want to proceed?' },
  blockDomainConfirm: { id: 'confirmations.domain_block.confirm', defaultMessage: 'Hide entire domain' },
  blockDomainPassphrase: { id: 'confirmations.domain_block.passphrase', defaultMessage: 'block' },
});

const makeMapStateToProps = () => {
  const getStatus = makeGetStatus();
  const getPictureInPicture = makeGetPictureInPicture();
  const getProper = (status) => status.get('reblog', null) !== null && typeof status.get('reblog') === 'object' ? status.get('reblog') : status;

  const getAncestorsIds = createSelector([
    (_, { id }) => id,
    state => state.getIn(['contexts', 'inReplyTos']),
  ], (statusId, inReplyTos) => {
    let ancestorsIds = ImmutableList();
    ancestorsIds = ancestorsIds.withMutations(mutable => {
      let id = statusId;

      while (id) {
        mutable.unshift(id);
        id = inReplyTos.get(id);
      }
    });

    return ancestorsIds;
  });

  const getDescendantsIds = createSelector([
    (_, { id }) => id,
    state => state.getIn(['contexts', 'replies']),
    state => state.get('statuses'),
  ], (statusId, contextReplies, statuses) => {
    let descendantsIds = [];
    const ids = [statusId];

    while (ids.length > 0) {
      let id        = ids.shift();
      const replies = contextReplies.get(id);

      if (statusId !== id) {
        descendantsIds.push(id);
      }

      if (replies) {
        replies.reverse().forEach(reply => {
          ids.unshift(reply);
        });
      }
    }

    let insertAt = descendantsIds.findIndex((id) => statuses.get(id).get('in_reply_to_account_id') !== statuses.get(id).get('account'));
    if (insertAt !== -1) {
      descendantsIds.forEach((id, idx) => {
        if (idx > insertAt && statuses.get(id).get('in_reply_to_account_id') === statuses.get(id).get('account')) {
          descendantsIds.splice(idx, 1);
          descendantsIds.splice(insertAt, 0, id);
          insertAt += 1;
        }
      });
    }

    return ImmutableList(descendantsIds);
  });

  const getReferencesIds = createSelector([
    (_, { id }) => id,
    state => state.getIn(['contexts', 'references']),
  ], (statusId, contextReference) => {
    return ImmutableList(contextReference.get(statusId));
  });

  const mapStateToProps = (state, { columnId, params }) => {
    const uuid = columnId;
    const columns = state.getIn(['settings', 'columns']);
    const index = columns.findIndex(c => c.get('uuid') === uuid);
    const columnWidth = (columnId && index >= 0) ? columns.get(index).getIn(['params', 'columnWidth']) : state.getIn(['settings', 'status', 'columnWidth']);
    const status         = getStatus(state, { id: params.statusId });
    const ancestorsIds   = status ? getAncestorsIds(state, { id: status.get('in_reply_to_id') }) : ImmutableList();
    const descendantsIds = status ? getDescendantsIds(state, { id: status.get('id') }) : ImmutableList();
    const referencesIds  = status ? getReferencesIds(state, { id: status.get('id') }) : ImmutableList();
    const id             = status ? getProper(status).get('id') : null;
    const emojiReactions = status ? status.get('emoji_reactions', ImmutableList()) : ImmutableList();
    const myCount        = emojiReactions.count((emojiReaction) => emojiReaction.get('account_ids', ImmutableList()).includes(me));

    return {
      status,
      ancestorsIds: ancestorsIds.concat(referencesIds).sortBy(id => id),
      descendantsIds,
      askReplyConfirmation: state.getIn(['compose', 'text']).trim().length !== 0,
      domain: state.getIn(['meta', 'domain']),
      pictureInPicture: getPictureInPicture(state, { id: params.statusId }),
      referenced: state.getIn(['compose', 'references']).has(id),
      contextReferenced: state.getIn(['compose', 'context_references']).has(id),
      columnWidth: columnWidth ?? defaultColumnWidth,
      emojiReactioned: myCount > 0,
      reactionLimitReached: myCount >= maxReactionsPerAccount,
    };
  };

  return mapStateToProps;
};

class Status extends ImmutablePureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    params: PropTypes.object.isRequired,
    dispatch: PropTypes.func.isRequired,
    status: ImmutablePropTypes.map,
    ancestorsIds: ImmutablePropTypes.list,
    descendantsIds: ImmutablePropTypes.list,
    referenced: PropTypes.bool,
    contextReferenced: PropTypes.bool,
    intl: PropTypes.object.isRequired,
    askReplyConfirmation: PropTypes.bool,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
    domain: PropTypes.string.isRequired,
    pictureInPicture: ImmutablePropTypes.contains({
      inUse: PropTypes.bool,
      available: PropTypes.bool,
    }),
    emojiReactioned: PropTypes.bool,
    reactionLimitReached: PropTypes.bool,
  };

  state = {
    fullscreen: false,
    showMedia: defaultMediaVisibility(this.props.status),
    showQuoteMedia: defaultMediaVisibility(this.props.status ? this.props.status.get('quote', null) : null),
    loadedStatusId: undefined,
  };

  componentWillMount () {
    this.props.dispatch(fetchStatus(this.props.params.statusId));
  }

  componentDidMount () {
    attachFullscreenListener(this.onFullScreenChange);
  }

  componentWillReceiveProps (nextProps) {
    if (nextProps.params.statusId !== this.props.params.statusId && nextProps.params.statusId) {
      this._scrolledIntoView = false;
      this.props.dispatch(fetchStatus(nextProps.params.statusId));
    }

    if (nextProps.status && nextProps.status.get('id') !== this.state.loadedStatusId) {
      this.setState({ showMedia: defaultMediaVisibility(nextProps.status), loadedStatusId: nextProps.status.get('id'),
        showQuoteMedia: defaultMediaVisibility(nextProps.status.get('quote', null)) });
    }
  }

  handleToggleMediaVisibility = () => {
    this.setState({ showMedia: !this.state.showMedia });
  }

  handleToggleQuoteMediaVisibility = () => {
    this.setState({ showQuoteMedia: !this.state.showQuoteMedia });
  }

  handleFavouriteClick = (status) => {
    if (status.get('favourited')) {
      this.props.dispatch(unfavourite(status));
    } else {
      this.props.dispatch(favourite(status));
    }
  }

  handlePin = (status) => {
    if (status.get('pinned')) {
      this.props.dispatch(unpin(status));
    } else {
      this.props.dispatch(pin(status));
    }
  }

  handleReplyClick = (status) => {
    let { askReplyConfirmation, dispatch, intl } = this.props;
    if (askReplyConfirmation) {
      dispatch(openModal('CONFIRM', {
        message: intl.formatMessage(messages.replyMessage),
        confirm: intl.formatMessage(messages.replyConfirm),
        onConfirm: () => dispatch(replyCompose(status, this.context.router.history)),
      }));
    } else {
      dispatch(replyCompose(status, this.context.router.history));
    }
  }

  handleModalReblog = (status, privacy) => {
    this.props.dispatch(reblog(status, privacy));
  }

  handleReblogClick = (status, e) => {
    if (status.get('reblogged')) {
      this.props.dispatch(unreblog(status));
    } else {
      if ((e && e.shiftKey) ^ !boostModal) {
        this.handleModalReblog(status);
      } else {
        this.props.dispatch(initBoostModal({ status, onReblog: this.handleModalReblog }));
      }
    }
  }

  handleBookmarkClick = (status) => {
    if (status.get('bookmarked')) {
      this.props.dispatch(unbookmark(status));
    } else {
      this.props.dispatch(bookmark(status));
    }
  }

  handleQuoteClick = (status) => {
    let { askReplyConfirmation, dispatch, intl } = this.props;
    if (askReplyConfirmation) {
      dispatch(openModal('CONFIRM', {
        message: intl.formatMessage(messages.quoteMessage),
        confirm: intl.formatMessage(messages.quoteConfirm),
        onConfirm: () => dispatch(quoteCompose(status, this.context.router.history)),
      }));
    } else {
      dispatch(quoteCompose(status, this.context.router.history));
    }
  }

  handleDeleteClick = (status, history, withRedraft = false) => {
    const { dispatch, intl } = this.props;

    if (!deleteModal) {
      dispatch(deleteStatus(status.get('id'), history, withRedraft));
    } else {
      dispatch(openModal('CONFIRM', {
        message: intl.formatMessage(withRedraft ? messages.redraftMessage : messages.deleteMessage),
        confirm: intl.formatMessage(withRedraft ? messages.redraftConfirm : messages.deleteConfirm),
        onConfirm: () => dispatch(deleteStatus(status.get('id'), history, withRedraft)),
      }));
    }
  }

  handleExpireClick = (status) => {
    const { dispatch, intl } = this.props;

    if (!deleteModal) {
      dispatch(expireStatus(status.get('id')));
    } else {
      dispatch(openModal('CONFIRM', {
        message: intl.formatMessage(messages.expireMessage),
        confirm: intl.formatMessage(messages.expireConfirm),
        onConfirm: () => dispatch(expireStatus(status.get('id'))),
      }));
    }
  }

  handleDirectClick = (account, router) => {
    this.props.dispatch(directCompose(account, router));
  }

  handleMemberListClick = (status, history) => {
    history.push(`/statuses/${status.get('id')}/mentions`);
  }

  handleMentionClick = (account, router) => {
    this.props.dispatch(mentionCompose(account, router));
  }

  handleOpenMedia = (media, index) => {
    this.props.dispatch(openModal('MEDIA', { statusId: this.props.status.get('id'), media, index }));
  }

  handleOpenVideo = (media, options) => {
    this.props.dispatch(openModal('VIDEO', { statusId: this.props.status.get('id'), media, options }));
  }

  handleOpenMediaQuote = (media, index) => {
    this.props.dispatch(openModal('MEDIA', { statusId: this.props.status.getIn(['quote', 'id']), media, index }));
  }

  handleOpenVideoQuote = (media, options) => {
    this.props.dispatch(openModal('VIDEO', { statusId: this.props.status.getIn(['quote', 'id']), media, options }));
  }

  handleHotkeyOpenMedia = e => {
    const { status } = this.props;

    e.preventDefault();

    if (status.get('media_attachments').size > 0) {
      if (status.getIn(['media_attachments', 0, 'type']) === 'video') {
        this.handleOpenVideo(status.getIn(['media_attachments', 0]), { startTime: 0 });
      } else {
        this.handleOpenMedia(status.get('media_attachments'), 0);
      }
    }
  }

  handleMuteClick = (account) => {
    this.props.dispatch(initMuteModal(account));
  }

  handleConversationMuteClick = (status) => {
    if (status.get('muted')) {
      this.props.dispatch(unmuteStatus(status.get('id')));
    } else {
      this.props.dispatch(muteStatus(status.get('id')));
    }
  }

  handleToggleHidden = (status) => {
    if (status.get('hidden')) {
      this.props.dispatch(revealStatus(status.get('id')));
    } else {
      this.props.dispatch(hideStatus(status.get('id')));
    }
  }

  handleToggleAll = () => {
    const { status, ancestorsIds, descendantsIds } = this.props;
    const statusIds = [status.get('id')].concat(ancestorsIds.toJS(), descendantsIds.toJS());

    if (status.get('hidden')) {
      this.props.dispatch(revealStatus(statusIds));
    } else {
      this.props.dispatch(hideStatus(statusIds));
    }
  }

  handleBlockClick = (status) => {
    const { dispatch } = this.props;
    const account = status.get('account');
    dispatch(initBlockModal(account));
  }

  handleReport = (status) => {
    this.props.dispatch(initReport(status.get('account'), status));
  }

  handleEmbed = (status) => {
    this.props.dispatch(openModal('EMBED', { url: status.get('url') }));
  }

  handleUnmuteClick = account => {
    this.props.dispatch(unmuteAccount(account.get('id')));
  }

  handleUnblockClick = account => {
    this.props.dispatch(unblockAccount(account.get('id')));
  }

  handleBlockDomainClick = domain => {
    this.props.dispatch(openModal('CONFIRM', {
      message: <FormattedMessage id='confirmations.domain_block.message' defaultMessage='Are you really, really sure you want to block the entire {domain}? In most cases a few targeted blocks or mutes are sufficient and preferable. You will not see content from that domain in any public timelines or your notifications. Your followers from that domain will be removed.' values={{ domain: <strong>{domain}</strong> }} />,
      confirm: this.props.intl.formatMessage(messages.blockDomainConfirm),
      onConfirm: () => this.props.dispatch(blockDomain(domain)),
      passphrase: confirmDomainBlock && this.props.intl.formatMessage(messages.blockDomainPassphrase),
      destructive: true,
    }));
  }

  handleUnblockDomainClick = domain => {
    this.props.dispatch(unblockDomain(domain));
  }


  handleHotkeyMoveUp = () => {
    this.handleMoveUp(this.props.status.get('id'));
  }

  handleHotkeyMoveDown = () => {
    this.handleMoveDown(this.props.status.get('id'));
  }

  handleHotkeyReply = e => {
    e.preventDefault();
    this.handleReplyClick(this.props.status);
  }

  handleHotkeyFavourite = () => {
    this.handleFavouriteClick(this.props.status);
  }

  handleHotkeyBoost = () => {
    this.handleReblogClick(this.props.status);
  }

  handleHotkeyMention = e => {
    e.preventDefault();
    this.handleMentionClick(this.props.status.get('account'));
  }

  handleHotkeyOpenProfile = () => {
    this.context.router.history.push(`/accounts/${this.props.status.getIn(['account', 'id'])}`);
  }

  handleHotkeyToggleHidden = () => {
    this.handleToggleHidden(this.props.status);
  }

  handleHotkeyToggleSensitive = () => {
    this.handleToggleMediaVisibility();
  }

  handleAddEmojiReaction = (status, name, domain, url, static_url) => {
    this.props.dispatch(addEmojiReaction(status, name, domain, url, static_url));
  }

  handleRemoveEmojiReaction = (status, name) => {
    this.props.dispatch(removeEmojiReaction(status, name));
  }

  handleAddReference = (id, change) => {
    this.props.dispatch(addReference(id, change));
  }

  handleRemoveReference = (id) => {
    this.props.dispatch(removeReference(id));
  }

  getCurrentStatusIndex = id => {
    const { status, ancestorsIds, descendantsIds } = this.props;
    const statusIds = ImmutableList([status.get('id')]);

    return ImmutableList().concat(ancestorsIds, statusIds, descendantsIds).indexOf(id);
  }

  handleMoveUp = id => {
    const index = this.getCurrentStatusIndex(id);

    if (index !== -1) {
      this._selectChild(index - 1, true);
    }
  }

  handleMoveDown = id => {
    const index = this.getCurrentStatusIndex(id);

    if (index !== -1) {
      this._selectChild(index + 1, true);
    }
  }

  _selectChild (index, align_top) {
    const container = this.node;
    const element = container.querySelectorAll('.focusable')[index];

    if (element) {
      if (align_top && container.scrollTop > element.offsetTop) {
        element.scrollIntoView(true);
      } else if (!align_top && container.scrollTop + container.clientHeight < element.offsetTop + element.offsetHeight) {
        element.scrollIntoView(false);
      }
      element.focus();
    }
  }

  renderChildren (list) {
    return list.map(id => (
      <StatusContainer
        key={id}
        id={id}
        onMoveUp={this.handleMoveUp}
        onMoveDown={this.handleMoveDown}
        contextType='thread'
      />
    ));
  }

  setRef = c => {
    this.node = c;
  }

  componentDidUpdate () {
    if (this._scrolledIntoView) {
      return;
    }

    const { status, ancestorsIds } = this.props;

    if (status && ancestorsIds && ancestorsIds.size > 0) {
      const element = this.node.querySelectorAll('.focusable')[ancestorsIds.size - 1];

      window.requestAnimationFrame(() => {
        element.scrollIntoView(true);
      });
      this._scrolledIntoView = true;
    }
  }

  componentWillUnmount () {
    detachFullscreenListener(this.onFullScreenChange);
  }

  onFullScreenChange = () => {
    this.setState({ fullscreen: isFullscreen() });
  }

  handleWidthChange = (value) => {
    const { columnId, dispatch } = this.props;

    if (columnId) {
      dispatch(changeColumnParams(columnId, 'columnWidth', value));
    } else {
      dispatch(changeSetting(['status', 'columnWidth'], value));
    }
  }

  render () {
    let ancestors, descendants;
    const { status, ancestorsIds, descendantsIds, intl, domain, multiColumn, pictureInPicture, referenced, contextReferenced, columnWidth, emojiReactioned, reactionLimitReached } = this.props;
    const { fullscreen } = this.state;

    if (status === null) {
      return (
        <Column>
          <ColumnBackButton multiColumn={multiColumn} />
          <MissingIndicator />
        </Column>
      );
    }

    if (ancestorsIds && ancestorsIds.size > 0) {
      ancestors = <div>{this.renderChildren(ancestorsIds)}</div>;
    }

    if (descendantsIds && descendantsIds.size > 0) {
      descendants = <div>{this.renderChildren(descendantsIds)}</div>;
    }

    const referenceCount  = enableStatusReference ? status.get('status_references_count', 0) - (status.get('status_reference_ids', ImmutableList()).includes(status.get('quote_id')) ? 1 : 0) : 0;

    const handlers = {
      moveUp: this.handleHotkeyMoveUp,
      moveDown: this.handleHotkeyMoveDown,
      reply: this.handleHotkeyReply,
      favourite: this.handleHotkeyFavourite,
      boost: this.handleHotkeyBoost,
      mention: this.handleHotkeyMention,
      openProfile: this.handleHotkeyOpenProfile,
      toggleHidden: this.handleHotkeyToggleHidden,
      toggleSensitive: this.handleHotkeyToggleSensitive,
      openMedia: this.handleHotkeyOpenMedia,
    };

    return (
      <Column bindToDocument={!multiColumn} label={intl.formatMessage(messages.detailedStatus)} columnWidth={columnWidth}>
        <ColumnHeader
          showBackButton
          multiColumn={multiColumn}
          columnWidth={columnWidth}
          onWidthChange={this.handleWidthChange}
          extraButton={(
            <button className='column-header__button' title={intl.formatMessage(status.get('hidden') ? messages.revealAll : messages.hideAll)} aria-label={intl.formatMessage(status.get('hidden') ? messages.revealAll : messages.hideAll)} onClick={this.handleToggleAll} aria-pressed={status.get('hidden') ? 'false' : 'true'}><Icon id={status.get('hidden') ? 'eye-slash' : 'eye'} /></button>
          )}
        />

        <DetailedHeaderContaier statusId={status.get('id')} />

        <ScrollContainer scrollKey='thread'>
          <div className={classNames('scrollable', { fullscreen })} ref={this.setRef}>
            {ancestors}

            <HotKeys handlers={handlers}>
              <div
                className={classNames('focusable', 'detailed-status__wrapper', {
                  'detailed-status__wrapper-referenced': referenced,
                  'detailed-status__wrapper-context-referenced': contextReferenced,
                  'detailed-status__wrapper-reference': referenceCount > 0,
                })} tabIndex='0' aria-label={textForScreenReader(intl, status, false)}
              >
                <DetailedStatus
                  key={`details-${status.get('id')}`}
                  status={status}
                  referenced={referenced}
                  contextReferenced={contextReferenced}
                  onOpenVideo={this.handleOpenVideo}
                  onOpenMedia={this.handleOpenMedia}
                  onOpenVideoQuote={this.handleOpenVideoQuote}
                  onOpenMediaQuote={this.handleOpenMediaQuote}
                  onToggleHidden={this.handleToggleHidden}
                  domain={domain}
                  showMedia={this.state.showMedia}
                  onToggleMediaVisibility={this.handleToggleMediaVisibility}
                  pictureInPicture={pictureInPicture}
                  showQuoteMedia={this.state.showQuoteMedia}
                  onToggleQuoteMediaVisibility={this.handleToggleQuoteMediaVisibility}
                  addEmojiReaction={this.handleAddEmojiReaction}
                  removeEmojiReaction={this.handleRemoveEmojiReaction}
                />

                <ActionBar
                  key={`action-bar-${status.get('id')}`}
                  status={status}
                  referenced={referenced}
                  contextReferenced={contextReferenced}
                  emojiReactioned={emojiReactioned}
                  reactionLimitReached={reactionLimitReached}
                  onReply={this.handleReplyClick}
                  onFavourite={this.handleFavouriteClick}
                  onReblog={this.handleReblogClick}
                  onBookmark={this.handleBookmarkClick}
                  onQuote={this.handleQuoteClick}
                  onDelete={this.handleDeleteClick}
                  onExpire={this.handleExpireClick}
                  onDirect={this.handleDirectClick}
                  onMemberList={this.handleMemberListClick}
                  onMention={this.handleMentionClick}
                  onMute={this.handleMuteClick}
                  onUnmute={this.handleUnmuteClick}
                  onMuteConversation={this.handleConversationMuteClick}
                  onBlock={this.handleBlockClick}
                  onUnblock={this.handleUnblockClick}
                  onBlockDomain={this.handleBlockDomainClick}
                  onUnblockDomain={this.handleUnblockDomainClick}
                  onReport={this.handleReport}
                  onPin={this.handlePin}
                  onEmbed={this.handleEmbed}
                  addEmojiReaction={this.handleAddEmojiReaction}
                  removeEmojiReaction={this.handleRemoveEmojiReaction}
                  onAddReference={this.handleAddReference}
                  onRemoveReference={this.handleRemoveReference}
                />
              </div>
            </HotKeys>

            {descendants}
          </div>
        </ScrollContainer>
      </Column>
    );
  }

}

export default injectIntl(connect(makeMapStateToProps)(Status));
