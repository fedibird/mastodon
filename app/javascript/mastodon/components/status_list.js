import { debounce } from 'lodash';
import React from 'react';
import { connect } from 'react-redux';
import ImmutablePropTypes from 'react-immutable-proptypes';
import PropTypes from 'prop-types';
import StatusContainer from '../containers/status_container';
import ImmutablePureComponent from 'react-immutable-pure-component';
import ReloadZone from './reload_zone';
import LoadGap from './load_gap';
import ScrollableList from './scrollable_list';
import RegenerationIndicator from 'mastodon/components/regeneration_indicator';
import { addIntersectionStatusId, removeIntersectionStatusId } from 'mastodon/actions/statuses';
import { isIOS } from 'mastodon/is_mobile';
import { showReloadButton } from '../initial_state';
import { List as ImmutableList } from 'immutable';

export default @connect()
class StatusList extends ImmutablePureComponent {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    scrollKey: PropTypes.string.isRequired,
    statusIds: ImmutablePropTypes.list.isRequired,
    featuredStatusIds: ImmutablePropTypes.list,
    onLoadMore: PropTypes.func,
    onScrollToTop: PropTypes.func,
    onScroll: PropTypes.func,
    trackScroll: PropTypes.bool,
    isLoading: PropTypes.bool,
    isPartial: PropTypes.bool,
    hasMore: PropTypes.bool,
    prepend: PropTypes.node,
    emptyMessage: PropTypes.node,
    alwaysPrepend: PropTypes.bool,
    timelineId: PropTypes.string,
    showCard: PropTypes.bool,
    trackIntersection: PropTypes.bool,
  };

  static defaultProps = {
    trackScroll: true,
    showCard: true,
    trackIntersection: true,
  };

  getFeaturedStatusCount = () => {
    return this.props.featuredStatusIds ? this.props.featuredStatusIds.size : 0;
  }

  getCurrentStatusIndex = (id, featured) => {
    if (featured) {
      return this.props.featuredStatusIds.indexOf(id);
    } else {
      return this.props.statusIds.indexOf(id) + this.getFeaturedStatusCount();
    }
  }

  handleMoveUp = (id, featured) => {
    const elementIndex = this.getCurrentStatusIndex(id, featured) - 1;
    this._selectChild(elementIndex, true);
  }

  handleMoveDown = (id, featured) => {
    const elementIndex = this.getCurrentStatusIndex(id, featured) + 1;
    this._selectChild(elementIndex, false);
  }

  handleLoadOlder = debounce(() => {
    this.props.onLoadMore(this.props.statusIds.size > 0 ? this.props.statusIds.last() : undefined);
  }, 300, { leading: true })

  handleReload = () => {
    location.reload();
  }

  handleIntersectionChange = (id, isIntersecting) => {
    const { dispatch } = this.props;

    if (isIntersecting) {
      dispatch(addIntersectionStatusId(id));
    } else {
      dispatch(removeIntersectionStatusId(id));
    }
  }

  _selectChild (index, align_top) {
    const container = this.node.node;
    const element = container.querySelector(`article:nth-of-type(${index + 1}) .focusable`);

    if (element) {
      if (align_top && container.scrollTop > element.offsetTop) {
        element.scrollIntoView(true);
      } else if (!align_top && container.scrollTop + container.clientHeight < element.offsetTop + element.offsetHeight) {
        element.scrollIntoView(false);
      }
      element.focus();
    }
  }

  setRef = c => {
    this.node = c;
  }

  render () {
    const { statusIds, featuredStatusIds, onLoadMore, timelineId, showCard, trackIntersection, ...other }  = this.props;
    const { isLoading, isPartial } = other;

    if (isPartial) {
      return <RegenerationIndicator />;
    }

    let scrollableContent = (isLoading || statusIds.size > 0) ? (
      statusIds.map((statusId, index) => statusId === null ? (
        <LoadGap
          key={'gap:' + statusIds.get(index + 1)}
          disabled={isLoading}
          maxId={index > 0 ? statusIds.get(index - 1) : null}
          onClick={onLoadMore}
        />
      ) : (
        <StatusContainer
          key={statusId}
          id={statusId}
          onMoveUp={this.handleMoveUp}
          onMoveDown={this.handleMoveDown}
          contextType={timelineId}
          scrollKey={this.props.scrollKey}
          showThread
          showCard={showCard}
        />
      ))
    ) : ImmutableList();

    if (scrollableContent && featuredStatusIds) {
      scrollableContent = featuredStatusIds.map(statusId => (
        <StatusContainer
          key={`f-${statusId}`}
          id={statusId}
          featured
          onMoveUp={this.handleMoveUp}
          onMoveDown={this.handleMoveDown}
          contextType={timelineId}
          showThread
          showCard={showCard}
        />
      )).concat(scrollableContent);
    }

    if (showReloadButton && scrollableContent && isIOS()) {
      scrollableContent = scrollableContent.unshift(<ReloadZone key='reload' onClick={this.handleReload} />);
    }

    return (
      <ScrollableList {...other} showLoading={isLoading && statusIds.size === 0} onLoadMore={onLoadMore && this.handleLoadOlder} onIntersectionChange={trackIntersection ? this.handleIntersectionChange : undefined} ref={this.setRef}>
        {scrollableContent}
      </ScrollableList>
    );
  }

}
