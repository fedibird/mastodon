import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { FormattedMessage } from 'react-intl';
import { List as ImmutableList } from 'immutable';
import StatusList from 'mastodon/components/status_list';
import StatusListContainer from 'mastodon/features/ui/containers/status_list_container';
import { layoutModeForPresentation, fullscreenScaleFactor } from 'mastodon/utils/fullscreen_column';
import { mixTimelineView } from 'mastodon/mix/view';
import { accountGalleryAttachments } from 'mastodon/selectors';
import AccountMediaItems from 'mastodon/features/account_gallery/components/media_items';
import { openModal } from 'mastodon/actions/modal';
import { me } from 'mastodon/initial_state';
import Notifications from 'mastodon/features/notifications';
import ConversationsListContainer from 'mastodon/features/direct_timeline/containers/conversations_list_container';
import SearchResults from 'mastodon/features/compose/components/search_results';
import { expandFullscreenSource } from '../expand';

const empty = ImmutableList();

const mapStateToProps = (state, { session }) => {
  const source = session.get('source');
  const kind = source.get('kind');
  const presentation = session.get('presentation');

  return {
    source,
    presentation,
    viewId: session.get('viewId'),
    composerId: session.get('composerId'),
    anchorStatusId: session.get('anchorStatusId'),
    statusLists: kind === 'status_list' ? state.getIn(['status_lists', source.get('listKey')]) : null,
    emojiList: kind === 'emoji_reactions' ? state.getIn(['emoji_reactioned_statuses', 'lists', source.get('listKey')]) : null,
    statuses: state.get('statuses'),
    accountItems: kind === 'account' ? state.getIn(['timelines', source.get('dataTimelineId'), 'items'], empty) : null,
    accountFeatured: kind === 'account' && source.get('featuredTimelineId') ? state.getIn(['timelines', source.get('featuredTimelineId'), 'items'], empty) : null,
    accountLoading: kind === 'account' ? state.getIn(['timelines', source.get('dataTimelineId'), 'isLoading']) : false,
    accountHasMore: kind === 'account' ? state.getIn(['timelines', source.get('dataTimelineId'), 'hasMore']) : false,
    mixTimeline: kind === 'mix' ? state.getIn(['mix_timelines', source.get('mixColumnKey')]) : null,
    filters: state.get('filters'),
    filterMatches: state.get('filterMatches'),
    mediaTimeline: kind === 'account_media' ? state.getIn(['timelines', source.get('dataTimelineId')]) : null,
    account: kind === 'account_media' ? state.getIn(['accounts', source.get('accountId')]) : null,
    searchResults: kind === 'search' ? state.getIn(['search', 'results']) : null,
    searchSuggestions: kind === 'search' ? state.getIn(['suggestions', 'items']) : null,
    searchTerm: kind === 'search' ? state.getIn(['search', 'searchTerm']) : '',
  };
};

