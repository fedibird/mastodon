import React, { PureComponent } from 'react';
import PropTypes from 'prop-types';
import { FormattedMessage } from 'react-intl';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { connect } from 'react-redux';
import { debounce } from 'lodash';

import { fetchTrendingStatuses, expandTrendingStatuses } from 'mastodon/actions/trends';
import StatusList from 'mastodon/components/status_list';

const mapStateToProps = state => ({
  statusIds: state.getIn(['status_lists', 'trending', 'items']),
  isLoading: state.getIn(['status_lists', 'trending', 'isLoading'], true),
  hasMore: !!state.getIn(['status_lists', 'trending', 'next']),
});

export default @connect(mapStateToProps)
class Statuses extends PureComponent {

  static propTypes = {
    statusIds: ImmutablePropTypes.list.isRequired,
    isLoading: PropTypes.bool,
    hasMore: PropTypes.bool,
    multiColumn: PropTypes.bool,
    dispatch: PropTypes.func.isRequired,
  };

  componentDidMount () {
    this.props.dispatch(fetchTrendingStatuses());
  }

  componentWillUnmount () {
    this.handleLoadMore.cancel();
  }

  handleLoadMore = debounce(() => {
    this.props.dispatch(expandTrendingStatuses());
  }, 300, { leading: true });

  render () {
    const { isLoading, hasMore, statusIds, multiColumn } = this.props;
    const emptyMessage = <FormattedMessage id='empty_column.explore_statuses' defaultMessage='Nothing is trending right now. Check back later!' />;

    return (
      <StatusList
        trackScroll
        timelineId='explore'
        statusIds={statusIds}
        scrollKey='explore-statuses'
        hasMore={hasMore}
        isLoading={isLoading}
        onLoadMore={this.handleLoadMore}
        emptyMessage={emptyMessage}
        bindToDocument={!multiColumn}
      />
    );
  }

}
