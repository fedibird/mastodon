import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { FormattedMessage } from 'react-intl';
import { List as ImmutableList } from 'immutable';
import StatusList from 'mastodon/components/status_list';
import StatusListContainer from 'mastodon/features/ui/containers/status_list_container';
import { layoutModeForPresentation, fullscreenScaleFactor } from 'mastodon/utils/fullscreen_column';
import { scrollTopDeltaForVisualDelta, usedCssZoom } from 'mastodon/utils/css_zoom';
import { mixTimelineView } from 'mastodon/mix/view';
import { accountGalleryAttachments } from 'mastodon/selectors';
import { accountMediaRevealKey, accountMediaTimelineSequence } from 'mastodon/utils/media_timeline_sequence';
import AccountMediaItems from 'mastodon/features/account_gallery/components/media_items';
import LoadMore from 'mastodon/components/load_more';
import { openModal } from 'mastodon/actions/modal';
import { expandSearch } from 'mastodon/actions/search';
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
    mediaFilters: state.get('filters'),
    mediaFilterMatches: state.get('filterMatches'),
    mediaFilterGeneration: state.getIn(['filterMatches', 'generation'], 0),
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
    mediaFilters: PropTypes.object,
    mediaFilterMatches: PropTypes.object,
    mediaFilterGeneration: PropTypes.number,
  };

  state = {
    revealedMediaIds: new Set(),
    revealedFilterStatusIds: new Set(),
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

    const visualDelta = node.getBoundingClientRect().top - scroller.getBoundingClientRect().top;
    scroller.scrollTop += scrollTopDeltaForVisualDelta(visualDelta, usedCssZoom(scroller));
    this.anchored = true;
  }

  handleLoadMore = (maxId) => {
    let cursor = typeof maxId === 'string' ? maxId : undefined;

    if (!cursor && this.props.source.get('expand') === 'account_media' && this.props.mediaTimeline) {
      const ids = this.props.mediaTimeline.get('items');
      cursor = ids && ids.findLast ? ids.findLast(id => id !== null) : undefined;
    }

    this.props.dispatch((dispatch, getState) => {
      expandFullscreenSource(dispatch, getState, this.props.source, cursor);
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

  accountFilterInfo () {
    return {
      filters: this.props.mediaFilters,
      matches: this.props.mediaFilterMatches,
      generation: this.props.mediaFilterGeneration,
      revealedMediaIds: this.state.revealedMediaIds,
      revealedFilterStatusIds: this.state.revealedFilterStatusIds,
    };
  }

  handleRevealAccountMedia = (attachment) => {
    const key = accountMediaRevealKey(attachment);
    const statusId = attachment && attachment.getIn(['status', 'id']);

    this.setState(({ revealedMediaIds, revealedFilterStatusIds }) => ({
      revealedMediaIds: new Set([...revealedMediaIds, key]),
      revealedFilterStatusIds: statusId ? new Set([...revealedFilterStatusIds, statusId]) : revealedFilterStatusIds,
    }));
  }

  handleOpenAccountMedia = (attachment) => {
    const { dispatch, mediaTimeline, statuses, account, presentation, source } = this.props;
    const statusId = attachment.getIn(['status', 'id']);
    const type = attachment.get('type');

    if (type === 'video') {
      dispatch(openModal('VIDEO', { media: attachment, statusId, options: { autoPlay: true } }));
      return;
    }

    if (type === 'audio') {
      dispatch(openModal('AUDIO', { media: attachment, statusId, options: { autoPlay: true } }));
      return;
    }

    const statusIds = mediaTimeline ? mediaTimeline.get('items', empty) : empty;
    const filterInfo = this.accountFilterInfo();
    const attachments = accountGalleryAttachments(statusIds, statuses, account, filterInfo);
    const sequence = accountMediaTimelineSequence(attachments, presentation.get('mediaVisibility'), filterInfo);
    const position = sequence.media.findIndex(item => item.get('id') === attachment.get('id'));

    dispatch(openModal('MEDIA', {
      media: position >= 0 ? sequence.media : attachment.getIn(['status', 'media_attachments']),
      index: position >= 0 ? position : 0,
      statusId,
      timelineStatusIds: position >= 0 ? sequence.statusIds : undefined,
      mediaSource: position >= 0 ? {
        kind: 'account',
        accountId: source.get('accountId'),
        timelineId: source.get('dataTimelineId'),
        afterStatusId: statusIds.findLast(id => id !== null),
        visibility: presentation.get('mediaVisibility'),
      } : undefined,
    }));
  }

  handleExpandSearch = (type) => {
    this.props.dispatch(expandSearch(type));
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
    const attachments = accountGalleryAttachments(statusIds, statuses, account, this.accountFilterInfo());
    const isLoading = !!(mediaTimeline && mediaTimeline.get('isLoading'));
    const hasMore = !!(mediaTimeline && mediaTimeline.get('hasMore'));
    const loadOlder = hasMore ? (
      <LoadMore visible={!isLoading} onClick={this.handleLoadMore} />
    ) : null;

    return (
      <div className='scrollable fullscreen-column__media' onScroll={this.handleAccountMediaScroll}>
        <AccountMediaItems
          attachments={attachments || empty}
          shape={presentation.get('mediaShape')}
          size={presentation.get('mediaSize')}
          visibility={presentation.get('mediaVisibility')}
          onOpenMedia={this.handleOpenAccountMedia}
          onReveal={this.handleRevealAccountMedia}
          onLoadMore={this.handleLoadMore}
          loadOlder={loadOlder}
        />
      </div>
    );
  }

  handleAccountMediaScroll = (event) => {
    const node = event.currentTarget;
    const remaining = node.scrollHeight - node.scrollTop - node.clientHeight;
    const timeline = this.props.mediaTimeline;

    if (remaining < 150 && timeline && timeline.get('hasMore') && !timeline.get('isLoading')) {
      this.handleLoadMore();
    }
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
          expandSearch={this.handleExpandSearch}
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