class FullscreenStream extends React.PureComponent {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    session: PropTypes.object.isRequired,
    source: PropTypes.object,
    presentation: PropTypes.object,
    viewId: PropTypes.string,
    composerId: PropTypes.string,
    anchorStatusId: PropTypes.string,
    statusLists: PropTypes.object,
    emojiList: PropTypes.object,
    statuses: PropTypes.object,
    accountItems: PropTypes.object,
    accountFeatured: PropTypes.object,
    accountLoading: PropTypes.bool,
    accountHasMore: PropTypes.bool,
    mixTimeline: PropTypes.object,
    filters: PropTypes.object,
    filterMatches: PropTypes.object,
    mediaTimeline: PropTypes.object,
    account: PropTypes.object,
    searchResults: PropTypes.object,
    searchSuggestions: PropTypes.object,
    searchTerm: PropTypes.string,
  };

  anchored = false;

  setRoot = (node) => {
    this.root = node;
  };

  componentDidMount () {
    this.scrollToAnchor();
  }

  componentDidUpdate () {
    this.scrollToAnchor();
  }

  scrollToAnchor () {
    const { anchorStatusId } = this.props;

    if (this.anchored || !anchorStatusId || !this.root || !window.CSS || !window.CSS.escape) {
      return;
    }

    const node = this.root.querySelector(`[data-id="${window.CSS.escape(anchorStatusId)}"]`);
    const scroller = this.root.querySelector('.scrollable');

    if (!node || !scroller) {
      return;
    }

    const delta = node.getBoundingClientRect().top - scroller.getBoundingClientRect().top;
    scroller.scrollTop += delta;
    this.anchored = true;
  }

  handleLoadMore = (maxId) => {
    this.props.dispatch((dispatch, getState) => {
      expandFullscreenSource(dispatch, getState, this.props.source, maxId);
    });
  };

  statusListProps () {
    const { presentation, viewId, composerId, source } = this.props;
    const appearance = presentation.get('appearance');
    const scale = fullscreenScaleFactor(presentation.get('scale'));

    return {
      layoutMode: layoutModeForPresentation(presentation.toJS()),
      flowColumns: appearance === 'normal' ? Number(presentation.get('columns')) || 1 : undefined,
      contentScale: appearance === 'media' ? 1 : scale,
      disableHeightCache: true,
      bindToDocument: false,
      trackScroll: false,
      scrollKey: `fullscreen:${viewId}`,
      contextHostId: viewId,
      composerId: source.get('supportsComposer') ? composerId : undefined,
      onLoadMore: this.handleLoadMore,
      suppressMediaControls: true,
      mediaShape: presentation.get('mediaShape'),
      mediaSize: presentation.get('mediaSize'),
      mediaVisibility: presentation.get('mediaVisibility'),
      emptyMessage: <FormattedMessage id='fullscreen_column.empty' defaultMessage='Nothing to show yet.' />,
    };
  }

  renderTimeline () {
    const { source } = this.props;
    const shared = this.statusListProps();

    return (
      <StatusListContainer
        {...shared}
        timelineId={source.get('timelineId')}
        dataTimelineId={source.get('dataTimelineId')}
        layoutScope={source.get('scope')}
        presentationOverride
        passiveView
        manageTimelineScrollState={false}
      />
    );
  }

  renderStatusList (record) {
    const { presentation, statuses } = this.props;
    const media = presentation.get('appearance') === 'media';

    return (
      <StatusList
        {...this.statusListProps()}
        statusIds={(record && record.get('items')) || empty}
        hasMore={!!(record && (record.get('next') || record.get('hasMore')))}
        isLoading={!!(record && record.get('isLoading'))}
        mediaStatuses={media ? statuses : null}
      />
    );
  }

  renderAccount () {
    const { presentation, statuses, accountItems, accountFeatured, accountLoading, accountHasMore } = this.props;
    const media = presentation.get('appearance') === 'media';

    return (
      <StatusList
        {...this.statusListProps()}
        timelineId='account'
        statusIds={accountItems || empty}
        featuredStatusIds={accountFeatured}
        hasMore={accountHasMore}
        isLoading={accountLoading}
        mediaStatuses={media ? statuses : null}
      />
    );
  }

  currentMixView () {
    const { mixTimeline, statuses, filters, filterMatches } = this.props;
    return mixTimelineView(mixTimeline, statuses, filters, me, undefined, filterMatches);
  }

  mixContextType = (id) => {
    const view = this.currentMixView();
    return view && view.contextById ? view.contextById[id] : null;
  }

  mixWarnings = (id) => {
    const view = this.currentMixView();
    return (view && view.warningsById && view.warningsById[id]) || [];
  }

  handleOpenAccountMedia = (attachment) => {
    this.props.dispatch(openModal('MEDIA', {
      statusId: attachment.getIn(['status', 'id']),
      media: attachment.getIn(['status', 'media_attachments']),
      index: 0,
    }));
  }

  noop = () => {}

  renderMix () {
    const { statuses, presentation } = this.props;
    const view = this.currentMixView();
    const media = presentation.get('appearance') === 'media';

    return (
      <StatusList
        {...this.statusListProps()}
        timelineId='mix'
        statusIds={view && view.statusIds ? view.statusIds : empty}
        filterStatusIds={view && view.reconciliationIds}
        hasMore={!!(view && view.hasMore)}
        isLoading={!!(view && (view.waiting || view.running))}
        mediaStatuses={media ? statuses : null}
        contextTypeForId={this.mixContextType}
        warningTitlesForId={this.mixWarnings}
      />
    );
  }

  renderAccountMedia () {
    const { mediaTimeline, statuses, account, presentation } = this.props;
    const statusIds = mediaTimeline ? mediaTimeline.get('items', empty) : empty;
    const attachments = accountGalleryAttachments(statusIds, statuses, account, {});

    return (
      <div className='scrollable fullscreen-column__media'>
        <AccountMediaItems
          attachments={attachments || empty}
          shape={presentation.get('mediaShape')}
          size={presentation.get('mediaSize')}
          visibility={presentation.get('mediaVisibility')}
          onOpenMedia={this.handleOpenAccountMedia}
          onReveal={this.noop}
          onLoadMore={this.handleLoadMore}
        />
      </div>
    );
  }

  renderSearch () {
    const { searchResults, searchSuggestions, searchTerm } = this.props;

    if (!searchResults) {
      return null;
    }

    return (
      <div className='scrollable fullscreen-column__search'>
        <SearchResults
          passive
          results={searchResults}
          suggestions={searchSuggestions || empty}
          searchTerm={searchTerm || ''}
          fetchSuggestions={this.noop}
          expandSearch={this.noop}
          dismissSuggestion={this.noop}
        />
      </div>
    );
  }

  render () {
    const kind = this.props.source.get('kind');
    const appearance = this.props.presentation.get('appearance');
    const scalable = appearance !== 'media' && ['timeline', 'status_list', 'emoji_reactions', 'account', 'mix'].includes(kind);
    const scale = scalable ? fullscreenScaleFactor(this.props.presentation.get('scale')) : 1;
    let body = null;

    if (kind === 'timeline') {
      body = this.renderTimeline();
    } else if (kind === 'status_list') {
      body = this.renderStatusList(this.props.statusLists);
    } else if (kind === 'emoji_reactions') {
      body = this.renderStatusList(this.props.emojiList);
    } else if (kind === 'account') {
      body = this.renderAccount();
    } else if (kind === 'mix') {
      body = this.renderMix();
    } else if (kind === 'account_media') {
      body = this.renderAccountMedia();
    } else if (kind === 'notifications') {
      body = <Notifications passive scrollKey={`fullscreen:${this.props.viewId}`} />;
    } else if (kind === 'direct') {
      body = (
        <ConversationsListContainer
          scrollKey={`fullscreen:${this.props.viewId}`}
          bindToDocument={false}
          trackScroll={false}
        />
      );
    } else if (kind === 'search') {
      body = this.renderSearch();
    }

    return (
      <div className='fullscreen-column__stream' ref={this.setRoot}>
        <div
          className='fullscreen-column__scale'
          style={scale === 1 ? undefined : { width: `${100 / scale}%`, height: `${100 / scale}%`, zoom: scale }}
        >
          {body}
        </div>
      </div>
    );
  }

}

export default connect(mapStateToProps)(FullscreenStream);
