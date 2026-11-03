import React from 'react';
import { connect } from 'react-redux';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import { fetchAccount } from 'mastodon/actions/accounts';
import { expandAccountMediaTimeline } from '../../actions/timelines';
import LoadingIndicator from 'mastodon/components/loading_indicator';
import Column from '../../components/column';
import ColumnHeader from '../../components/column_header';
import ColumnSettingsContainer from '../account_timeline/containers/column_settings_container';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { getAccountGallery } from 'mastodon/selectors';
import MediaItem from './components/media_item';
import MediaDisplayControls from 'mastodon/components/media_display_controls';
import MediaItemsLayout from 'mastodon/components/media_items_layout';
import { defaultMediaVisibility, mediaIsConcealed } from 'mastodon/utils/media_display';
import HeaderContainer from '../account_timeline/containers/header_container';
import ScrollContainer from 'mastodon/containers/scroll_container';
import LoadMore from 'mastodon/components/load_more';
import MissingIndicator from 'mastodon/components/missing_indicator';
import { openModal } from 'mastodon/actions/modal';
import { me, new_features_policy, defaultColumnWidth } from 'mastodon/initial_state';
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
    attachments: getAccountGallery(state, accountId),
    isLoading: state.getIn(['timelines', `account:${accountId}:media`, 'isLoading']),
    hasMore: state.getIn(['timelines', `account:${accountId}:media`, 'hasMore']),
    suspended: state.getIn(['accounts', accountId, 'suspended'], false),
    blockedBy: state.getIn(['relationships', accountId, 'blocked_by'], false),
    advancedMode: state.getIn(['settings', 'account', 'other', 'advancedMode'], new_features_policy === 'conservative' ? false : true),
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
    attachments: ImmutablePropTypes.list.isRequired,
    isLoading: PropTypes.bool,
    hasMore: PropTypes.bool,
    isAccount: PropTypes.bool,
    advancedMode: PropTypes.bool,
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
  };

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
  }

  componentWillReceiveProps (nextProps) {
    if (nextProps.params.accountId !== this.props.params.accountId && nextProps.params.accountId) {
      this.props.dispatch(fetchAccount(nextProps.params.accountId));
      this.props.dispatch(expandAccountMediaTimeline(nextProps.params.accountId));
    }
  }

  handleScrollToBottom = () => {
    if (this.props.hasMore) {
      this.handleLoadMore(this.props.attachments.size > 0 ? this.props.attachments.last().getIn(['status', 'id']) : undefined);
    }
  }

  handleScroll = e => {
    const { scrollTop, scrollHeight, clientHeight } = e.target;
    const offset = scrollHeight - scrollTop - clientHeight;

    if (150 > offset && !this.props.isLoading) {
      this.handleScrollToBottom();
    }
  }

  handleLoadMore = maxId => {
    this.props.dispatch(expandAccountMediaTimeline(this.props.params.accountId, { maxId }));
  };

  handleLoadOlder = e => {
    e.preventDefault();
    this.handleScrollToBottom();
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
      const images = this.props.attachments.filter(item =>
        item &&
        ['image', 'gifv'].includes(item.get('type')) &&
        !mediaIsConcealed(this.state.mediaVisibility, item.getIn(['status', 'sensitive']))
      );
      const position = images.findIndex(item => item.get('id') === attachment.get('id'));
      if (position >= 0 && images.size > 1) {
        dispatch(openModal('MEDIA', {
          media: images,
          timelineStatusIds: images.map(item => item.getIn(['status', 'id'])),
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
    const { attachments, isLoading, hasMore, isAccount, multiColumn, blockedBy, suspended, hideRelation, columnWidth, intl } = this.props;
    const { mediaShape, mediaSize, mediaVisibility } = this.state;

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

        <ScrollContainer scrollKey='account_gallery'>
          <div className='scrollable scrollable--flex' onScroll={this.handleScroll}>
            <HeaderContainer accountId={this.props.params.accountId} hideProfile hideRelation={hideRelation} hideFeaturedTags />

            <MediaDisplayControls
              shape={mediaShape}
              size={mediaSize}
              visibility={mediaVisibility}
              onShapeChange={this.handleMediaShapeChange}
              onSizeChange={this.handleMediaSizeChange}
              onVisibilityChange={this.handleMediaVisibilityChange}
            />

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
                    <MediaItem key={attachment.get('id')} attachment={attachment} shape={mediaShape} visibility={mediaVisibility} onOpenMedia={this.handleOpenMedia} />
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
