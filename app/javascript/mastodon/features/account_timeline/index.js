import React from 'react';
import { connect } from 'react-redux';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import { fetchAccount } from '../../actions/accounts';
import { expandAccountFeaturedTimeline, expandAccountTimeline, fetchAccountTimeline } from '../../actions/timelines';
import StatusList from '../../components/status_list';
import LoadingIndicator from '../../components/loading_indicator';
import Column from '../../components/column';
import ColumnHeader from '../../components/column_header';
import ColumnSettingsContainer from './containers/column_settings_container';
import HeaderContainer from './containers/header_container';
import ColumnBackButton from '../../components/column_back_button';
import { List as ImmutableList } from 'immutable';
import ImmutablePureComponent from 'react-immutable-pure-component';
import { defineMessages, injectIntl, FormattedMessage } from 'react-intl';
import { fetchAccountIdentityProofs } from '../../actions/identity_proofs';
import MissingIndicator from 'mastodon/components/missing_indicator';
import TimelineHint from 'mastodon/components/timeline_hint';
import { me, new_features_policy, defaultColumnWidth } from 'mastodon/initial_state';
import { connectTimeline, disconnectTimeline } from 'mastodon/actions/timelines';
import { fetchFeaturedTags } from '../../actions/featured_tags';
import { changeSetting } from '../../actions/settings';
import Icon from 'mastodon/components/icon';
import { readTimelineLayout } from 'mastodon/utils/timeline_layout';

const emptyList = ImmutableList();

const messages = defineMessages({
  title: { id: 'column.account', defaultMessage: 'Account' },
});

const mapStateToProps = (state, { params: { accountId, tagged }, about, withReplies, posts }) => {
  posts = tagged ? false : posts;
  withReplies = tagged ? true : withReplies;
  const advancedMode = state.getIn(['settings', 'account', 'other', 'advancedMode'], new_features_policy === 'conservative' ? false : true);
  const hideFeaturedTags = state.getIn(['settings', 'account', 'other', 'hideFeaturedTags'], false);
  const withoutReblogs = advancedMode && state.getIn(['settings', 'account', 'other', 'withoutReblogs'], false);
  const showPostsInAbout = state.getIn(['settings', 'account', 'other', 'showPostsInAbout'], true);
  const hidePostCount = state.getIn(['settings', 'account', 'other', 'hidePostCount'], false);
  const hideFollowingCount = state.getIn(['settings', 'account', 'other', 'hideFollowingCount'], false);
  const hideFollowerCount = state.getIn(['settings', 'account', 'other', 'hideFollowerCount'], false);
  const hideSubscribingCount = state.getIn(['settings', 'account', 'other', 'hideSubscribingCount'], false);
  const hideRelation = hidePostCount && hideFollowingCount && hideFollowerCount && (me !== accountId || hideSubscribingCount);
  const path = `${accountId}${withReplies ? ':with_replies' : ''}${withoutReblogs ? ':without_reblogs' : ''}${tagged ? `:${tagged}` : ''}`;
  const onlyMedia = readTimelineLayout(state, null, 'account') === 'media';
  const activePath = `${path}${onlyMedia ? ':view-media' : ''}`;

  return {
    remote: !!(state.getIn(['accounts', accountId, 'acct']) !== state.getIn(['accounts', accountId, 'username'])),
    remoteUrl: state.getIn(['accounts', accountId, 'url']),
    fetched: state.getIn(['accounts', accountId, 'fetched'], true),
    isAccount: !!state.getIn(['accounts', accountId]),
    statusIds: advancedMode && about && !showPostsInAbout ? emptyList : state.getIn(['timelines', `account:${activePath}`, 'items'], emptyList),
    featuredStatusIds: (withReplies || posts) ? emptyList : state.getIn(['timelines', `account:${accountId}:pinned${tagged ? `:${tagged}` : ''}`, 'items'], emptyList),
    isLoading: state.getIn(['timelines', `account:${activePath}`, 'isLoading']),
    hasMore: state.getIn(['timelines', `account:${activePath}`, 'hasMore']),
    suspended: state.getIn(['accounts', accountId, 'suspended'], false),
    blockedBy: state.getIn(['relationships', accountId, 'blocked_by'], false),
    following: state.getIn(['relationships', accountId, 'following'], false),
    advancedMode,
    hideFeaturedTags,
    posts,
    withReplies,
    withoutReblogs,
    showPostsInAbout,
    hideRelation,
    columnWidth: state.getIn(['settings', 'account', 'columnWidth'], defaultColumnWidth),
    layoutMode: readTimelineLayout(state, null, 'account'),
    onlyMedia,
    mediaStatuses: state.get('statuses'),
  };
};

