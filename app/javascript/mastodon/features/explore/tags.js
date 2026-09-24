import React, { PureComponent } from 'react';
import PropTypes from 'prop-types';
import { FormattedMessage } from 'react-intl';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { connect } from 'react-redux';

import { fetchTrendingHashtags } from 'mastodon/actions/trends';
import Hashtag from 'mastodon/components/hashtag';
import LoadingIndicator from 'mastodon/components/loading_indicator';

const mapStateToProps = state => ({
  hashtags: state.getIn(['trends', 'tags', 'items']),
  isLoading: state.getIn(['trends', 'tags', 'isLoading']),
});

export default @connect(mapStateToProps)
class Tags extends PureComponent {

  static propTypes = {
    hashtags: ImmutablePropTypes.list.isRequired,
    isLoading: PropTypes.bool,
    dispatch: PropTypes.func.isRequired,
  };

  componentDidMount () {
    this.props.dispatch(fetchTrendingHashtags());
  }

  render () {
    const { isLoading, hashtags } = this.props;

    if (!isLoading && hashtags.isEmpty()) {
      return (
        <div className='explore__links scrollable scrollable--flex'>
          <div className='empty-column-indicator'>
            <FormattedMessage id='empty_column.explore_statuses' defaultMessage='Nothing is trending right now. Check back later!' />
          </div>
        </div>
      );
    }

    return (
      <div className='scrollable explore__links' data-nosnippet>
        {isLoading ? <LoadingIndicator /> : hashtags.map(hashtag => (
          <Hashtag key={hashtag.get('name')} hashtag={hashtag} />
        ))}
      </div>
    );
  }

}
