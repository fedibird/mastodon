import React, { Fragment } from 'react';
import { connect } from 'react-redux';
import PropTypes from 'prop-types';
import ImmutablePropTypes from 'react-immutable-proptypes';
import Avatar from '../../../components/avatar';
import DisplayName from '../../../components/display_name';
import ExternalSourceIdentity, { TimeLink } from '../../../components/external_source_identity';
import { externalIdentityOf } from 'mastodon/external_presentation';
import ExternalStatusMedia from '../../../components/external_status_media';
import StatusContent from '../../../components/status_content';
import { isHideCard } from '../../../components/status';
import MediaGallery from '../../../components/media_gallery';
import { Link } from 'react-router-dom';
import { injectIntl, defineMessages, FormattedDate, FormattedMessage } from 'react-intl';
import Card from './card';
import ImmutablePureComponent from 'react-immutable-pure-component';
import Video from '../../video';
import Audio from '../../audio';

import { galleryTranslationProps, statusTranslationView, translationDisplayStatus } from 'mastodon/utils/translation_view';
import StatusMediaStack from 'mastodon/components/status_media';
import { translationRequestStatus } from 'mastodon/utils/translation_languages';
import scheduleIdleTask from '../../ui/util/schedule_idle_task';
import classNames from 'classnames';
import Icon from 'mastodon/components/icon';
import EditedTimestamp from 'mastodon/components/edited_timestamp';
import AnimatedNumber from 'mastodon/components/animated_number';
import EmojiReactionsBar from 'mastodon/components/emoji_reactions_bar';
import PictureInPicturePlaceholder from 'mastodon/components/picture_in_picture_placeholder';
import AccountContextActions from '../../account_context/components/actions';
import { enableReaction, enableStatusReference, hideListOfEmojiReactionsToPosts, hideListOfFavouritesToPosts, hideListOfReblogsToPosts, hideListOfReferredByToPosts } from 'mastodon/initial_state';

const messages = defineMessages({
  public_short: { id: 'privacy.public.short', defaultMessage: 'Public' },
  unlisted_short: { id: 'privacy.unlisted.short', defaultMessage: 'Unlisted' },
  private_short: { id: 'privacy.private.short', defaultMessage: 'Followers-only' },
  mutual_short: { id: 'privacy.mutual.short', defaultMessage: 'Mutual-followers-only' },
  personal_short: { id: 'privacy.personal.short', defaultMessage: 'Personal' },
  external_short: { id: 'privacy.external.short', defaultMessage: 'External content (only you)' },
  limited_short: { id: 'privacy.limited.short', defaultMessage: 'Circle' },
  direct_short: { id: 'privacy.direct.short', defaultMessage: 'Direct' },
});

const mapStateToProps = (state, props) => {
  let status = props.status;

  if (status === null) {
    return null;
  }

  if (status.get('reblog', null) !== null && typeof status.get('reblog') === 'object') {
    status = status.get('reblog');
  }

  if (status.get('quote', null) === null) {
    return {
      quote_muted: status.get('quote_id', null) ? true : false,
    };
  }
  const id = status.getIn(['quote', 'account', 'id'], null);

  return {
    quote_muted: id !== null && (state.getIn(['relationships', id, 'muting']) || state.getIn(['relationships', id, 'blocking']) || state.getIn(['relationships', id, 'blocked_by']) || state.getIn(['relationships', id, 'domain_blocking'])) || status.getIn(['quote', 'quote_muted']),
  };
};

const dateFormatOptions = {
  hour12: false,
  year: 'numeric',
  month: 'short',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
};

