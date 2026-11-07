import React from 'react';
import { connect } from 'react-redux';
import ImmutablePureComponent from 'react-immutable-pure-component';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import IconButton from 'mastodon/components/icon_button';
import classNames from 'classnames';
import { me, boostModal, show_quote_button, enableStatusReference, maxReferences, matchVisibilityOfReferences, addReferenceModal } from 'mastodon/initial_state';
import { defineMessages, injectIntl } from 'react-intl';
import { replyCompose, quoteCompose, addReference, addReferenceToComposer, removeReference } from 'mastodon/actions/compose';
import { dismissFullscreenModals, dispatchFullscreenCompose, pushFullscreenPath, setFullscreenComposerOpen } from 'mastodon/actions/fullscreen_column';
import { createComposer, targetComposerAction } from 'mastodon/actions/composer';
import { selectComposer, selectPortableComposerSeed } from 'mastodon/selectors/composer';
import { reblog, favourite, bookmark, unreblog, unfavourite, unbookmark } from 'mastodon/actions/interactions';
import { makeGetStatus } from 'mastodon/selectors';
import { initBoostModal } from 'mastodon/actions/boosts';
import { openModal } from 'mastodon/actions/modal';

const messages = defineMessages({
  reply: { id: 'status.reply', defaultMessage: 'Reply' },
  replyAll: { id: 'status.replyAll', defaultMessage: 'Reply to thread' },
  reference: { id: 'status.reference', defaultMessage: 'Reference' },
  reblog: { id: 'status.reblog', defaultMessage: 'Boost' },
  reblog_private: { id: 'status.reblog_private', defaultMessage: 'Boost with original visibility' },
  cancel_reblog_private: { id: 'status.cancel_reblog_private', defaultMessage: 'Unboost' },
  cannot_reblog: { id: 'status.cannot_reblog', defaultMessage: 'This post cannot be boosted' },
  cannot_quote: { id: 'status.cannot_quote', defaultMessage: 'This post cannot be quoted' },
  quote: { id: 'status.quote', defaultMessage: 'Quote' },
  favourite: { id: 'status.favourite', defaultMessage: 'Favourite' },
  bookmark: { id: 'status.bookmark', defaultMessage: 'Bookmark' },
  replyConfirm: { id: 'confirmations.reply.confirm', defaultMessage: 'Reply' },
  replyMessage: { id: 'confirmations.reply.message', defaultMessage: 'Replying now will overwrite the message you are currently composing. Are you sure you want to proceed?' },
  quoteConfirm: { id: 'confirmations.quote.confirm', defaultMessage: 'Quote' },
  quoteMessage: { id: 'confirmations.quote.message', defaultMessage: 'Quoting now will overwrite the message you are currently composing. Are you sure you want to proceed?' },
  open: { id: 'status.open', defaultMessage: 'Expand this status' },
  visibilityMatchMessage: { id: 'visibility.match_message', defaultMessage: 'Do you want to match the visibility of the post to the reference?' },
  visibilityKeepMessage: { id: 'visibility.keep_message', defaultMessage: 'Do you want to keep the visibility of the post to the reference?' },
  visibilityChange: { id: 'visibility.change', defaultMessage: 'Change' },
  visibilityKeep: { id: 'visibility.keep', defaultMessage: 'Keep' },
});

const makeMapStateToProps = () => {
  const getStatus = makeGetStatus();
  const getProper = (status) => status.get('reblog', null) !== null && typeof status.get('reblog') === 'object' ? status.get('reblog') : status;

  const mapStateToProps = (state, { statusId, fullscreenScope }) => {
    const status         = getStatus(state, { id: statusId });
    const id             = status ? getProper(status).get('id') : null;
    const composerId = fullscreenScope && fullscreenScope.composerId;
    const compose = composerId ? selectComposer(state, composerId) : state.get('compose');
    const references = compose ? compose.get('references') : null;

    return {
      status,
      askReplyConfirmation: !!(compose && compose.get('text') && compose.get('text').trim().length !== 0 && (!composerId || compose.get('dirty'))),
      referenceCountLimit: !!(references && references.size >= maxReferences),
      referenced: !!(references && references.has(id)),
      contextReferenced: !!(compose && compose.get('context_references') && compose.get('context_references').has(id)),
      composePrivacy: compose ? compose.get('privacy') : state.getIn(['compose', 'privacy']),
    };
  };

  return mapStateToProps;
};