const RemoteHint = ({ url }) => (
  <TimelineHint url={url} resource={<FormattedMessage id='timeline_hint.resources.statuses' defaultMessage='Older toots' />} />
);

RemoteHint.propTypes = {
  url: PropTypes.string.isRequired,
};

export default @connect(mapStateToProps)
@injectIntl
class AccountTimeline extends ImmutablePureComponent {

  static propTypes = {
    intl: PropTypes.object.isRequired,
    params: PropTypes.object.isRequired,
    dispatch: PropTypes.func.isRequired,
    statusIds: ImmutablePropTypes.list,
    featuredStatusIds: ImmutablePropTypes.list,
    isLoading: PropTypes.bool,
    hasMore: PropTypes.bool,
    about: PropTypes.bool,
    withReplies: PropTypes.bool,
    withoutReblogs: PropTypes.bool,
    posts: PropTypes.bool,
    advancedMode: PropTypes.bool,
    hideFeaturedTags: PropTypes.bool,
    hideRelation: PropTypes.bool,
    blockedBy: PropTypes.bool,
    following: PropTypes.bool,
    isAccount: PropTypes.bool,
    suspended: PropTypes.bool,
    remote: PropTypes.bool,
    remoteUrl: PropTypes.string,
    fetched: PropTypes.bool,
    multiColumn: PropTypes.bool,
    columnWidth: PropTypes.string,
    layoutMode: PropTypes.string,
    onlyMedia: PropTypes.bool,
    mediaStatuses: ImmutablePropTypes.map,
  };

  static defaultProps = {
    about: false,
    withReplies: false,
    posts: false,
  };

  componentWillMount () {
    const { params: { accountId, tagged }, about, withReplies, posts, advancedMode, hideFeaturedTags, withoutReblogs, showPostsInAbout, dispatch } = this.props;

    dispatch(fetchAccount(accountId));
    dispatch(fetchAccountIdentityProofs(accountId));

    if (!withReplies && !posts) {
      dispatch(expandAccountFeaturedTimeline(accountId, { tagged }));
    }

    if (!about || !advancedMode || showPostsInAbout) {
      dispatch(expandAccountTimeline(accountId, { withReplies, tagged, withoutReblogs, onlyMedia: this.props.onlyMedia }));
    }

    if (tagged || !hideFeaturedTags) {
      dispatch(fetchFeaturedTags(accountId));
    }

    if (accountId === me) {
      dispatch(connectTimeline(`account:${me}`));
    }
  }

  componentWillReceiveProps (nextProps) {
    const { dispatch } = this.props;

    if ((nextProps.params.accountId !== this.props.params.accountId && nextProps.params.accountId)
      || (nextProps.params.tagged !== this.props.params.tagged)
      || nextProps.withReplies !== this.props.withReplies
      || nextProps.withoutReblogs !== this.props.withoutReblogs
      || nextProps.showPostsInAbout !== this.props.showPostsInAbout
      || nextProps.onlyMedia !== this.props.onlyMedia
    ) {
      dispatch(fetchAccount(nextProps.params.accountId));
      dispatch(fetchAccountIdentityProofs(nextProps.params.accountId));

      if (!nextProps.withReplies && !nextProps.posts) {
        dispatch(expandAccountFeaturedTimeline(nextProps.params.accountId, { tagged: nextProps.params.tagged }));
      }

      if (!nextProps.about || nextProps.showPostsInAbout) {
        dispatch(expandAccountTimeline(nextProps.params.accountId, { withReplies: nextProps.withReplies, tagged: nextProps.params.tagged, withoutReblogs: nextProps.withoutReblogs, onlyMedia: nextProps.onlyMedia }));
      }

      if (nextProps.params.tagged || !nextProps.hideFeaturedTags) {
        dispatch(fetchFeaturedTags(nextProps.params.accountId));
      }
    }

    if ((!nextProps.about || !this.props.advancedMode) && nextProps.params.accountId === me && this.props.params.accountId !== me) {
      dispatch(connectTimeline(`account:${me}`));
    } else if (this.props.params.accountId === me && nextProps.params.accountId !== me) {
      dispatch(disconnectTimeline(`account:${me}`));
    }
  }

