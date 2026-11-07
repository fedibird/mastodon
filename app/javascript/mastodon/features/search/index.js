import React from 'react';
import { connect } from 'react-redux';
import PropTypes from 'prop-types';
import { FormattedMessage } from 'react-intl';
import SearchContainer from 'mastodon/features/compose/containers/search_container';
import SearchResultsContainer from 'mastodon/features/compose/containers/search_results_container';
import { openFullscreenColumn } from 'mastodon/actions/fullscreen_column';
import { rememberFullscreenOpener } from 'mastodon/utils/fullscreen_column';

class Search extends React.PureComponent {

  static propTypes = {
    dispatch: PropTypes.func.isRequired,
    layout: PropTypes.string,
  };

  handleOpen = (event) => {
    rememberFullscreenOpener(event.currentTarget);
    this.props.dispatch(openFullscreenColumn({ fullscreenKind: 'search', title: 'Search', icon: 'search' }));
  }

  render () {
    const { layout } = this.props;

    return (
      <div className='column search-page'>
        <SearchContainer />
        {layout && layout !== 'mobile' && (
          <button
            type='button'
            className='fullscreen-column__search-open'
            onClick={this.handleOpen}
          >
            <FormattedMessage id='fullscreen_column.open' defaultMessage='Open fullscreen' />
          </button>
        )}

        <div className='drawer__pager'>
          <div className='drawer__inner darker'>
            <SearchResultsContainer />
          </div>
        </div>
      </div>
    );
  }

}

export default connect(state => ({
  layout: state.getIn(['meta', 'layout']),
}))(Search);
