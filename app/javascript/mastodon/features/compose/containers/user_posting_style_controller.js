import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { fetchUserPostingStyles, resolveUserPostingStyleDestination } from '../../../actions/user_posting_styles';
import { isAdministrator } from '../../../initial_state';
import { selectComposer } from '../../../selectors/composer';
import { PRIMARY_COMPOSER_ID } from '../../../utils/composer';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);

  return {
    active: composerId === PRIMARY_COMPOSER_ID && Boolean(composer),
    destinationStatus: composer ? composer.getIn(['userPostingStyle', 'destinationStatus']) : null,
  };
};

class UserPostingStyleController extends React.PureComponent {

  static propTypes = {
    active: PropTypes.bool,
    destinationStatus: PropTypes.string,
    dispatch: PropTypes.func.isRequired,
    composerId: PropTypes.string,
  };

  componentDidMount () {
    this.fetchStyles();
    this.resolveIfNeeded();
  }

  componentDidUpdate () {
    this.resolveIfNeeded();
  }

  fetchStyles () {
    if (this.props.active && isAdministrator) {
      this.props.dispatch(fetchUserPostingStyles());
    }
  }

  resolveIfNeeded () {
    if (!this.props.active || this.props.destinationStatus !== 'needs_resolve') {
      return;
    }

    this.props.dispatch(resolveUserPostingStyleDestination(this.props.composerId));
  }

  render () {
    return null;
  }

}

export default withComposerId(connect(mapStateToProps)(UserPostingStyleController));