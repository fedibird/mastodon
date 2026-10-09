import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { fetchUserPostingContextAssignment } from '../../../actions/user_posting_context_assignments';
import { fetchUserPostingStyles, maybeAutoSelectPortablePostingStyle, resolveUserPostingStyleDestination } from '../../../actions/user_posting_styles';
import { isAdministrator } from '../../../initial_state';
import { surfaceCacheKey } from '../../../posting_context/surface';
import { selectComposer } from '../../../selectors/composer';
import { PRIMARY_COMPOSER_ID } from '../../../utils/composer';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);
  const editing = Boolean(composer && (composer.get('id') || composer.get('scheduled_status_id')));
  const surface = composer && composer.get('surface');
  const portable = Boolean(surface) && !editing;
  const cacheKey = surfaceCacheKey(surface);
  const assignment = cacheKey && state.getIn(['userPostingContextAssignments', 'bySurface', cacheKey]);

  return {
    active: !editing && Boolean(composer) && (composerId === PRIMARY_COMPOSER_ID || portable),
    portable,
    destinationLocked: portable || (composer ? composer.getIn(['userPostingStyle', 'destinationPolicy']) === 'locked' : false),
    destinationStatus: composer ? composer.getIn(['userPostingStyle', 'destinationStatus']) : null,
    catalogStatus: state.getIn(['userPostingStyles', 'status']),
    assignmentFetchStatus: assignment ? assignment.get('status') : 'idle',
    styleCount: state.getIn(['userPostingStyles', 'styles']) ? state.getIn(['userPostingStyles', 'styles']).size : 0,
    selectionOrigin: composer ? composer.getIn(['userPostingStyle', 'selectionOrigin']) : null,
    styleInputLock: composer ? composer.getIn(['userPostingStyle', 'styleInputLock']) : false,
    surfaceKind: surface ? surface.get('kind') : null,
    surfaceKey: surface ? String(surface.get('key')) : null,
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
    assignmentFetchStatus: PropTypes.string,
    surfaceKind: PropTypes.string,
    surfaceKey: PropTypes.string,
    dispatch: PropTypes.func.isRequired,
    composerId: PropTypes.string,
  };

  componentDidMount () {
    this.fetchStyles();
    this.fetchAssignment();
    this.resolveIfNeeded();
    this.autoSelectIfNeeded();
  }

  componentDidUpdate () {
    this.fetchAssignment();
    this.resolveIfNeeded();
    this.autoSelectIfNeeded();
  }

  fetchStyles () {
    if (this.props.active && isAdministrator) {
      this.props.dispatch(fetchUserPostingStyles());
    }
  }

  fetchAssignment () {
    const { portable, surfaceKind, surfaceKey, dispatch } = this.props;

    if (portable && isAdministrator && surfaceKind && surfaceKey) {
      dispatch(fetchUserPostingContextAssignment({ kind: surfaceKind, key: surfaceKey }));
    }
  }

  resolveIfNeeded () {
    if (!this.props.active || this.props.destinationLocked || this.props.destinationStatus !== 'needs_resolve') {
      return;
    }

    this.props.dispatch(resolveUserPostingStyleDestination(this.props.composerId));
  }

  autoSelectIfNeeded () {
    const { portable, catalogStatus, assignmentFetchStatus, composerId, dispatch } = this.props;

    if (!portable || !isAdministrator || catalogStatus !== 'ready' || assignmentFetchStatus !== 'ready' || !composerId) {
      return;
    }

    dispatch(maybeAutoSelectPortablePostingStyle(composerId));
  }

  render () {
    return null;
  }

}

export default withComposerId(connect(mapStateToProps)(UserPostingStyleController));