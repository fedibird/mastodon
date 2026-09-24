import React, { PureComponent } from 'react';
import PropTypes from 'prop-types';
import { FormattedMessage } from 'react-intl';
import ImmutablePropTypes from 'react-immutable-proptypes';
import { connect } from 'react-redux';

import { fetchTrendingLinks } from 'mastodon/actions/trends';
import LoadingIndicator from 'mastodon/components/loading_indicator';

import Story from './components/story';

const mapStateToProps = state => ({
  links: state.getIn(['trends', 'links', 'items']),
  isLoading: state.getIn(['trends', 'links', 'isLoading']),
});

export default @connect(mapStateToProps)
class Links extends PureComponent {

  static propTypes = {
    links: ImmutablePropTypes.list.isRequired,
    isLoading: PropTypes.bool,
    dispatch: PropTypes.func.isRequired,
  };

  componentDidMount () {
    this.props.dispatch(fetchTrendingLinks());
  }

  render () {
    const { isLoading, links } = this.props;

    if (!isLoading && links.isEmpty()) {
      return (
        <div className='explore__links scrollable scrollable--flex'>
          <div className='empty-column-indicator'>
            <FormattedMessage id='empty_column.explore_statuses' defaultMessage='Nothing is trending right now. Check back later!' />
          </div>
        </div>
      );
    }

    return (
      <div className='explore__links scrollable' data-nosnippet>
        {isLoading ? <LoadingIndicator /> : links.map((link, index) => (
          <Story
            key={link.get('id')}
            expanded={index === 0}
            lang={link.get('language')}
            url={link.get('url')}
            title={link.get('title')}
            publisher={link.get('provider_name')}
            publishedAt={link.get('published_at')}
            author={link.get('author_name')}
            sharedTimes={(link.getIn(['history', 0, 'accounts'], 0) * 1) + (link.getIn(['history', 1, 'accounts'], 0) * 1)}
            thumbnail={link.get('image')}
            thumbnailDescription={link.get('image_description')}
            blurhash={link.get('blurhash')}
          />
        ))}
      </div>
    );
  }

}