export default @connect(makeMapStateToProps)
@injectIntl
class Footer extends ImmutablePureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    statusId: PropTypes.string.isRequired,
    status: ImmutablePropTypes.map.isRequired,
    referenceCountLimit: PropTypes.bool,
    referenced: PropTypes.bool,
    contextReferenced: PropTypes.bool,
    composePrivacy: PropTypes.string,
    intl: PropTypes.object.isRequired,
    dispatch: PropTypes.func.isRequired,
    askReplyConfirmation: PropTypes.bool,
    withOpenButton: PropTypes.bool,
    onClose: PropTypes.func,
    fullscreenScope: PropTypes.shape({
      viewId: PropTypes.string,
      composerId: PropTypes.string,
    }),
  };

  scopedComposerId = () => this.props.fullscreenScope && this.props.fullscreenScope.composerId;

  _performReply = () => {
    const { dispatch, status, onClose, intl } = this.props;
    const { router } = this.context;
    const composerId = this.scopedComposerId();

    if (onClose) {
      onClose();
    }

    if (composerId) {
      dispatch(dispatchFullscreenCompose('reply', status, intl, composerId));
      return;
    }

    dispatch(replyCompose(status, router.history));
  };

  handleReplyClick = () => {
    const { dispatch, askReplyConfirmation, intl } = this.props;

    if (this.scopedComposerId()) {
      this._performReply();
      return;
    }

    if (askReplyConfirmation) {
      dispatch(openModal('CONFIRM', {
        message: intl.formatMessage(messages.replyMessage),
        confirm: intl.formatMessage(messages.replyConfirm),
        onConfirm: this._performReply,
      }));
    } else {
      this._performReply();
    }
  };

  handleReferenceClick = (e) => {
    const { dispatch, intl, status, referenced, composePrivacy } = this.props;
    const id = status.get('id');

    if (referenced) {
      this.handleRemoveReference(id);
    } else {
      if (status.get('visibility') === 'private' && ['public', 'unlisted'].includes(composePrivacy)) {
        if (!addReferenceModal || e && e.shiftKey) {
          this.handleAddReference(id, true);
        } else {
          dispatch(openModal('CONFIRM', {
            message: intl.formatMessage(matchVisibilityOfReferences ? messages.visibilityMatchMessage : messages.visibilityKeepMessage),
            confirm: intl.formatMessage(matchVisibilityOfReferences ? messages.visibilityChange : messages.visibilityKeep),
            onConfirm:   () => this.handleAddReference(id, matchVisibilityOfReferences),
            secondary: intl.formatMessage(matchVisibilityOfReferences ? messages.visibilityKeep : messages.visibilityChange),
            onSecondary: () => this.handleAddReference(id, !matchVisibilityOfReferences),
          }));
        }
      } else {
        this.handleAddReference(id, true);
      }
    }
  }

  handleAddReference = (id, change) => {
    const composerId = this.scopedComposerId();

    if (!composerId) {
      this.props.dispatch(addReference(id, change));
      return;
    }

    this.props.dispatch((dispatch, getState) => {
      if (!selectComposer(getState(), composerId)) {
        dispatch(createComposer(composerId, selectPortableComposerSeed(getState())));
      }

      if (getState().getIn(['fullscreenColumn', 'composerId']) === composerId) {
        dispatch(dismissFullscreenModals());
        dispatch(setFullscreenComposerOpen(true));
      }

      dispatch(addReferenceToComposer(composerId, id, change));
    });
  }

  handleRemoveReference = (id) => {
    const composerId = this.scopedComposerId();

    if (!composerId) {
      this.props.dispatch(removeReference(id));
      return;
    }

    this.props.dispatch(targetComposerAction(removeReference(id), composerId));
  }

  handleFavouriteClick = () => {
    const { dispatch, status } = this.props;

    if (status.get('favourited')) {
      dispatch(unfavourite(status));
    } else {
      dispatch(favourite(status));
    }
  };

  _performReblog = (status, privacy) => {
    const { dispatch } = this.props;
    dispatch(reblog(status, privacy));
  }

  handleReblogClick = e => {
    const { dispatch, status } = this.props;

    if (status.get('reblogged')) {
      dispatch(unreblog(status));
    } else if ((e && e.shiftKey) ^ !boostModal) {
      this._performReblog(status);
    } else {
      dispatch(initBoostModal({ status, onReblog: this._performReblog }));
    }
  };

  handleOpenClick = e => {
    const { router } = this.context;

    if (e.button !== 0 || !router) {
      return;
    }

    const { status, onClose, dispatch } = this.props;

    if (onClose) {
      onClose();
    }

    if (this.scopedComposerId()) {
      dispatch(pushFullscreenPath(`/statuses/${status.get('id')}`));
      return;
    }

    router.history.push(`/statuses/${status.get('id')}`);
  }

  handleBookmarkClick = () => {
    const { dispatch, status } = this.props;

    if (status.get('bookmarked')) {
      dispatch(unbookmark(status));
    } else {
      dispatch(bookmark(status));
    }
  }

  _performQuote = () => {
    const { dispatch, status, onClose, intl } = this.props;
    const { router } = this.context;
    const composerId = this.scopedComposerId();

    if (onClose) {
      onClose();
    }

    if (composerId) {
      dispatch(dispatchFullscreenCompose('quote', status, intl, composerId));
      return;
    }

    dispatch(quoteCompose(status, router.history));
  };

  handleQuoteClick = () => {
    const { dispatch, askReplyConfirmation, intl } = this.props;

    if (this.scopedComposerId()) {
      this._performQuote();
      return;
    }

    if (askReplyConfirmation) {
      dispatch(openModal('CONFIRM', {
        message: intl.formatMessage(messages.quoteMessage),
        confirm: intl.formatMessage(messages.quoteConfirm),
        onConfirm: this._performQuote,
      }));
    } else {
      this._performQuote();
    }
  }

  render () {
    const { status, intl, withOpenButton, referenced, contextReferenced, referenceCountLimit } = this.props;

    const publicStatus  = ['public', 'unlisted'].includes(status.get('visibility'));
    const reblogPrivate = status.getIn(['account', 'id']) === me && status.get('visibility') === 'private';

    const expires_at = status.get('expires_at')
    const expires_date = expires_at && new Date(expires_at)
    const expired = expires_date && expires_date.getTime() < intl.now()

    let replyIcon, replyTitle;

    if (status.get('in_reply_to_id', null) === null) {
      replyIcon = 'reply';
      replyTitle = intl.formatMessage(messages.reply);
    } else {
      replyIcon = 'reply-all';
      replyTitle = intl.formatMessage(messages.replyAll);
    }

    let reblogTitle = '';

    if (status.get('reblogged')) {
      reblogTitle = intl.formatMessage(messages.cancel_reblog_private);
    } else if (publicStatus) {
      reblogTitle = intl.formatMessage(messages.reblog);
    } else if (reblogPrivate) {
      reblogTitle = intl.formatMessage(messages.reblog_private);
    } else {
      reblogTitle = intl.formatMessage(messages.cannot_reblog);
    }

    const referenceDisabled = expired || !referenced && referenceCountLimit || ['limited', 'direct', 'personal'].includes(status.get('visibility'));

    return (
      <div className='picture-in-picture__footer'>
        <IconButton className='status__action-bar-button' title={replyTitle} icon={status.get('in_reply_to_account_id') === status.getIn(['account', 'id']) ? 'reply' : replyIcon} onClick={this.handleReplyClick} counter={status.get('replies_count')} obfuscateCount />
        {enableStatusReference && me && <IconButton className={classNames('status__action-bar-button', 'link-icon', {referenced, 'context-referenced': contextReferenced})} animate disabled={referenceDisabled} active={referenced} pressed={referenced} title={intl.formatMessage(messages.reference)} icon='link' onClick={this.handleReferenceClick} />}
        <IconButton className={classNames('status__action-bar-button', { reblogPrivate })} disabled={!publicStatus && !reblogPrivate}  active={status.get('reblogged')} pressed={status.get('reblogged')} title={reblogTitle} icon='retweet' onClick={this.handleReblogClick} counter={status.get('reblogs_count')} />
        <IconButton className='status__action-bar-button star-icon' animate active={status.get('favourited')} pressed={status.get('favourited')} title={intl.formatMessage(messages.favourite)} icon='star' onClick={this.handleFavouriteClick} counter={status.get('favourites_count')} />
        {show_quote_button && <IconButton className='status__action-bar-button' disabled={!publicStatus || expired} title={!publicStatus ? intl.formatMessage(messages.cannot_quote) : intl.formatMessage(messages.quote)} icon='quote-right' onClick={this.handleQuoteClick} />}
        <IconButton className='status__action-bar-button bookmark-icon' active={status.get('bookmarked')} title={intl.formatMessage(messages.bookmark)} icon='bookmark' onClick={this.handleBookmarkClick} />
        {withOpenButton && <IconButton className='status__action-bar-button' title={intl.formatMessage(messages.open)} icon='external-link' onClick={this.handleOpenClick} />}
      </div>
    );
  }

}
