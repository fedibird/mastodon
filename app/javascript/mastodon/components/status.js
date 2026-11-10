import React from 'react';
import { connect } from 'react-redux';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import Avatar from './avatar';
import AvatarOverlay from './avatar_overlay';
import AvatarComposite from './avatar_composite';
import AbsoluteTimestamp from './absolute_timestamp';
import RelativeTimestamp from './relative_timestamp';
import DisplayName from './display_name';
import EmojiMutedHtml, { EmojiMutedPlain, bindCustomEmojiClick, unbindCustomEmojiClick, customEmojiTarget } from './emoji_muted_html';
import ExternalSourceIdentity, { TimeLink } from './external_source_identity';
import StatusContent from './status_content';
import TimelineCardBody from './timeline_card_body';
import TimelineCardReactions, { showCardEmojiReactions } from './timeline_card_reactions';
import StatusActionBar from './status_action_bar';
import AccountContextActions from '../features/account_context/components/actions';
import AccountActionBar from './account_action_bar';
import Card from '../features/status/components/card';
import { injectIntl, defineMessages, FormattedMessage } from 'react-intl';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { ThumbnailGallery } from '../features/ui/util/async-components';
import { HotKeys } from 'react-hotkeys';
import classNames from 'classnames';
import Icon from 'mastodon/components/icon';
import EmojiReactionsBar from 'mastodon/components/emoji_reactions_bar';
import PictureInPicturePlaceholder from 'mastodon/components/picture_in_picture_placeholder';
import FilterReason from './filter_reason';
import { displayMedia, cropCardImages, enableReaction, compactReaction, cardReactionsSingleLine, cardCollapseLongText, show_reply_tree_button, enableStatusReference, disableRelativeTime, hideLinkPreview, hidePhotoPreview, hideVideoPreview, hideRebloggedBy, new_features_policy } from 'mastodon/initial_state';
import { List as ImmutableList } from 'immutable';
import MixSourceBadges from 'mastodon/features/mixes/components/source_badges';
import { galleryTranslationProps, statusTranslationView, translationDisplayStatus, TRANSLATION_MODE_BILINGUAL, TRANSLATION_MODE_ORIGINAL, TRANSLATION_MODE_TRANSLATED } from 'mastodon/utils/translation_view';
import StatusMediaStack, { firstOpenableMedia, hotkeyMediaRoot, openMediaFromHotkey } from 'mastodon/components/status_media';
import { translationRequestStatus } from 'mastodon/utils/translation_languages';
import { externalIdentityOf, externalIdentityName, externalIdentityReaderText } from 'mastodon/external_presentation';
import ExternalStatusMedia from 'mastodon/components/external_status_media';
import { assignRelease, spoilerConcealed } from 'mastodon/external_player/session';
import { isCardTimelineLayout } from 'mastodon/utils/timeline_layout';
import AltTextBadge from 'mastodon/components/alt_text_badge';
import Blurhash from 'mastodon/components/blurhash';
import Thumbhash from 'mastodon/components/thumbhash';
import { useBlurhash } from 'mastodon/initial_state';
import { defaultMediaVisibility as defaultMediaTileVisibility, mediaAspectRatio, mediaIsConcealed } from 'mastodon/utils/media_display';

const domParser = new DOMParser();

// We use the component (and not the container) since we do not want
// to use the progress bar to show download progress
import Bundle from '../features/ui/components/bundle';