export default @connect(mapStateToProps)
@injectIntl
class DetailedStatus extends ImmutablePureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    status: ImmutablePropTypes.map,
    referenced: PropTypes.bool,
    contextReferenced: PropTypes.bool,
    quote_muted: PropTypes.bool,
    onOpenMedia: PropTypes.func.isRequired,
    onOpenVideo: PropTypes.func.isRequired,
    onOpenMediaQuote: PropTypes.func.isRequired,
    onOpenVideoQuote: PropTypes.func.isRequired,
    onTranslate: PropTypes.func,
    onToggleHidden: PropTypes.func.isRequired,
    measureHeight: PropTypes.bool,
    onHeightChange: PropTypes.func,
    domain: PropTypes.string.isRequired,
    compact: PropTypes.bool,
    showMedia: PropTypes.bool,
    pictureInPicture: ImmutablePropTypes.contains({
      inUse: PropTypes.bool,
      available: PropTypes.bool,
    }),
    onToggleMediaVisibility: PropTypes.func,
    showQuoteMedia: PropTypes.bool,
    onToggleQuoteMediaVisibility: PropTypes.func,
    addEmojiReaction: PropTypes.func.isRequired,
    removeEmojiReaction: PropTypes.func.isRequired,
    onReference: PropTypes.func,
    contextHostId: PropTypes.string,
    onOpenAccountContext: PropTypes.func,
    reactionLimitReached: PropTypes.bool,
  };

  state = {
    height: null,
  };

  handleAccountClick = (e) => {
    if (e.button === 0 && !(e.ctrlKey || e.metaKey) && this.context.router) {
      const id = e.currentTarget.getAttribute('data-id');
      const group = e.currentTarget.getAttribute('data-group') !== 'false';

      e.preventDefault();
      if (group) {
        this.context.router.history.push(`/timelines/groups/${id}`);
      } else {
        this.context.router.history.push(`/accounts/${id}`);
      }
    }

    e.stopPropagation();
  }

  _translationMediaStatus () {
    return translationDisplayStatus(this._properStatus(), this.props.status);
  }

  _properStatus () {
    const { status } = this.props;

    if (status && status.get('reblog') && typeof status.get('reblog') === 'object') {
      return status.get('reblog');
    }

    return status;
  }

  handleTranslate = (mode) => {
    const { onTranslate, status } = this.props;
    const requestStatus = translationRequestStatus(status);

    if (!onTranslate || !requestStatus) {
      return;
    }

    onTranslate(requestStatus, mode);
  }

  handleQuoteTranslate = (mode) => {
    const { onTranslate } = this.props;
    const displayed = this._properStatus();
    const quote = displayed && displayed.get('quote');

    if (onTranslate && quote && quote.get('translation')) {
      onTranslate(quote, mode);
    }
  }

  handleOpenMedia = (media, index) => {
    const status = this._properStatus();
    const lang = statusTranslationView(this._translationMediaStatus()).mediaLang;
    this.props.onOpenMedia(media, index, lang, status.get('id'));
  }

  handleOpenMediaQuote = (media, index) => {
    const quote = this._properStatus().get('quote');
    const lang = statusTranslationView(quote).mediaLang;
    this.props.onOpenMediaQuote(media, index, lang, quote.get('id'));
  }

  handleOpenVideo = (attachment, options) => {
    const status = this._properStatus();
    const lang = statusTranslationView(this._translationMediaStatus()).mediaLang;
    this.props.onOpenVideo(attachment, options, lang, status.get('id'));
  }

  handleOpenSavedVideo = (attachment, options) => {
    const status = this._properStatus();
    const lang = statusTranslationView(this._translationMediaStatus()).mediaLang;
    this.props.onOpenVideo(attachment, options, lang, status.get('id'));
  }

  handleOpenVideoQuote = (attachment, options) => {
    const quote = this._properStatus().get('quote');
    const lang = statusTranslationView(quote).mediaLang;
    this.props.onOpenVideoQuote(attachment, options, lang, quote.get('id'));
  }

  handleExpandedToggle = () => {
    this.props.onToggleHidden(this.props.status);
  }

  renderAttachmentMedia (mediaStatus, options) {
    const translation = galleryTranslationProps(options.translationView);

    return (
      <StatusMediaStack
        media={mediaStatus.get('media_attachments')}
        Gallery={MediaGallery}
        Video={Video}
        Audio={Audio}
        sensitive={options.sensitive}
        height={options.height}
        videoHeight={options.videoHeight}
        audioHeight={options.audioHeight}
        visible={options.visible}
        onToggleVisibility={options.onToggleVisibility}
        onOpenMedia={options.onOpenMedia}
        onOpenVideo={options.onOpenVideo}
        defaultWidth={options.width}
        standalone
        quote={options.quote}
        posterFallback={options.posterFallback}
        lang={translation.lang}
        translationMode={translation.translationMode}
        sourceLang={translation.sourceLang}
        targetLang={translation.targetLang}
      />
    );
  }

  _measureHeight (heightJustChanged) {
    if (this.props.measureHeight && this.node) {
      scheduleIdleTask(() => this.node && this.setState({ height: Math.ceil(this.node.scrollHeight) + 1 }));

      if (this.props.onHeightChange && heightJustChanged) {
        this.props.onHeightChange();
      }
    }
  }

  setRef = c => {
    this.node = c;
    this._measureHeight();
  }

  componentDidUpdate (prevProps, prevState) {
    this._measureHeight(prevState.height !== this.state.height);
  }

  handleModalLink = e => {
    e.preventDefault();

    let href;

    if (e.target.nodeName !== 'A') {
      href = e.target.parentNode.href;
    } else {
      href = e.target.href;
    }

    window.open(href, 'mastodon-intent', 'width=445,height=600,resizable=no,menubar=no,status=no,scrollbars=yes');
  }

  handleExpandedQuoteToggle = () => {
    this.props.onToggleHidden(this.props.status.get('quote'));
  }

  handleQuoteClick = () => {
    if (!this.context.router) {
      return;
    }

    const { status } = this.props;
    this.context.router.history.push(`/statuses/${status.getIn(['quote', 'id'])}`);
  }

  render () {
    const status = (this.props.status && this.props.status.get('reblog')) ? this.props.status.get('reblog') : this.props.status;
    const quote_muted = this.props.quote_muted;
    const outerStyle = { boxSizing: 'border-box' };
    const { intl, compact, pictureInPicture, referenced, contextReferenced, reactionLimitReached } = this.props;

    if (!status) {
      return null;
    }

    let media                = '';
    let applicationLink      = '';
    let reblogLink           = '';
    let reblogIcon           = 'retweet';
    let favouriteLink        = '';
    let emojiReactionLink    = '';
    let statusReferredByLink = '';

    const reblogsCount = status.get('reblogs_count');
    const favouritesCount = status.get('favourites_count');
    const emojiReactionsCount = status.get('emoji_reactions_count');
    const referredByCount = status.get('status_referred_by_count');

    const showReblogCount = !hideListOfReblogsToPosts && reblogsCount > 0;
    const showFavouritCount = !hideListOfFavouritesToPosts && favouritesCount > 0;
    const showEmojiReactionCount = !hideListOfEmojiReactionsToPosts && enableReaction && emojiReactionsCount > 0;
    const showStatusReferredByCount = !hideListOfReferredByToPosts && enableStatusReference && referredByCount > 0;

    if (this.props.measureHeight) {
      outerStyle.height = `${this.state.height}px`;
    }

    let quote = null;
    if (status.get('quote', null) !== null) {
      let quote_status = status.get('quote');
      const quoteExternalIdentity = externalIdentityOf(quote_status);
      const quoteView = statusTranslationView(quote_status);

      let quote_media = null;
      if (quote_status.get('fedibird_external')) {
        quote_media = (
          <ExternalStatusMedia
            status={quote_status}
            sensitive={quote_status.get('sensitive')}
            height={300}
            videoHeight={150}
            standalone
            quote
            onOpenMedia={this.handleOpenMediaQuote}
            onOpenVideo={this.handleOpenVideoQuote}
            visible={this.props.showQuoteMedia}
            onToggleVisibility={this.props.onToggleQuoteMediaVisibility}
            {...galleryTranslationProps(quoteView)}
          />
        );
      } else if (quote_status.get('media_attachments').size > 0) {
        quote_media = this.renderAttachmentMedia(quote_status, {
          sensitive: quote_status.get('sensitive'),
          height: 300,
          videoHeight: 150,
          audioHeight: 60,
          width: 300,
          visible: this.props.showQuoteMedia,
          onToggleVisibility: this.props.onToggleQuoteMediaVisibility,
          onOpenMedia: this.handleOpenMediaQuote,
          onOpenVideo: this.handleOpenVideoQuote,
          translationView: quoteView,
          posterFallback: quote_status.getIn(['account', 'avatar_static']),
          quote: true,
        });
      }

      if (quote_muted) {
        quote = (
          <div className='quote-status' data-id={quote_status.get('id')} dataurl={quote_status.get('url')}>
            <div className='status__content muted-quote'>
              <FormattedMessage id='status.muted_quote' defaultMessage='Muted quote' />
            </div>
          </div>
        );
      } else {
        quote = (
          <div className='quote-status' data-id={quote_status.get('id')} dataurl={quote_status.get('url')}>
            <div className='status__info'>
              {quoteExternalIdentity ? (
                <ExternalSourceIdentity identity={quoteExternalIdentity} size={18} className='detailed-status__display-name' avatarClassName='detailed-status__display-avatar' showLabel={false} />
              ) : (
                <a href={quote_status.getIn(['account', 'url'])} onClick={this.handleAccountClick} data-id={quote_status.getIn(['account', 'id'])} data-group={quote_status.getIn(['account', 'group'])} className='detailed-status__display-name'>
                  <div className='detailed-status__display-avatar'><Avatar account={quote_status.get('account')} size={18} /></div>
                  <DisplayName account={quote_status.get('account')} localDomain={this.props.domain} />
                </a>
              )}
            </div>
            <StatusContent status={quote_status} onClick={this.handleQuoteClick} expanded={!quote_status.get('hidden')} onExpandedToggle={this.handleExpandedQuoteToggle} onTranslate={quote_status.get('translation') && this.props.onTranslate ? this.handleQuoteTranslate : undefined} quote />
            {!(quote_status.get('hidden') && quote_status.get('spoiler_text').length > 0) && <>
              {quote_media}
            </>}
          </div>
        );
      }
    } else if (quote_muted) {
      quote = (
        <div className={classNames('quote-status', { muted: this.props.muted })}>
          <div className={classNames('status__content muted-quote', { 'status__content--with-action': this.context.router })}>
            <FormattedMessage id='status.muted_quote' defaultMessage='Muted quote' />
          </div>
        </div>
      );
    }

    const mediaStatus = translationDisplayStatus(status, this.props.status);
    const translationView = statusTranslationView(mediaStatus);

    if (status.get('fedibird_external') && !pictureInPicture.get('inUse')) {
      media = (
        <ExternalStatusMedia
          status={mediaStatus}
          sensitive={status.get('sensitive')}
          height={300}
          videoHeight={150}
          standalone
          onOpenMedia={this.handleOpenMedia}
          onOpenVideo={this.handleOpenSavedVideo}
          visible={this.props.showMedia}
          onToggleVisibility={this.props.onToggleMediaVisibility}
          {...galleryTranslationProps(translationView)}
        />
      );
    } else if (pictureInPicture.get('inUse')) {
      media = <PictureInPicturePlaceholder />;
    } else if (mediaStatus.get('media_attachments').size > 0) {
      media = this.renderAttachmentMedia(mediaStatus, {
        sensitive: status.get('sensitive'),
        height: 300,
        videoHeight: 150,
        audioHeight: 150,
        width: 300,
        visible: this.props.showMedia,
        onToggleVisibility: this.props.onToggleMediaVisibility,
        onOpenMedia: this.handleOpenMedia,
        onOpenVideo: this.handleOpenVideo,
        translationView,
        posterFallback: status.getIn(['account', 'avatar_static']),
      });
    } else if (status.get('spoiler_text').length === 0 && !isHideCard(status.getIn(['card', 'type']))) {
      media = <Card sensitive={status.get('sensitive')} onOpenMedia={this.props.onOpenMedia} card={status.get('card', null)} />;
    }

    if (status.get('application')) {
      applicationLink = <Fragment> · <a className='detailed-status__application' href={status.getIn(['application', 'website'])} target='_blank' rel='noopener noreferrer'>{status.getIn(['application', 'name'])}</a></Fragment>;
    }

    const visibilityIconInfo = {
      'public': { icon: 'globe', text: intl.formatMessage(messages.public_short) },
      'unlisted': { icon: 'unlock', text: intl.formatMessage(messages.unlisted_short) },
      'private': { icon: 'lock', text: intl.formatMessage(messages.private_short) },
      'mutual': { icon: 'exchange', text: intl.formatMessage(messages.mutual_short) },
      'limited': { icon: 'user-circle', text: intl.formatMessage(messages.limited_short) },
      'direct': { icon: 'envelope', text: intl.formatMessage(messages.direct_short) },
      'personal': { icon: 'book', text: intl.formatMessage(messages.personal_short) },
      'external': { icon: 'external-link', text: intl.formatMessage(messages.external_short) },
    };

    const visibilityIcon = visibilityIconInfo[status.get('visibility')];
    const visibilityLink = <Fragment> · <Icon id={visibilityIcon.icon} title={visibilityIcon.text} /></Fragment>;

    if (!showReblogCount || !(['public', 'unlisted'].includes(status.get('visibility')))) {
      reblogLink = '';
    } else if (this.context.router) {
      reblogLink = (
        <Fragment>
          <Fragment> · </Fragment>
          <Link to={`/statuses/${status.get('id')}/reblogs`} className='detailed-status__link'>
            <Icon id={reblogIcon} />
            <span className='detailed-status__reblogs'>
              <AnimatedNumber value={reblogsCount} />
            </span>
          </Link>
        </Fragment>
      );
    } else {
      reblogLink = (
        <Fragment>
          <Fragment> · </Fragment>
          <a href={`/interact/${status.get('id')}?type=reblog`} className='detailed-status__link' onClick={this.handleModalLink}>
            <Icon id={reblogIcon} />
            <span className='detailed-status__reblogs'>
              <AnimatedNumber value={reblogsCount} />
            </span>
          </a>
        </Fragment>
      );
    }

    if (!showFavouritCount) {
      favouriteLink = '';
    } else if (this.context.router) {
      favouriteLink = (
        <Fragment>
          <Fragment> · </Fragment>
          <Link to={`/statuses/${status.get('id')}/favourites`} className='detailed-status__link'>
            <Icon id='star' />
            <span className='detailed-status__favorites'>
              <AnimatedNumber value={favouritesCount} />
            </span>
          </Link>
        </Fragment>
      );
    } else {
      favouriteLink = (
        <Fragment>
          <Fragment> · </Fragment>
          <a href={`/interact/${status.get('id')}?type=favourite`} className='detailed-status__link' onClick={this.handleModalLink}>
            <Icon id='star' />
            <span className='detailed-status__favorites'>
              <AnimatedNumber value={favouritesCount} />
            </span>
          </a>
        </Fragment>
      );
    }

    if (!showEmojiReactionCount) {
      emojiReactionLink = '';
    } else if (this.context.router) {
      emojiReactionLink = (
        <Fragment>
          <Fragment> · </Fragment>
          <Link to={`/statuses/${status.get('id')}/emoji_reactions`} className='detailed-status__link'>
            <Icon id='smile-o' />
            <span className='detailed-status__emoji_reactions'>
              <AnimatedNumber value={emojiReactionsCount} />
            </span>
          </Link>
        </Fragment>
      );
    }

    if (!showStatusReferredByCount) {
      statusReferredByLink = '';
    } else if (this.context.router) {
      statusReferredByLink = (
        <Fragment>
          <Fragment> · </Fragment>
          <Link to={`/statuses/${status.get('id')}/referred_by`} className='detailed-status__link'>
            <Icon id='link' />
            <span className='detailed-status__status_referred_by'>
              <AnimatedNumber value={referredByCount} />
            </span>
          </Link>
        </Fragment>
      );
    }

    const expires_at = status.get('expires_at');
    const expires_date = expires_at && new Date(expires_at);
    const expired = expires_date && expires_date.getTime() < intl.now();
    const externalIdentity = externalIdentityOf(status);

    return (
      <div style={outerStyle}>
        <div ref={this.setRef} className={classNames('detailed-status', `detailed-status-${status.get('visibility')}`, { compact, 'detailed-status-with-expiration': expires_date, 'detailed-status-expired': expired, referenced, 'context-referenced': contextReferenced })}>
          {externalIdentity ? (
            <ExternalSourceIdentity identity={externalIdentity} size={48} className='detailed-status__display-name' avatarClassName='detailed-status__display-avatar' />
          ) : (
            <a href={status.getIn(['account', 'url'])} onClick={this.handleAccountClick} data-id={status.getIn(['account', 'id'])} data-group={status.getIn(['account', 'group'])} className='detailed-status__display-name'>
              <div className='detailed-status__display-avatar'><Avatar account={status.get('account')} size={48} /></div>
              <DisplayName account={status.get('account')} localDomain={this.props.domain} />
            </a>
          )}

          <AccountContextActions status={this.props.status} hostTimelineId={this.props.contextHostId || 'status:route'} onOpen={this.props.onOpenAccountContext} />
          <StatusContent status={status} translationWrapper={this.props.status} expanded={!status.get('hidden')} onExpandedToggle={this.handleExpandedToggle} onTranslate={this.props.onTranslate && this.handleTranslate} />

          {!(status.get('hidden') && status.get('spoiler_text').length > 0) && <>
            {quote}
            {media}
          </>
          }

          {enableReaction && <EmojiReactionsBar
            status={status}
            addEmojiReaction={this.props.addEmojiReaction}
            removeEmojiReaction={this.props.removeEmojiReaction}
            reactionLimitReached={reactionLimitReached}
          />}

          <div className='detailed-status__meta'>
            <TimeLink url={externalIdentity ? externalIdentity.articleUrl : status.get('url')} external={!!externalIdentity} className='detailed-status__datetime'>
              <FormattedDate value={new Date(status.get('created_at'))} hour12={false} year='numeric' month='short' day='2-digit' hour='2-digit' minute='2-digit' />
            </TimeLink>
            <EditedTimestamp statusId={status.get('id')} timestamp={status.get('edited_at')} />
            {status.get('expires_at') &&
              <span className='detailed-status__expiration-time'>
                <time dateTime={expires_at} title={intl.formatDate(expires_date, dateFormatOptions)}>
                  <i className='fa fa-clock-o' aria-hidden='true' />
                </time>
              </span>
            }
            {visibilityLink}{applicationLink}{reblogLink}{favouriteLink}{emojiReactionLink}{statusReferredByLink}
          </div>
        </div>
      </div>
    );
  }

}
