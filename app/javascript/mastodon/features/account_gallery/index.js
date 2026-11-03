import React from 'react';
import { connect } from 'react-redux';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import { fetchAccount } from 'mastodon/actions/accounts';
import { accountMediaTimelineId, expandAccountMediaTimeline } from '../../actions/timelines';
import { fetchFeaturedTags } from '../../actions/featured_tags';
import LoadingIndicator from 'mastodon/components/loading_indicator';
import Column from '../../components/column';
import ColumnHeader from '../../components/column_header';
import ColumnSettingsContainer from '../account_timeline/containers/column_settings_container';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { accountGalleryAttachments } from 'mastodon/selectors';
import { List as ImmutableList } from 'immutable';
import MediaItem from './components/media_item';
import MediaDisplayControls from 'mastodon/components/media_display_controls';
import MediaItemsLayout from 'mastodon/components/media_items_layout';
import { defaultMediaVisibility } from 'mastodon/utils/media_display';
import { accountMediaTimelineSequence } from 'mastodon/utils/media_timeline_sequence';
import HeaderContainer from '../account_timeline/containers/header_container';
import ScrollContainer from 'mastodon/containers/scroll_container';
import LoadMore from 'mastodon/components/load_more';
import MissingIndicator from 'mastodon/components/missing_indicator';
import { openModal } from 'mastodon/actions/modal';
import { me, defaultColumnWidth } from 'mastodon/initial_state';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import { changeSetting } from '../../actions/settings';

const messages = defineMessages({
  title: { id: 'column.account', defaultMessage: 'Account' },
});

const mapStateToProps = (state, { params: { accountId } }) => {
  const hidePostCount = state.getIn(['settings', 'account', 'other', 'hidePostCount'], false);
  const hideFollowingCount = state.getIn(['settings', 'account', 'other', 'hideFollowingCount'], false);
  const hideFollowerCount = state.getIn(['settings', 'account', 'other', 'hideFollowerCount'], false);
  const hideSubscribingCount = state.getIn(['settings', 'account', 'other', 'hideSubscribingCount'], false);
  const hideRelation = hidePostCount && hideFollowingCount && hideFollowerCount && (me !== accountId || hideSubscribingCount);

  return {
    isAccount: !!state.getIn(['accounts', accountId]),
    account: state.getIn(['accounts', accountId]),
    mediaTimelines: state.get('timelines'),
    mediaStatuses: state.get('statuses'),
    mediaFilters: state.get('filters'),
    mediaFilterMatches: state.get('filterMatches'),
    mediaFilterGeneration: state.getIn(['filterMatches', 'generation'], 0),
    suspended: state.getIn(['accounts', accountId, 'suspended'], false),
    blockedBy: state.getIn(['relationships', accountId, 'blocked_by'], false),
    hideFeaturedTags: state.getIn(['settings', 'account', 'other', 'hideFeaturedTags'], false),
    hideRelation,
    columnWidth: state.getIn(['settings', 'account', 'columnWidth'], defaultColumnWidth),
  };
};

class LoadMoreMedia extends ImmutablePureComponent {

  static propTypes = {
    maxId: PropTypes.string,
    onLoadMore: PropTypes.func.isRequired,
    disabled: PropTypes.bool,
  };

  handleLoadMore = () => {
    this.props.onLoadMore(this.props.maxId);
  }

  render () {
    return (
      <div className='media-layout__more'>
        <LoadMore
          disabled={this.props.disabled}
          onClick={this.handleLoadMore}
        />
      </div>
    );
  }

}

export default @connect(mapStateToProps)
@injectIntl
class AccountGallery extends ImmutablePureComponent {

  static propTypes = {
    params: PropTypes.object.isRequired,
    dispatch: PropTypes.func.isRequired,
    account: ImmutablePropTypes.map,
    mediaTimelines: ImmutablePropTypes.map.isRequired,
    mediaStatuses: ImmutablePropTypes.map.isRequired,
    mediaFilters: ImmutablePropTypes.map,
    mediaFilterMatches: ImmutablePropTypes.map,
    mediaFilterGeneration: PropTypes.number,
    isAccount: PropTypes.bool,
    hideFeaturedTags: PropTypes.bool,
    hideRelation: PropTypes.bool,
    blockedBy: PropTypes.bool,
    suspended: PropTypes.bool,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
  };

  state = {
    mediaShape: 'square',
    mediaSize: 'small',
    mediaVisibility: defaultMediaVisibility(),
    tagged: null,
  };