  componentWillUnmount () {
    const { dispatch, params: { accountId } } = this.props;

    if (accountId === me) {
      dispatch(disconnectTimeline(`account:${me}`));
    }
  }

  handleFetchMore = () => {
    const { dispatch, params: { accountId, tagged }, withReplies, withoutReblogs } = this.props;

    dispatch(fetchAccountTimeline(accountId, { withReplies, tagged, withoutReblogs, onlyMedia: this.props.onlyMedia }));
  }

  handleLoadMore = maxId => {
    this.props.dispatch(expandAccountTimeline(this.props.params.accountId, { maxId, withReplies: this.props.withReplies, tagged: this.props.params.tagged, withoutReblogs: this.props.withoutReblogs, onlyMedia: this.props.onlyMedia }));
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
    const { params: { accountId, tagged }, intl, statusIds, featuredStatusIds, isLoading, hasMore, blockedBy, following, suspended, isAccount, multiColumn, remote, remoteUrl, fetched, about, withReplies, posts, advancedMode, hideFeaturedTags, showPostsInAbout, hideRelation, columnWidth, layoutMode, mediaStatuses } = this.props;

    if (!isAccount) {
      return (
        <Column>
          <ColumnBackButton multiColumn={multiColumn} />
          <MissingIndicator />
        </Column>
      );
    }

    if (!statusIds && isLoading) {
      return (
        <Column>
          <LoadingIndicator />
        </Column>
      );
    }

    const remoteMessage = (!fetched && remote) && (following ? (
      <div className='timeline-hint'>
        <strong><FormattedMessage id='timeline_hint.remote_resource_not_fetched' defaultMessage='{resource} from other servers has not yet been fetched.' values={{ resource: <FormattedMessage id='timeline_hint.resources.statuses' defaultMessage='Older toots' /> }} /></strong>
        <br />
        <button className='load-more' onClick={this.handleFetchMore} disabled={isLoading} >
          {isLoading ? (
            <FormattedMessage id='loading_indicator.label' defaultMessage='Loading...' />
          ) : (<>
            <Icon id='refresh' /> <FormattedMessage id='account.fetch_more_on_origin_server' defaultMessage='Fetch more on ther original profile' />
          </>)}
        </button>
      </div>
    ) : <RemoteHint url={remoteUrl} />);

    let emptyMessage;

    if (suspended) {
      emptyMessage = <FormattedMessage id='empty_column.account_suspended' defaultMessage='Account suspended' />;
    } else if (blockedBy) {
      emptyMessage = <FormattedMessage id='empty_column.account_unavailable' defaultMessage='Profile unavailable' />;
    } else if (about && advancedMode && featuredStatusIds.isEmpty()) {
      emptyMessage = <FormattedMessage id='empty_column.pinned_unavailable' defaultMessage='Pinned posts unavailable' />;
    } else if (remote && !following && statusIds.isEmpty()) {
      emptyMessage = <RemoteHint url={remoteUrl} />;
    } else if (remote && remoteMessage) {
      emptyMessage = remoteMessage;
    } else {
      emptyMessage = <FormattedMessage id='empty_column.account_timeline' defaultMessage='No toots here!' />;
    }

    return (
      <Column bindToDocument={!multiColumn} ref={this.setRef} label={intl.formatMessage(messages.title)} columnWidth={columnWidth}>
        <ColumnHeader
          layoutScope='account'
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

        <StatusList
          layoutMode={layoutMode}
          mediaStatuses={layoutMode === 'media' ? mediaStatuses : null}
          prepend={<HeaderContainer accountId={accountId} tagged={tagged} hideProfile={withReplies || posts || !!tagged} hideRelation={hideRelation} hideFeaturedTags={hideFeaturedTags} />}
          alwaysPrepend
          append={remoteMessage}
          scrollKey='account_timeline'
          statusIds={(suspended || blockedBy) ? emptyList : statusIds}
          featuredStatusIds={featuredStatusIds}
          isLoading={isLoading}
          hasMore={about && advancedMode && !showPostsInAbout ? null : hasMore}
          onLoadMore={about && advancedMode && !showPostsInAbout ? null : this.handleLoadMore}
          emptyMessage={emptyMessage}
          bindToDocument={!multiColumn}
          timelineId='account'
        />
      </Column>
    );
  }

}