export const mapStateToProps = (state, props) => {
  let status = props.status;

  if (status === null) {
    return { quote_muted: false };
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

const plainHtmlText = (html) => {
  const text = domParser.parseFromString(html || '', 'text/html').documentElement.textContent || '';

  return text.trim() ? text : '';
};

const presentText = (value) => {
  const text = value || '';

  return text.trim() ? text : '';
};

const bilingualText = (source, translated) => {
  if (source && translated) {
    return `${source} → ${translated}`;
  }

  return source || translated;
};

// Screen-reader copy stays on the shared plain extraction. replace_in_text
// for that path is a later P3-B slice, so a mute does not rewrite it here.
const screenReaderStatusText = (status) => {
  const mode = statusTranslationView(status).mode;
  const sourceSpoiler = status.get('spoiler_text') || '';
  const translatedSpoiler = presentText(status.getIn(['translation', 'spoiler_text']));
  const sourceBody = (status.get('search_index') || '').slice(sourceSpoiler.length);
  const translatedBody = plainHtmlText(status.getIn(['translation', 'contentHtml']));
  const hiddenSpoiler = mode === TRANSLATION_MODE_ORIGINAL ? sourceSpoiler : (sourceSpoiler || translatedSpoiler);

  const read = (source, translated) => {
    if (mode === TRANSLATION_MODE_TRANSLATED) {
      return translated || source;
    }

    if (mode === TRANSLATION_MODE_BILINGUAL) {
      return bilingualText(source, translated);
    }

    return source;
  };

  if (status.get('hidden') && hiddenSpoiler) {
    return read(sourceSpoiler, translatedSpoiler);
  }

  return read(sourceBody, translatedBody);
};

export const textForScreenReader = (intl, status, rebloggedByText = false) => {
  const externalIdentity = externalIdentityOf(status);

  if (externalIdentity) {
    const externalValues = [
      externalIdentityReaderText(intl, externalIdentity),
      screenReaderStatusText(status),
      intl.formatDate(status.get('created_at'), { hour: '2-digit', minute: '2-digit', month: 'short', day: 'numeric' }),
    ];

    if (rebloggedByText) {
      externalValues.push(rebloggedByText);
    }

    return externalValues.join(', ');
  }

  const displayName = status.getIn(['account', 'display_name']);

  const values = [
    displayName.length === 0 ? status.getIn(['account', 'acct']).split('@')[0] : displayName,
    screenReaderStatusText(status),
    intl.formatDate(status.get('created_at'), { hour: '2-digit', minute: '2-digit', month: 'short', day: 'numeric' }),
    status.getIn(['account', 'acct']),
  ];

  if (rebloggedByText) {
    values.push(rebloggedByText);
  }

  return values.join(', ');
};

export const displayedStatus = (status) => {
  if (!status || typeof status.get !== 'function') {
    return status;
  }

  const reblog = status.get('reblog', null);
  if (reblog && typeof reblog.get === 'function') {
    return reblog;
  }

  return status;
};

export const defaultMediaVisibility = (status) => {
  const shown = displayedStatus(status);
  if (!shown || typeof shown.get !== 'function') {
    return undefined;
  }

  return (displayMedia !== 'hide_all' && !shown.get('sensitive') || displayMedia === 'show_all');
};

const quoteOf = (status) => {
  if (!status || typeof status.get !== 'function') {
    return null;
  }

  const quote = status.get('quote', null);
  return quote && typeof quote.get === 'function' ? quote : null;
};

// Shared by the timeline card and the detail column. An update that keeps
// the status id still resets media when that status, or its quote, becomes
// sensitive. idKey is statusId on the card and loadedStatusId on the detail.
export const nextShownMediaState = (prevState, status, idKey = 'statusId') => {
  const shown = displayedStatus(status);
  if (!status || typeof status.get !== 'function' || !shown || typeof shown.get !== 'function') {
    return null;
  }

  const quote = quoteOf(shown);
  const sensitive = !!shown.get('sensitive');
  const quoteSensitive = !!(quote && quote.get('sensitive'));
  if (status.get('id') !== prevState[idKey]) {
    return {
      showMedia: defaultMediaVisibility(status),
      showQuoteMedia: defaultMediaVisibility(quote),
      [idKey]: status.get('id'),
      sensitive,
      quoteSensitive,
      forceFilter: undefined,
    };
  }

  const next = {};
  if (sensitive !== !!prevState.sensitive) {
    next.showMedia = defaultMediaVisibility(status);
    next.sensitive = sensitive;
  }
  if (quoteSensitive !== !!prevState.quoteSensitive) {
    next.showQuoteMedia = defaultMediaVisibility(quote);
    next.quoteSensitive = quoteSensitive;
  }
  return Object.keys(next).length > 0 ? next : null;
};

export const isHideCard = (type) => {
  switch(type) {
  case 'link':
    return hideLinkPreview;
  case 'photo':
    return hidePhotoPreview;
  case 'video':
    return hideVideoPreview;
  default:
    return false;
  }
};

const messages = defineMessages({
  public_short: { id: 'privacy.public.short', defaultMessage: 'Public' },
  unlisted_short: { id: 'privacy.unlisted.short', defaultMessage: 'Unlisted' },
  private_short: { id: 'privacy.private.short', defaultMessage: 'Followers-only' },
  mutual_short: { id: 'privacy.mutual.short', defaultMessage: 'Mutual-followers-only' },
  personal_short: { id: 'privacy.personal.short', defaultMessage: 'Personal' },
  external_short: { id: 'privacy.external.short', defaultMessage: 'External content (only you)' },
  limited_short: { id: 'privacy.limited.short', defaultMessage: 'Circle' },
  direct_short: { id: 'privacy.direct.short', defaultMessage: 'Direct' },
  mark_ancestor: { id: 'thread_mark.ancestor', defaultMessage: 'Has reference' },
  mark_descendant: { id: 'thread_mark.descendant', defaultMessage: 'Has reply' },
  mark_both: { id: 'thread_mark.both', defaultMessage: 'Has reference and reply' },
  edited: { id: 'status.edited', defaultMessage: 'Edited {date}' },
  revealMediaTile: { id: 'timeline.media.reveal', defaultMessage: 'Reveal media' },
  openMediaTile: { id: 'timeline.media.open', defaultMessage: 'Open media' },
  openMediaSource: { id: 'timeline.media.open_post', defaultMessage: 'Open original post' },
  cardMediaCount: { id: 'timeline.card.media_count', defaultMessage: '{count} media attachments' },
  cardExpandText: { id: 'timeline.card.expand_text', defaultMessage: 'Show full post text' },
  cardScrollText: { id: 'timeline.card.scroll_text', defaultMessage: 'Hold to scroll post text' },
  cardExpandReactions: { id: 'timeline.card.expand_reactions', defaultMessage: 'Show all emoji reactions' },
  cardScrollReactions: { id: 'timeline.card.scroll_reactions', defaultMessage: 'Scrollable emoji reactions' },
});

const dateFormatOptions = {
  hour12: false,
  year: 'numeric',
  month: 'short',
  day: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
};

class Status extends ImmutablePureComponent {

  static contextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    status: ImmutablePropTypes.map,
    account: ImmutablePropTypes.map,
    otherAccounts: ImmutablePropTypes.list,
    referenced: PropTypes.bool,
    contextReferenced: PropTypes.bool,
    quote_muted: PropTypes.bool,
    onClick: PropTypes.func,
    onReply: PropTypes.func,
    onFavourite: PropTypes.func,
    onReblog: PropTypes.func,
    onDelete: PropTypes.func,
    onExpire: PropTypes.func,
    onDirect: PropTypes.func,
    onMemberList: PropTypes.func,
    onMention: PropTypes.func,
    onPin: PropTypes.func,
    onOpenMedia: PropTypes.func,
    onOpenVideo: PropTypes.func,
    onBlock: PropTypes.func,
    onEmbed: PropTypes.func,
    onHeightChange: PropTypes.func,
    onToggleHidden: PropTypes.func,
    onToggleCollapsed: PropTypes.func,
    onTranslate: PropTypes.func,
    onReference: PropTypes.func,
    onAddToList: PropTypes.func.isRequired,
    muted: PropTypes.bool,
    hidden: PropTypes.bool,
    unread: PropTypes.bool,
    onMoveUp: PropTypes.func,
    onMoveDown: PropTypes.func,
    showThread: PropTypes.bool,
    showCard: PropTypes.bool,
    getScrollPosition: PropTypes.func,
    updateScrollBottom: PropTypes.func,
    cacheMediaWidth: PropTypes.func,
    cachedMediaWidth: PropTypes.number,
    scrollKey: PropTypes.string,
    deployPictureInPicture: PropTypes.func,
    pictureInPicture: ImmutablePropTypes.contains({
      inUse: PropTypes.bool,
      available: PropTypes.bool,
    }),
    contextType: PropTypes.string,
    addEmojiReaction: PropTypes.func.isRequired,
    removeEmojiReaction: PropTypes.func.isRequired,
    emojiReactioned: PropTypes.bool,
    reactionLimitReached: PropTypes.bool,
    sourceBadges: PropTypes.array,
    immediate: PropTypes.bool,
    layoutMode: PropTypes.string,
    mediaIndex: PropTypes.number,
    mediaShape: PropTypes.oneOf(['square', 'original']),
    mediaVisibility: PropTypes.oneOf(['hide_sensitive', 'show_all', 'hide_all']),
    mediaRowKey: PropTypes.string,
    mediaTimeline: PropTypes.object,
    mediaSource: PropTypes.object,
    onMediaTileReveal: PropTypes.func,
    mediaTileRevealed: PropTypes.bool,
    onMediaFilterReveal: PropTypes.func,
    mediaFilterRevealed: PropTypes.bool,
  };

  static defaultProps = {
    showCard: true,
  };

  // Avoid checking props that are functions (and whose equality will always
  // evaluate to false. See react-immutable-pure-component for usage.
  updateOnProps = [
    'status',
    'account',
    'muted',
    'hidden',
    'unread',
    'pictureInPicture',
    'referenced',
    'contextReferenced',
    'quote_muted',
    'sourceBadges',
    'immediate',
    'layoutMode',
    'mediaIndex',
    'mediaShape',
    'mediaVisibility',
    'mediaSource',
  ];

  state = {
    showMedia: defaultMediaVisibility(this.props.status),
    showQuoteMedia: defaultMediaVisibility(this.props.status ? this.props.status.get('quote', null) : null),
    statusId: undefined,
    forceFilter: undefined,
    tileRevealed: false,
    tileVisibility: this.props.mediaVisibility,
    tileIndex: this.props.mediaIndex,
  };

  static getDerivedStateFromProps(nextProps, prevState) {
    const changes = nextShownMediaState(prevState, nextProps.status, 'statusId');
    const statusId = nextProps.status && nextProps.status.get('id');
    const resetTile = nextProps.mediaVisibility !== prevState.tileVisibility ||
      nextProps.mediaIndex !== prevState.tileIndex || (statusId && statusId !== prevState.statusId);

    return resetTile ? {
      ...changes,
      tileRevealed: false,
      tileVisibility: nextProps.mediaVisibility,
      tileIndex: nextProps.mediaIndex,
    } : changes;
  }

  componentDidMount () {
    this._updateEmojiLinks();
  }

  componentDidUpdate () {
    this._updateEmojiLinks();
  }

  componentWillUnmount () {
    this._removeEmojiLinks();
  }

  _updateEmojiLinks () {
    bindCustomEmojiClick(this.emoji_node, this.handleEmojiClick);
  }

  _removeEmojiLinks () {
    unbindCustomEmojiClick(this.emoji_node, this.handleEmojiClick);
  }

  handleEmojiClick = e => {
    const emoji = customEmojiTarget(e);

    if (!emoji || !this.emoji_node || !this.emoji_node.contains(emoji)) {
      return;
    }

    const shortcode = emoji.getAttribute('data-shortcode');
    const domain = emoji.getAttribute('data-domain');

    if (this.context.router) {
      e.preventDefault();
      e.stopPropagation();
      this.context.router.history.push(`/emoji_detail/${shortcode}${domain ? `@${domain}` : ''}`);
    }
  }

  handleToggleMediaVisibility = () => {
    this.setState({ showMedia: !this.state.showMedia });
  }

  handleToggleQuoteMediaVisibility = () => {
    this.setState({ showQuoteMedia: !this.state.showQuoteMedia });
  }

  handleClick = () => {
    if (this.props.onClick) {
      this.props.onClick();
      return;
    }

    if (!this.context.router) {
      return;
    }

    const { status } = this.props;
    this.context.router.history.push(`/statuses/${status.getIn(['reblog', 'id'], status.get('id'))}`);
  }

  handleExpandClick = (e) => {
    if (this.props.onClick) {
      this.props.onClick();
      return;
    }

    if (e.button === 0) {
      if (!this.context.router) {
        return;
      }

      const { status } = this.props;
      this.context.router.history.push(`/statuses/${status.getIn(['reblog', 'id'], status.get('id'))}`);
    }
  }

  handleQuoteClick = () => {
    if (!this.context.router) {
      return;
    }

    const { status } = this.props;
    this.context.router.history.push(`/statuses/${status.getIn(['reblog', 'quote', 'id'], status.getIn(['quote', 'id']))}`);
  }

  handleAccountClick = (e) => {
    if (this.context.router && e.button === 0 && !(e.ctrlKey || e.metaKey)) {
      const id = e.currentTarget.getAttribute('data-id');
      const group = e.currentTarget.getAttribute('data-group') !== 'false';
      e.preventDefault();
      if (group) {
        this.context.router.history.push(`/timelines/groups/${id}`);
      } else {
        this.context.router.history.push(`/accounts/${id}`);
      }
    }
  }

  handleExpandedToggle = () => {
    this.props.onToggleHidden(this._properStatus());
  }

  handleCollapsedToggle = isCollapsed => {
    this.props.onToggleCollapsed(this._properStatus(), isCollapsed);
  }

  handleUnfilterClick = e => {
    this.setState({ forceFilter: false });
    this.props.onMediaFilterReveal?.(this.props.status.get('id'));
    e.preventDefault();
    e.stopPropagation();
  }

  handleFilterClick = () => {
    this.setState({ forceFilter: true });
  }

  handleExpandedQuoteToggle = () => {
    this.props.onToggleHidden(this._properQuoteStatus());
  }

  renderLoadingThumbnailGallery () {
    return <div className='thumbnail-gallery' style={{ height: '20px' }} />;
  }

  handleTranslate = (mode) => {
    const requestStatus = translationRequestStatus(this.props.status);

    if (!this.props.onTranslate || !requestStatus) {
      return;
    }

    this.props.onTranslate(requestStatus, mode);
  }

  handleQuoteTranslate = (mode) => {
    const quote = this._properQuoteStatus();

    if (quote && quote.get('translation') && this.props.onTranslate) {
      this.props.onTranslate(quote, mode);
    }
  }

  handleOpenVideo = (attachment, options) => {
    const status = this._properStatus();
    const lang = statusTranslationView(this._translationMediaStatus()).mediaLang;
    this.props.onOpenVideo(status.get('id'), attachment, options, lang);
  }

  handleOpenSavedVideo = (attachment, options) => {
    this.handleOpenVideo(attachment, options);
  }

  handleOpenVideoQuote = (attachment, options) => {
    const status = this._properQuoteStatus();
    const lang = statusTranslationView(status).mediaLang;
    this.props.onOpenVideo(status.get('id'), attachment, options, lang);
  }

  handleOpenMedia = (media, index) => {
    const status = this._properStatus();
    const lang = statusTranslationView(this._translationMediaStatus()).mediaLang;
    this.props.onOpenMedia(status.get('id'), media, index, lang);
  }

  handleOpenMediaQuote = (media, index) => {
    const status = this._properQuoteStatus();
    const lang = statusTranslationView(status).mediaLang;
    this.props.onOpenMedia(status.get('id'), media, index, lang);
  }

  handleOpenCardMedia = () => {
    // Only one thumbnail is rendered on a card; the modal must still receive
    // every image/GIF from the post so its navigation is not limited to one.
    const target = firstOpenableMedia(this._translationMediaStatus().get('media_attachments', ImmutableList()));

    if (target && target.kind === 'gallery') {
      this.handleOpenMedia(target.media, target.index);
    }
  }

  handleHotkeyOpenMedia = e => {
    const status = this._properStatus();

    e.preventDefault();

    const mediaStatus = this._translationMediaStatus();
    const lang = statusTranslationView(mediaStatus).mediaLang;

    openMediaFromHotkey({
      attachments: mediaStatus.get('media_attachments'),
      root: hotkeyMediaRoot(e, this.node),
      openGallery: (media, index) => {
        if (this.props.onOpenMedia) {
          this.props.onOpenMedia(status.get('id'), media, index, lang);
        }
      },
      openVideo: (attachment, options) => {
        if (this.props.onOpenVideo) {
          this.props.onOpenVideo(status.get('id'), attachment, options, lang);
        }
      },
    });
  }

  renderAttachmentMedia (mediaStatus, options) {
    const translation = galleryTranslationProps(options.translationView);

    return (
      <StatusMediaStack
        media={mediaStatus.get('media_attachments')}
        sensitive={options.sensitive}
        height={options.height}
        videoHeight={options.videoHeight}
        audioHeight={options.audioHeight}
        visible={options.visible}
        onToggleVisibility={options.onToggleVisibility}
        onOpenMedia={options.onOpenMedia}
        onOpenVideo={options.onOpenVideo}
        cacheWidth={this.props.cacheMediaWidth}
        defaultWidth={this.props.cachedMediaWidth}
        deployPictureInPicture={options.deployPictureInPicture}
        quote={options.quote}
        posterFallback={options.posterFallback}
        cropImages={options.cropImages}
        lang={translation.lang}
        translationMode={translation.translationMode}
        sourceLang={translation.sourceLang}
        targetLang={translation.targetLang}
      />
    );
  }

  handleDeployPictureInPicture = (type, mediaProps) => {
    const { deployPictureInPicture } = this.props;
    const status = this._properStatus();

    deployPictureInPicture(status, type, mediaProps);
  }

  handleHotkeyReply = e => {
    e.preventDefault();
    const status = this._properStatus();

    if (status && status.get('visibility') === 'external') {
      return;
    }

    this.props.onReply(status, this.context.router.history);
  }

  handleHotkeyFavourite = () => {
    this.props.onFavourite(this._properStatus());
  }

  handleHotkeyBoost = e => {
    this.props.onReblog(this._properStatus(), e);
  }

  handleHotkeyMention = e => {
    e.preventDefault();
    const status = this._properStatus();

    // The Account of an external projection is the owner. It is not the author.
    if (externalIdentityOf(status)) {
      return;
    }

    this.props.onMention(status.get('account'), this.context.router.history);
  }

  handleHotkeyOpen = () => {
    this.context.router.history.push(`/statuses/${this._properStatus().get('id')}`);
  }

  handleHotkeyOpenProfile = () => {
    const status = this._properStatus();

    if (externalIdentityOf(status)) {
      return;
    }

    this.context.router.history.push(`/accounts/${status.getIn(['account', 'id'])}`);
  }

  handleHotkeyMoveUp = e => {
    this.props.onMoveUp(this.props.status.get('id'), e.target.getAttribute('data-featured'));
  }

  handleHotkeyMoveDown = e => {
    this.props.onMoveDown(this.props.status.get('id'), e.target.getAttribute('data-featured'));
  }

  handleHotkeyToggleHidden = () => {
    this.props.onToggleHidden(this._properStatus());
  }

  handleHotkeyToggleSensitive = () => {
    this.handleToggleMediaVisibility();
  }

  _translationMediaStatus () {
    return translationDisplayStatus(this._properStatus(), this.props.status);
  }

  _properStatus () {
    const { status } = this.props;

    if (status.get('reblog', null) !== null && typeof status.get('reblog') === 'object') {
      return status.get('reblog');
    } else {
      return status;
    }
  }

  _properQuoteStatus () {
    const status = this._properStatus();

    if (status.get('quote', null) !== null && typeof status.get('quote') === 'object') {
      return status.get('quote');
    } else {
      return status;
    }
  }

  handleRef = c => {
    this.node = c;
  }

  emojiRef = c => {
    if (c === this.emoji_node) {
      return;
    }

    unbindCustomEmojiClick(this.emoji_node, this.handleEmojiClick);
    this.emoji_node = c;
    bindCustomEmojiClick(this.emoji_node, this.handleEmojiClick);
  }


  handleTimelineCardClick = event => {
    const target = event.target;
    if (target && typeof target.closest === 'function' && target.closest('a, button, [role="button"], .quote-status')) {
      return;
    }

    this.handleClick();
  }

  handleTimelineQuoteClick = event => {
    event.stopPropagation();
    this.handleQuoteClick();
  }

  handleTimelineQuoteKeyDown = event => {
    if (event.key === 'Enter' || event.key === ' ') {
      event.preventDefault();
      event.stopPropagation();
      this.handleQuoteClick();
    }
  }

  renderTimelineCard () {
    const { status: original, intl, otherAccounts, account, contextType, scrollKey, quote_muted, reactionLimitReached, sourceBadges } = this.props;
    const status = this._properStatus();
    const externalIdentity = externalIdentityOf(status);
    const hasSpoiler = !!status.get('spoiler_text');
    const contentVisible = !hasSpoiler || !status.get('hidden');
    const media = status.get('media_attachments', ImmutableList());
    // The add-reaction control always stays beside favourite. Counts stay off
    // the card when compact reactions are on, including a zero-count row.
    const hasVisibleEmojiReactions = status.get('emoji_reactions', ImmutableList()).some(reaction => reaction.get('count', 0) > 0);
    const showReactions = showCardEmojiReactions(enableReaction, hasVisibleEmojiReactions, compactReaction);
    const firstMedia = contentVisible && media && media.size > 0
      ? this.renderAttachmentMedia(status.set('media_attachments', media.take(1)), {
        sensitive: status.get('sensitive'),
        height: 160,
        videoHeight: 160,
        audioHeight: 100,
        visible: this.state.showMedia,
        onToggleVisibility: this.handleToggleMediaVisibility,
        onOpenMedia: this.handleOpenCardMedia,
        onOpenVideo: this.handleOpenVideo,
        translationView: statusTranslationView(status),
        posterFallback: status.getIn(['account', 'avatar_static']),
        cropImages: cropCardImages,
      })
      : null;

    const quote = status.get('quote');
    const hiddenQuote = quote && quote_muted;
    const unlistedQuote = quote && quote.get('visibility') === 'unlisted' &&
      !!contextType && ['public', 'community', 'hashtag'].includes(contextType.split(':', 2)[0]);
    // A concealed quote (muted account, or unlisted on a public timeline)
    // never contributes its text. A CW uses the spoiler string until that
    // spoiler HTML actually replaces an emoji. Other previews keep
    // textContent, so an unmuted image alt does not change the card height.
    let quotePreviewSource = null;

    if (quote && !hiddenQuote && !unlistedQuote) {
      quotePreviewSource = quote.get('hidden') && quote.get('spoiler_text')
        ? { plain: quote.get('spoiler_text'), html: quote.get('spoilerHtml') || '' }
        : { plain: plainHtmlText(quote.get('contentHtml')), html: quote.get('contentHtml') || '' };
    }

    let quotePreview = null;
    if (quote) {
      if (hiddenQuote) {
        quotePreview = <FormattedMessage id='status.muted_quote' defaultMessage='Muted quote' />;
      } else if (unlistedQuote) {
        quotePreview = <FormattedMessage id='status.unlisted_quote' defaultMessage='Unlisted quote' />;
      } else {
        quotePreview = (
          <>
            {quote.get('account') && <div className='timeline-card__quote-author'>
              <Avatar account={quote.get('account')} size={18} />
              <DisplayName account={quote.get('account')} />
            </div>}
            <EmojiMutedPlain tag='p' className='timeline-card__quote-text' plain={quotePreviewSource.plain} html={quotePreviewSource.html} />
          </>
        );
      }
    }

    const quoteBody = contentVisible && quote ? (
      <div
        className='timeline-card__quote'
        onClick={this.handleTimelineQuoteClick}
        onKeyDown={this.handleTimelineQuoteKeyDown}
        role='button'
        tabIndex='0'
      >
        {quotePreview}
      </div>
    ) : null;

    const linkPreview = contentVisible && !quote && status.get('card') && !isHideCard(status.getIn(['card', 'type'])) ? (
      <div className='timeline-card__preview'>
        <Card
          onOpenMedia={this.handleOpenMedia}
          card={status.get('card')}
          compact
          maxDescription={50}
          cacheWidth={this.props.cacheMediaWidth}
          defaultWidth={this.props.cachedMediaWidth}
          sensitive={status.get('sensitive')}
        />
      </div>
    ) : null;

    const expiresAt = status.get('expires_at');
    const expired = expiresAt && new Date(expiresAt).getTime() < intl.now();
    const reblog = original.get('reblog');
    const booster = reblog && typeof reblog.get === 'function' ? original.get('account') : null;
    let cardContext = null;

    if (this.props.featured) {
      cardContext = (
        <div className='timeline-card__context'>
          <Icon id='thumb-tack' fixedWidth />
          <FormattedMessage id='status.pinned' defaultMessage='Pinned toot' />
        </div>
      );
    } else if (booster && !hideRebloggedBy) {
      // Only the server-sanitized HTML field is safe for custom emoji markup;
      // the plain display-name fallback must remain escaped React text.
      const boosterNameHtml = booster.get('display_name_html');
      const boosterName = boosterNameHtml
        ? <EmojiMutedHtml tag='strong' html={boosterNameHtml} />
        : <strong>{booster.get('display_name') || booster.get('username') || booster.get('acct')}</strong>;
      const name = (
        <a
          href={booster.get('url')}
          data-id={booster.get('id')}
          data-group={booster.get('group')}
          className='timeline-card__context-account status__display-name'
          onClick={this.handleAccountClick}
        >
          <bdi>{boosterName}</bdi>
        </a>
      );
      cardContext = (
        <div className='timeline-card__context'>
          <Icon id='retweet' fixedWidth />
          <FormattedMessage id='status.reblogged_by' defaultMessage='{name} boosted' values={{ name }} />
        </div>
      );
    }

    const boosterDescription = booster && !hideRebloggedBy
      ? intl.formatMessage({ id: 'status.reblogged_by', defaultMessage: '{name} boosted' }, { name: booster.get('acct') })
      : false;

    return (
      <HotKeys handlers={{ open: this.handleHotkeyOpen, favourite: this.handleHotkeyFavourite, moveUp: this.handleHotkeyMoveUp, moveDown: this.handleHotkeyMoveDown }}>
        <div className='status__wrapper status__wrapper--compact focusable' tabIndex='0' data-id={status.get('id')} aria-label={textForScreenReader(intl, status, boosterDescription)} ref={this.handleRef} onClick={this.handleTimelineCardClick}>
          <div className='timeline-card'>
            {firstMedia && <div className='timeline-card__media'>
              {firstMedia}
              {media.size > 1 && (
                <span
                  className='timeline-card__media-count'
                  role='img'
                  aria-label={intl.formatMessage(messages.cardMediaCount, { count: media.size })}
                >
                  <span aria-hidden='true'><Icon id='clone' fixedWidth /> {media.size}</span>
                </span>
              )}
            </div>}
            <TimelineCardBody
              key={status.get('id')}
              expandLabel={intl.formatMessage(messages.cardExpandText)}
              scrollLabel={intl.formatMessage(messages.cardScrollText)}
              collapseLongText={cardCollapseLongText !== false}
            >
              <StatusContent status={status} translationWrapper={original} onClick={this.handleClick} expanded={!status.get('hidden')} onExpandedToggle={this.handleExpandedToggle} compactCard />
            </TimelineCardBody>
            {quoteBody}
            {linkPreview}
            {cardContext}
            <div className='timeline-card__author'>
              {externalIdentity ? (
                <ExternalSourceIdentity identity={externalIdentity} size={26} showLabel={false} />
              ) : (
                <a href={status.getIn(['account', 'url'])} data-id={status.getIn(['account', 'id'])} data-group={status.getIn(['account', 'group'])} onClick={this.handleAccountClick} className='status__display-name timeline-card__author-link'>
                  <Avatar account={status.get('account')} size={26} />
                  <DisplayName account={status.get('account')} others={otherAccounts} />
                </a>
              )}
              {sourceBadges && sourceBadges.length > 0 && <MixSourceBadges badges={sourceBadges} />}
              <div className='timeline-card__author-actions'>
                <StatusActionBar status={status} account={account} scrollKey={scrollKey} compactCardMode='favourite' expired={expired} onFavourite={this.props.onFavourite} />
                {enableReaction && <StatusActionBar status={status} account={account} scrollKey={scrollKey} compactCardMode='reactions' expired={expired} addEmojiReaction={this.props.addEmojiReaction} removeEmojiReaction={this.props.removeEmojiReaction} emojiReactioned={this.props.emojiReactioned} reactionLimitReached={reactionLimitReached} />}
              </div>
            </div>
            {showReactions && (
              <TimelineCardReactions
                singleLine={cardReactionsSingleLine !== false}
                expandLabel={intl.formatMessage(messages.cardExpandReactions)}
                scrollLabel={intl.formatMessage(messages.cardScrollReactions)}
              >
                <EmojiReactionsBar status={status} addEmojiReaction={this.props.addEmojiReaction} removeEmojiReaction={this.props.removeEmojiReaction} reactionLimitReached={reactionLimitReached} />
              </TimelineCardReactions>
            )}
          </div>
        </div>
      </HotKeys>
    );
  }

  mediaTileConcealed = () => {
    const status = this._properStatus();
    const policy = this.props.mediaVisibility || defaultMediaTileVisibility();
    return mediaIsConcealed(policy, status.get('sensitive'), this.state.tileRevealed || this.props.mediaTileRevealed);
  }

  handleMediaTileClick = event => {
    event.stopPropagation();
    const status = this._properStatus();
    const media = status.get('media_attachments', ImmutableList());
    const attachment = media.get(this.props.mediaIndex);

    if (!attachment) {
      return;
    }

    if (this.mediaTileConcealed()) {
      // Reveal this one tile only, without changing the user's media policy.
      this.setState({ tileRevealed: true });
      this.props.onMediaTileReveal?.(this.props.mediaRowKey);
      return;
    }

    const type = attachment.get('type');
    if (type === 'video') {
      this.handleOpenVideo(attachment, { startTime: 0 });
    } else if (type === 'image' || type === 'gifv') {
      const sequence = this.props.mediaTimeline;
      const position = sequence && sequence.positions[this.props.mediaRowKey];

      if (Number.isInteger(position) && this.props.onOpenMedia && sequence.media.size > 0) {
        // Sequence contains only currently loaded, view-visible image/GIF tiles.
        // Preserve per-post attribution as the viewer advances across posts.
        this.props.onOpenMedia(
          status.get('id'),
          sequence.media,
          position,
          statusTranslationView(status).mediaLang,
          sequence.statusIds,
          this.props.mediaSource,
        );
      } else {
        // If the selected tile was revealed individually, do not let the
        // modal disclose concealed siblings from the same post either.
        this.handleOpenMedia(ImmutableList([attachment]), 0);
      }
    } else {
      // Audio and unknown attachment types have players on the full post.
      this.handleClick();
    }
  }

  renderMediaTile () {
    const status = this._properStatus();
    const media = status.get('media_attachments', ImmutableList());
    const attachment = media.get(this.props.mediaIndex);

    if (!attachment) {
      return null;
    }

    const original = this.props.mediaShape === 'original';
    const concealed = this.mediaTileConcealed();
    const preview = attachment.get('preview_url') || (attachment.get('type') === 'image' ? attachment.get('url') : null);
    const canPreview = !concealed && preview && ['image', 'gifv', 'video'].includes(attachment.get('type'));
    const description = attachment.get('description');
    const alt = description || status.getIn(['account', 'display_name']) || status.getIn(['account', 'username']) || '';
    const externalIdentity = externalIdentityOf(status);
    const aspect = original && mediaAspectRatio(attachment);
    const itemStyle = aspect ? { aspectRatio: String(aspect) } : undefined;
    const hash = attachment.get('blurhash');
    const thumbnailHash = attachment.get('thumbhash');
    const blurred = concealed && useBlurhash && (hash || thumbnailHash);

    let mediaTileContent;
    if (canPreview) {
      mediaTileContent = <img src={preview} alt={alt} loading='lazy' />;
    } else if (blurred) {
      mediaTileContent = hash
        ? <Blurhash className='timeline-media-tile__blurhash' hash={hash} />
        : <Thumbhash className='timeline-media-tile__blurhash' hash={thumbnailHash} />;
    } else {
      let placeholderIcon = 'file-o';
      if (concealed) {
        placeholderIcon = 'eye-slash';
      } else if (attachment.get('type') === 'audio') {
        placeholderIcon = 'music';
      }

      mediaTileContent = (
        <span className='timeline-media-tile__placeholder'>
          <Icon id={placeholderIcon} />
        </span>
      );
    }

    return (
      <div className='status__wrapper status__wrapper--media-tile' data-id={status.get('id')} ref={this.handleRef}>
        <div className='timeline-media-tile'>
          <div className='timeline-media-tile__preview'>
            <button
              type='button'
              className={classNames('timeline-media-tile__open', { 'timeline-media-tile__open--original': original })}
              style={itemStyle}
              onClick={this.handleMediaTileClick}
              aria-label={concealed ? this.props.intl.formatMessage(messages.revealMediaTile) : (alt || this.props.intl.formatMessage(messages.openMediaTile))}
            >
              {mediaTileContent}
              {blurred && <span className='timeline-media-tile__concealed-icon'><Icon id='eye-slash' /></span>}
              {!concealed && attachment.get('type') === 'video' && <span className='timeline-media-tile__play'><Icon id='play' /></span>}
            </button>
            {description && <div className='media-gallery__item__badges'>
              <AltTextBadge description={description} />
            </div>}
          </div>
          <button type='button' className='timeline-media-tile__source' onClick={this.handleClick} title={this.props.intl.formatMessage(messages.openMediaSource)}>
            {externalIdentity ? externalIdentityName(this.props.intl, externalIdentity) : (status.getIn(['account', 'display_name']) || status.getIn(['account', 'username']))}
          </button>
        </div>
      </div>
    );
  }

  render () {
    let media = null;
    let statusAvatar, prepend, rebloggedByText;

    const { intl, hidden, featured, otherAccounts, unread, showThread, showCard, scrollKey, pictureInPicture, contextType, quote_muted, referenced, contextReferenced, reactionLimitReached, layoutMode } = this.props;

    let { status, account, sourceBadges, ...other } = this.props;

    if (status === null) {
      return null;
    }

    const handlers = this.props.muted ? {} : {
      reply: this.handleHotkeyReply,
      favourite: this.handleHotkeyFavourite,
      boost: this.handleHotkeyBoost,
      mention: this.handleHotkeyMention,
      open: this.handleHotkeyOpen,
      openProfile: this.handleHotkeyOpenProfile,
      moveUp: this.handleHotkeyMoveUp,
      moveDown: this.handleHotkeyMoveDown,
      toggleHidden: this.handleHotkeyToggleHidden,
      toggleSensitive: this.handleHotkeyToggleSensitive,
      openMedia: this.handleHotkeyOpenMedia,
    };

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

    if (hidden) {
      const hiddenExternalIdentity = externalIdentityOf(status);

      return (
        <HotKeys handlers={handlers}>
          <div ref={this.handleRef} className={classNames('status__wrapper', { focusable: !this.props.muted })} tabIndex='0'>
            <span>{hiddenExternalIdentity ? externalIdentityName(intl, hiddenExternalIdentity) : (status.getIn(['account', 'display_name']) || status.getIn(['account', 'username']))}</span>
            <span>{status.get('content')}</span>
          </div>
        </HotKeys>
      );
    }

    const matchedFilters = status.get('matched_filters');
    const hasMatchedFilters = ImmutableList.isList(matchedFilters) ? !matchedFilters.isEmpty() : !!matchedFilters;
    const shouldFilter = hasMatchedFilters && this.state.forceFilter !== false && !this.props.mediaFilterRevealed;

    if (shouldFilter) {
      const minHandlers = this.props.muted ? {} : {
        moveUp: this.handleHotkeyMoveUp,
        moveDown: this.handleHotkeyMoveDown,
      };

      return (
        <HotKeys handlers={minHandlers}>
          <div className='status__wrapper status__wrapper--filtered focusable' tabIndex='0' ref={this.handleRef}>
            <FormattedMessage id='status.filtered' defaultMessage='Filtered' />
            : <FilterReason titles={matchedFilters} />.
            {' '}
            <button type='button' className='status__wrapper--filtered__button' onClick={this.handleUnfilterClick}>
              <FormattedMessage id='status.show_filter_reason' defaultMessage='Show anyway' />
            </button>
          </div>
        </HotKeys>
      );
    }

    if (layoutMode === 'media') {
      return this.renderMediaTile();
    }

    if (isCardTimelineLayout(layoutMode)) {
      return this.renderTimelineCard();
    }

    if (featured) {
      prepend = (
        <div className='status__prepend' ref={this.emojiRef}>
          <div className='status__prepend-icon-wrapper'><Icon id='thumb-tack' className='status__prepend-icon' fixedWidth /></div>
          <FormattedMessage id='status.pinned' defaultMessage='Pinned toot' />
        </div>
      );
    } else if (status.get('reblog', null) !== null && typeof status.get('reblog') === 'object') {
      if (!hideRebloggedBy) {
        const visibilityReblogIcon = visibilityIconInfo[status.get('visibility')];
        const visibilityReblogLink = <Icon id={visibilityReblogIcon.icon} className='status__prepend-icon' title={visibilityReblogIcon.text} />;

        prepend = (
          <div className='status__prepend' ref={this.emojiRef}>
            <div className='status__prepend-icon-wrapper'><Icon id='retweet' className='status__prepend-icon' fixedWidth /></div>
            <FormattedMessage id='status.reblogged_by' defaultMessage='{name} boosted' values={{ name: <a onClick={this.handleAccountClick} data-id={status.getIn(['account', 'id'])} data-group={status.getIn(['account', 'group'])} href={status.getIn(['account', 'url'])} className='status__display-name muted'><bdi><EmojiMutedHtml tag='strong' html={status.getIn(['account', 'display_name_html']) || ''} /></bdi></a> }} />
            {visibilityReblogLink}
          </div>
        );

        rebloggedByText = intl.formatMessage({ id: 'status.reblogged_by', defaultMessage: '{name} boosted' }, { name: status.getIn(['account', 'acct']) });

        account = status.get('account');
      }

      status  = status.get('reblog');
    }

    const mediaStatus = translationDisplayStatus(status, this.props.status);
    const translationView = statusTranslationView(mediaStatus);
    const deployPictureInPicture = pictureInPicture.get('available') ? this.handleDeployPictureInPicture : undefined;
    const mainRelease = assignRelease(this, 'mainRelease', spoilerConcealed(status) || pictureInPicture.get('inUse'));

    if (status.get('fedibird_external') && !this.props.muted && !pictureInPicture.get('inUse')) {
      media = (
        <ExternalStatusMedia
          status={mediaStatus}
          sensitive={status.get('sensitive')}
          height={110}
          videoHeight={110}
          onOpenMedia={this.handleOpenMedia}
          onOpenVideo={this.handleOpenSavedVideo}
          cacheWidth={this.props.cacheMediaWidth}
          defaultWidth={this.props.cachedMediaWidth}
          visible={this.state.showMedia}
          onToggleVisibility={this.handleToggleMediaVisibility}
          deployPictureInPicture={deployPictureInPicture}
          releaseSignal={mainRelease}
          {...galleryTranslationProps(translationView)}
        />
      );
    } else if (mediaStatus.get('media_attachments').size > 0) {
      if (pictureInPicture.get('inUse')) {
        media = <PictureInPicturePlaceholder width={this.props.cachedMediaWidth} />;
      } else if (this.props.muted) {
        media = (
          <Bundle fetchComponent={ThumbnailGallery} loading={this.renderLoadingThumbnailGallery}>
            {Component => (
              <Component
                media={status.get('media_attachments')}
                sensitive={status.get('sensitive')}
              />
            )}
          </Bundle>
        );
      } else {
        media = this.renderAttachmentMedia(mediaStatus, {
          sensitive: status.get('sensitive'),
          height: 110,
          videoHeight: 110,
          audioHeight: 110,
          visible: this.state.showMedia,
          onToggleVisibility: this.handleToggleMediaVisibility,
          onOpenMedia: this.handleOpenMedia,
          onOpenVideo: this.handleOpenVideo,
          translationView,
          deployPictureInPicture,
          posterFallback: status.getIn(['account', 'avatar_static']),
        });
      }
    } else if (showCard && status.get('spoiler_text').length === 0 && status.get('card') && !isHideCard(status.getIn(['card', 'type']))) {
      media = (
        <Card
          onOpenMedia={this.handleOpenMedia}
          card={status.get('card')}
          compact
          cacheWidth={this.props.cacheMediaWidth}
          defaultWidth={this.props.cachedMediaWidth}
          sensitive={status.get('sensitive')}
        />
      );
    }

    const externalIdentity = externalIdentityOf(status);

    if (externalIdentity) {
      statusAvatar = null;
    } else if (otherAccounts && otherAccounts.size > 0) {
      statusAvatar = <AvatarComposite accounts={otherAccounts} size={48} />;
    } else if (account === undefined || account === null) {
      statusAvatar = <Avatar account={status.get('account')} size={48} />;
    } else {
      statusAvatar = <AvatarOverlay account={status.get('account')} friend={account} />;
    }

    const visibilityIcon = visibilityIconInfo[status.get('visibility')];
    const visibilityLink = <Icon id={visibilityIcon.icon} title={visibilityIcon.text} />;

    let quote = null;
    if (status.get('quote', null) !== null && typeof status.get('quote') === 'object') {
      let quote_status = status.get('quote');
      const quoteExternalIdentity = externalIdentityOf(quote_status);
      const quoteView = statusTranslationView(quote_status);

      let quote_media = null;
      const quoteRelease = assignRelease(this, 'quoteRelease', spoilerConcealed(status) || spoilerConcealed(quote_status) || pictureInPicture.get('inUse'));
      if (!showCard) {
        // hide media
      } else if (quote_status.get('fedibird_external') && !this.props.muted && !pictureInPicture.get('inUse')) {
        quote_media = (
          <ExternalStatusMedia
            status={quote_status}
            sensitive={quote_status.get('sensitive')}
            height={110}
            videoHeight={110}
            onOpenMedia={this.handleOpenMediaQuote}
            onOpenVideo={this.handleOpenVideoQuote}
            cacheWidth={this.props.cacheMediaWidth}
            defaultWidth={this.props.cachedMediaWidth}
            visible={this.state.showQuoteMedia}
            onToggleVisibility={this.handleToggleQuoteMediaVisibility}
            deployPictureInPicture={deployPictureInPicture}
            releaseSignal={quoteRelease}
            quote
            {...galleryTranslationProps(quoteView)}
          />
        );
      } else if (quote_status.get('media_attachments').size > 0) {
        if (pictureInPicture.get('inUse')) {
          quote_media = <PictureInPicturePlaceholder width={this.props.cachedMediaWidth} />;
        } else if (this.props.muted) {
          quote_media = (
            <Bundle fetchComponent={ThumbnailGallery} loading={this.renderLoadingThumbnailGallery}>
              {Component => (
                <Component
                  media={quote_status.get('media_attachments')}
                  sensitive={quote_status.get('sensitive')}
                />
              )}
            </Bundle>
          );
        } else {
          quote_media = this.renderAttachmentMedia(quote_status, {
            sensitive: quote_status.get('sensitive'),
            height: 110,
            videoHeight: 110,
            audioHeight: 70,
            visible: this.state.showQuoteMedia,
            onToggleVisibility: this.handleToggleQuoteMediaVisibility,
            onOpenMedia: this.handleOpenMediaQuote,
            onOpenVideo: this.handleOpenVideoQuote,
            translationView: quoteView,
            deployPictureInPicture,
            posterFallback: quote_status.getIn(['account', 'avatar_static']),
            quote: true,
          });
        }
      }

      if (quote_muted) {
        quote = (
          <div className={classNames('quote-status', `status-${quote_status.get('visibility')}`, { muted: this.props.muted })} data-id={quote_status.get('id')}>
            <div className={classNames('status__content muted-quote', { 'status__content--with-action': this.context.router })}>
              <FormattedMessage id='status.muted_quote' defaultMessage='Muted quote' />
            </div>
          </div>
        );
      } else if (quote_status.get('visibility') === 'unlisted' && !!contextType && ['public', 'community', 'hashtag'].includes(contextType.split(':', 2)[0])) {
        quote = (
          <div className={classNames('quote-status', `status-${quote_status.get('visibility')}`, { muted: this.props.muted })} data-id={quote_status.get('id')}>
            <div className={classNames('status__content unlisted-quote', { 'status__content--with-action': this.context.router })}>
              <button onClick={this.handleQuoteClick}>
                <FormattedMessage id='status.unlisted_quote' defaultMessage='Unlisted quote' />
              </button>
            </div>
          </div>
        );
      } else {
        quote = (
          <div className={classNames('quote-status', `status-${quote_status.get('visibility')}`, { muted: this.props.muted })} data-id={quote_status.get('id')}>
            <div className='status__info'>
              {quoteExternalIdentity ? (
                <ExternalSourceIdentity identity={quoteExternalIdentity} size={18} className='status__display-name' avatarClassName='status__avatar' showLabel={false} />
              ) : (
                <a onClick={this.handleAccountClick} target='_blank' data-id={quote_status.getIn(['account', 'id'])} data-group={quote_status.getIn(['account', 'group'])} href={quote_status.getIn(['account', 'url'])} title={quote_status.getIn(['account', 'acct'])} className='status__display-name'>
                  <div className='status__avatar'><Avatar account={quote_status.get('account')} size={18} /></div>
                  <DisplayName account={quote_status.get('account')} />
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

    const expires_at = status.get('expires_at');
    const expires_date = expires_at && new Date(expires_at);
    const expired = expires_date && expires_date.getTime() < intl.now();

    const ancestorCount   = showThread && show_reply_tree_button && status.get('in_reply_to_id', 0) > 0 ? 1 : 0;
    const descendantCount = showThread && show_reply_tree_button ? status.get('replies_count', 0) : 0;
    const referenceCount  = enableStatusReference ? status.get('status_references_count', 0) - (status.get('status_reference_ids', ImmutableList()).includes(status.get('quote_id')) ? 1 : 0) : 0;
    const threadCount     = ancestorCount + descendantCount + referenceCount;

    let threadMarkTitle = '';

    if (ancestorCount + referenceCount > 0) {
      if (descendantCount > 0) {
        threadMarkTitle = intl.formatMessage(messages.mark_both);
      } else {
        threadMarkTitle = intl.formatMessage(messages.mark_ancestor);
      }
    } else if (descendantCount > 0) {
      threadMarkTitle = intl.formatMessage(messages.mark_descendant);
    }

    const threadMark = threadCount > 0 ? (<span
      className={classNames('status__thread_mark', {
        'status__thread_mark-ancenstor': (ancestorCount + referenceCount) > 0,
        'status__thread_mark-descendant': descendantCount > 0,
      })} title={threadMarkTitle}
    >+</span>) : null;

    return (
      <HotKeys handlers={handlers}>
        <div
          className={classNames('status__wrapper', `status__wrapper-${status.get('visibility')}`, {
            'status__wrapper-reply': !!status.get('in_reply_to_id'),
            unread,
            focusable: !this.props.muted,
            'status__wrapper-with-expiration': expires_date,
            'status__wrapper-expired': expired,
            'status__wrapper-referenced': referenced,
            'status__wrapper-context-referenced': contextReferenced,
            'status__wrapper-reference': referenceCount > 0,
          })} tabIndex={this.props.muted ? null : 0} data-featured={featured ? 'true' : null} aria-label={textForScreenReader(intl, status, rebloggedByText)} ref={this.handleRef}
        >
          {prepend}
          <AccountContextActions status={this.props.status} hostTimelineId={this.props.contextHostId || scrollKey || 'timeline'} onOpen={this.props.onOpenAccountContext} />

          <div className={classNames('status', `status-${status.get('visibility')}`, { 'status-reply': !!status.get('in_reply_to_id'), muted: this.props.muted, 'status-with-expiration': expires_date, 'status-expired': expired, referenced, 'context-referenced': contextReferenced, 'status-immediate': this.props.immediate && new_features_policy === 'tester' })} data-id={status.get('id')}>
            {!externalIdentity && <AccountActionBar account={status.get('account')} {...other} />}
            <div className='status__expand' onClick={this.handleExpandClick} role='presentation' />
            <div className='status__info'>
              {status.get('expires_at') && <span className='status__expiration-time'><time dateTime={expires_at} title={intl.formatDate(expires_date, dateFormatOptions)}><i className='fa fa-clock-o' aria-hidden='true' /></time></span>}
              <TimeLink url={externalIdentity ? externalIdentity.articleUrl : status.get('url')} external={!!externalIdentity} className='status__relative-time'>
                {threadMark}
                {disableRelativeTime ? <AbsoluteTimestamp timestamp={status.get('created_at')} /> : <RelativeTimestamp timestamp={status.get('created_at')} /> }
                {status.get('edited_at') && (
                  <abbr
                    title={intl.formatMessage(messages.edited, {
                      date: intl.formatDate(status.get('edited_at'), dateFormatOptions),
                    })}
                  >
                    {' *'}
                  </abbr>
                )}
              </TimeLink>
              <span className='status__visibility-icon'>{visibilityLink}</span>

              {externalIdentity ? (
                <ExternalSourceIdentity identity={externalIdentity} size={48} className='status__display-name' avatarClassName='status__avatar' />
              ) : (
                <a onClick={this.handleAccountClick} data-id={status.getIn(['account', 'id'])} data-group={status.getIn(['account', 'group'])} href={status.getIn(['account', 'url'])} title={status.getIn(['account', 'acct'])} className='status__display-name' target='_blank' rel='noopener noreferrer'>
                  <div className='status__avatar'>
                    {statusAvatar}
                  </div>

                  <DisplayName account={status.get('account')} others={otherAccounts} />
                </a>
              )}
              {sourceBadges && sourceBadges.length > 0 && <MixSourceBadges badges={sourceBadges} />}
            </div>

            <StatusContent status={status} translationWrapper={this.props.status} onClick={this.handleClick} expanded={!status.get('hidden')} showThread={showThread} onExpandedToggle={this.handleExpandedToggle} collapsable onCollapsedToggle={this.handleCollapsedToggle} onTranslate={this.props.onTranslate && this.handleTranslate} />

            {!(status.get('hidden') && status.get('spoiler_text').length > 0) && <>
              {quote}
              {media}
            </>
            }

            {enableReaction && (contextType === 'thread' || !compactReaction) && <EmojiReactionsBar
              status={status}
              addEmojiReaction={this.props.addEmojiReaction}
              removeEmojiReaction={this.props.removeEmojiReaction}
              reactionLimitReached={reactionLimitReached}
            />}
            <StatusActionBar scrollKey={scrollKey} status={status} translationStatus={translationRequestStatus(this.props.status)} account={account} expired={expired} {...other} onFilter={hasMatchedFilters ? this.handleFilterClick : null} />
          </div>
        </div>
      </HotKeys>
    );
  }

}

export default injectIntl(connect(mapStateToProps)(Status));