  handleChooseTag = selected => {
    const tagged = selected ? selected.replace(/^#/, '').trim().normalize('NFKC') : null;
    const accountId = this.props.params.accountId;
    if (tagged === this.state.tagged) {
      return;
    }

    this.setState({ tagged });
    this.props.dispatch(expandAccountMediaTimeline(accountId, { tagged }));
  }

  handleMediaShapeChange = mediaShape => {
    this.setState({ mediaShape });
  }

  handleMediaSizeChange = mediaSize => {
    this.setState({ mediaSize });
  }

  handleMediaVisibilityChange = mediaVisibility => {
    // Temporary override in this account media view. No settings write.
    this.setState({ mediaVisibility });
  }

  componentDidMount () {
    this.props.dispatch(fetchAccount(this.props.params.accountId));
    this.props.dispatch(expandAccountMediaTimeline(this.props.params.accountId));
    this.props.dispatch(fetchFeaturedTags(this.props.params.accountId));
  }

  componentWillReceiveProps (nextProps) {
    if (nextProps.params.accountId !== this.props.params.accountId && nextProps.params.accountId) {
      this.setState({ tagged: null });
      this.props.dispatch(fetchAccount(nextProps.params.accountId));
      this.props.dispatch(fetchFeaturedTags(nextProps.params.accountId));
      this.props.dispatch(expandAccountMediaTimeline(nextProps.params.accountId));
    }
  }

  handleScrollToBottom = () => {
    const id = accountMediaTimelineId(this.props.params.accountId, this.state.tagged);
    if (this.props.mediaTimelines.getIn([id, 'hasMore'])) {
      const ids = this.props.mediaTimelines.getIn([id, 'items'], ImmutableList());
      this.handleLoadMore(ids.findLast(statusId => statusId !== null));
    }
  }

  handleScroll = e => {
    const { scrollTop, scrollHeight, clientHeight } = e.target;
    const offset = scrollHeight - scrollTop - clientHeight;

    const activeId = accountMediaTimelineId(this.props.params.accountId, this.state.tagged);
    if (150 > offset && !this.props.mediaTimelines.getIn([activeId, 'isLoading'])) {
      this.handleScrollToBottom();
    }
  }

  handleLoadMore = maxId => {
    this.props.dispatch(expandAccountMediaTimeline(this.props.params.accountId, { maxId, tagged: this.state.tagged }));
  };

  handleLoadOlder = e => {
    e.preventDefault();
    this.handleScrollToBottom();
  }

  handleModalLoadMore = (accountId, tagged) => {
    const timelineId = accountMediaTimelineId(accountId, tagged);
    const { mediaTimelines, dispatch } = this.props;
    if (mediaTimelines.getIn([timelineId, 'isLoading']) || !mediaTimelines.getIn([timelineId, 'hasMore'])) {
      return;
    }

    const ids = mediaTimelines.getIn([timelineId, 'items'], ImmutableList());
    dispatch(expandAccountMediaTimeline(accountId, { maxId: ids.findLast(statusId => statusId !== null), tagged }));
  }

  handleOpenMedia = attachment => {
    const { dispatch } = this.props;
    const statusId = attachment.getIn(['status', 'id']);

    if (attachment.get('type') === 'video') {
      dispatch(openModal('VIDEO', { media: attachment, statusId, options: { autoPlay: true } }));
    } else if (attachment.get('type') === 'audio') {
      dispatch(openModal('AUDIO', { media: attachment, statusId, options: { autoPlay: true } }));
    } else {
      // Account media mode is already one attachment per tile. Navigate
      // pictures across all currently loaded posts instead of stopping at
      // each post's media_attachments collection.
      const id = accountMediaTimelineId(this.props.params.accountId, this.state.tagged);
      const statusIds = this.props.mediaTimelines.getIn([id, 'items'], ImmutableList());
      const filterInfo = {
        filters: this.props.mediaFilters,
        matches: this.props.mediaFilterMatches,
        generation: this.props.mediaFilterGeneration,
      };
      const attachments = accountGalleryAttachments(statusIds, this.props.mediaStatuses, this.props.account, filterInfo);
      const sequence = accountMediaTimelineSequence(attachments, this.state.mediaVisibility, filterInfo);
      const position = sequence.media.findIndex(item => item.get('id') === attachment.get('id'));
      if (position >= 0 && sequence.media.size > 0) {
        const accountId = this.props.params.accountId;
        const tagged = this.state.tagged;
        dispatch(openModal('MEDIA', {
          media: sequence.media,
          timelineStatusIds: sequence.statusIds,
          mediaSource: {
            kind: 'account',
            accountId,
            timelineId: id,
            afterStatusId: statusIds.findLast(statusId => statusId !== null),
            visibility: this.state.mediaVisibility,
            onLoadMore: () => this.handleModalLoadMore(accountId, tagged),
          },
          index: position,
          statusId,
        }));
      } else {
        // Restrict individually revealed tiles to that attachment. The
        // default per-post gallery would bypass this column's concealment
        // preference when moving to a sibling attachment.
        const media = attachment.getIn(['status', 'media_attachments'])
          .filter(item => item.get('id') === attachment.get('id'));
        dispatch(openModal('MEDIA', { media, index: 0, statusId }));
      }
    }
  }

  handleHeaderClick = () => {
    this.column.scrollTop();
  }

  handleWidthChange = (value) => {
    this.props.dispatch(changeSetting(['account', 'columnWidth'], value));
  }

  setRef = c => {
    this.column = c;
  }

  render () {
    const { mediaTimelines, mediaStatuses, account, isAccount, multiColumn, blockedBy, suspended, hideRelation, hideFeaturedTags, columnWidth, intl } = this.props;
    const { mediaShape, mediaSize, mediaVisibility, tagged } = this.state;
    const timelineId = accountMediaTimelineId(this.props.params.accountId, tagged);
    const statusIds = mediaTimelines.getIn([timelineId, 'items'], ImmutableList());
    const filterInfo = {
      filters: this.props.mediaFilters,
      matches: this.props.mediaFilterMatches,
      generation: this.props.mediaFilterGeneration,
    };
    const attachments = accountGalleryAttachments(statusIds, mediaStatuses, account, filterInfo);
    const isLoading = !!mediaTimelines.getIn([timelineId, 'isLoading']);
    const hasMore = !!mediaTimelines.getIn([timelineId, 'hasMore']);

    if (!isAccount) {
      return (
        <Column>
          <MissingIndicator />
        </Column>
      );
    }

    if (!attachments && isLoading) {
      return (
        <Column>
          <LoadingIndicator />
        </Column>
      );
    }

    let loadOlder = null;

    if (hasMore && !(isLoading && attachments.size === 0)) {
      loadOlder = <LoadMore visible={!isLoading} onClick={this.handleLoadOlder} />;
    }

    let emptyMessage;

    if (suspended) {
      emptyMessage = <FormattedMessage id='empty_column.account_suspended' defaultMessage='Account suspended' />;
    } else if (blockedBy) {
      emptyMessage = <FormattedMessage id='empty_column.account_unavailable' defaultMessage='Profile unavailable' />;
    }

    return (
      <Column bindToDocument={!multiColumn} ref={this.setRef} label={intl.formatMessage(messages.title)} columnWidth={columnWidth}>
        <ColumnHeader
          icon='user'
          active={false}
          title={intl.formatMessage(messages.title)}
          onClick={this.handleHeaderClick}
          pinned={false}
          multiColumn={multiColumn}
          columnWidth={columnWidth}
          onWidthChange={this.handleWidthChange}
        >
          <ColumnSettingsContainer />
        </ColumnHeader>

        <ScrollContainer scrollKey={`account_gallery:${this.props.params.accountId}:${tagged || 'all'}`}>
          <div className='scrollable scrollable--flex' onScroll={this.handleScroll}>
            <HeaderContainer accountId={this.props.params.accountId} hideProfile hideRelation={hideRelation} hideFeaturedTags={hideFeaturedTags} tagged={tagged} showTagSearch onSelectTag={this.handleChooseTag} />

            <div className='account-gallery__filters'>
              <MediaDisplayControls
                shape={mediaShape}
                size={mediaSize}
                visibility={mediaVisibility}
                onShapeChange={this.handleMediaShapeChange}
                onSizeChange={this.handleMediaSizeChange}
                onVisibilityChange={this.handleMediaVisibilityChange}
              />
            </div>

            {(suspended || blockedBy) ? (
              <div className='empty-column-indicator'>
                {emptyMessage}
              </div>
            ) : (
              <div role='feed' className='account-gallery__container account-gallery__container--media'>
                <MediaItemsLayout shape={mediaShape} size={mediaSize}>
                  {attachments.map((attachment, index) => attachment === null ? (
                    <LoadMoreMedia key={'more:' + attachments.getIn(index + 1, 'id')} maxId={index > 0 ? attachments.getIn(index - 1, 'id') : null} onLoadMore={this.handleLoadMore} />
                  ) : (
                    <MediaItem key={`${attachment.get('id')}:${mediaVisibility}`} attachment={attachment} shape={mediaShape} visibility={mediaVisibility} onOpenMedia={this.handleOpenMedia} />
                  ))}

                  {loadOlder && <div key='more:older' className='media-layout__more'>{loadOlder}</div>}
                </MediaItemsLayout>
              </div>
            )}

            {isLoading && attachments.size === 0 && (
              <div className='scrollable__append'>
                <LoadingIndicator />
              </div>
            )}
          </div>
        </ScrollContainer>
      </Column>
    );
  }

}
