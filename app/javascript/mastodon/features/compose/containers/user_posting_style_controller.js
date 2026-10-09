import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { fetchUserPostingStyles, maybeAutoSelectPortablePostingStyle, resolveUserPostingStyleDestination } from '../../../actions/user_posting_styles';
import { isAdministrator } from '../../../initial_state';
import { selectComposer } from '../../../selectors/composer';
import { PRIMARY_COMPOSER_ID } from '../../../utils/composer';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);
  const editing = Boolean(composer && (composer.get('id') || composer.get('scheduled_status_id')));
  const surface = composer && composer.get('surface');
  const portable = Boolean(surface) && !editing;

  return {
    active: !editing && Boolean(composer) && (composerId === PRIMARY_COMPOSER_ID || portable),
    portable,
    destinationLocked: portable || (composer ? composer.getIn(['userPostingStyle', 'destinationPolicy']) === 'locked' : false),
    destinationStatus: composer ? composer.getIn(['userPostingStyle', 'destinationStatus']) : null,
    catalogStatus: state.getIn(['userPostingStyles', 'status']),
    styleCount: state.getIn(['userPostingStyles', 'styles']) ? state.getIn(['userPostingStyles', 'styles']).size : 0,
    selectionOrigin: composer ? composer.getIn(['userPostingStyle', 'selectionOrigin']) : null,
    styleInputLock: composer ? composer.getIn(['userPostingStyle', 'styleInputLock']) : false,
    surfaceKey: surface ? `${surface.get('kind')}:${surface.get('key')}` : null,
    contextKey: composer ? composer.getIn(['context', 'key']) : null,
  };
};

class UserPostingStyleController extends React.PureComponent {

  static propTypes = {
    active: PropTypes.bool,
    portable: PropTypes.bool,
    destinationLocked: PropTypes.bool,
    destinationStatus: PropTypes.string,
    catalogStatus: PropTypes.string,
    dispatch: PropTypes.func.isRequired,
    composerId: PropTypes.string,
  };

  componentDidMount () {
    this.fetchStyles();
    this.resolveIfNeeded();
    this.autoSelectIfNeeded();
  }

  componentDidUpdate () {
    this.resolveIfNeeded();
    this.autoSelectIfNeeded();
  }

  fetchStyles () {
    if (this.props.active && isAdministrator) {
      this.props.dispatch(fetchUserPostingStyles());
    }
  }

  resolveIfNeeded () {
    if (!this.props.active || this.props.destinationLocked || this.props.destinationStatus !== 'needs_resolve') {
      return;
    }

    this.props.dispatch(resolveUserPostingStyleDestination(this.props.composerId));
  }

  autoSelectIfNeeded () {
    const { portable, catalogStatus, composerId, dispatch } = this.props;

    if (!portable || !isAdministrator || catalogStatus === 'loading' || catalogStatus === 'failed' || !composerId) {
      return;
    }

    dispatch(maybeAutoSelectPortablePostingStyle(composerId));
  }

  render () {
    return null;
  }

}

export default withComposerId(connect(mapStateToProps)(UserPostingStyleController));