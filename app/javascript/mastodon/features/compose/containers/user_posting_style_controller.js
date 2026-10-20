import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { fetchGlobalUsualStyle, fetchUserPostingContextAssignment, registerAssignmentConsumer, unregisterAssignmentConsumer } from '../../../actions/user_posting_context_assignments';
import { fetchUserPostingStyles, resolveUserPostingStyleDestination, settleUsualSelection, USER_POSTING_STYLE_RESOLUTION } from '../../../actions/user_posting_styles';
import { targetComposerAction } from '../../../actions/composer';
import { isAdministrator } from '../../../initial_state';
import { portablePostingContextReady, surfaceCacheKey } from '../../../posting_context/surface';
import { selectComposer } from '../../../selectors/composer';
import { PRIMARY_COMPOSER_ID } from '../../../utils/composer';
import { withComposerId } from '../composer_id_context';

let nextAssignmentConsumerId = 0;

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
    assignmentFetchStatus: assignment?.get('writePending') ? 'saving' : (assignment?.get('status') || 'idle'),
    styleCount: state.getIn(['userPostingStyles', 'styles']) ? state.getIn(['userPostingStyles', 'styles']).size : 0,
    selectionOrigin: composer ? composer.getIn(['userPostingStyle', 'selectionOrigin']) : null,
    styleInputLock: composer ? composer.getIn(['userPostingStyle', 'styleInputLock']) : false,
    globalStatus: state.getIn(['userPostingContextAssignments', 'global', 'status']) || 'idle',
    globalAssignmentStatus: state.getIn(['userPostingContextAssignments', 'global', 'assignmentStatus']) || null,
    globalStyleId: state.getIn(['userPostingContextAssignments', 'global', 'styleId']) || null,
    revalidateUsual: Boolean(composer && composer.getIn(['userPostingStyle', 'revalidateUsual'])),
    defaultsSettledSurface: composer ? composer.getIn(['userPostingStyle', 'defaultsSettledSurface']) : null,
    resolutionRequired: Boolean(composer && composer.getIn(['userPostingStyle', 'resolutionRequired'])),
    surfaceKind: surface ? surface.get('kind') : null,
    surfaceKey: surface ? String(surface.get('key')) : null,
    contextKey: composer ? composer.getIn(['context', 'key']) : null,
    postingContextReady: portablePostingContextReady(composer),
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
    postingContextReady: PropTypes.bool,
    resolutionRequired: PropTypes.bool,
    dispatch: PropTypes.func.isRequired,
    composerId: PropTypes.string,
  };

  assignmentConsumerId = ++nextAssignmentConsumerId;

  componentDidMount () {
    this.syncAssignmentConsumer();
    this.markResolutionRequired();
    this.fetchStyles();
    this.fetchAssignment();
    this.fetchUsual();
    this.resolveIfNeeded();
    this.settleIfNeeded();
  }

  componentDidUpdate () {
    this.syncAssignmentConsumer();
    this.markResolutionRequired();
    this.fetchAssignment();
    this.fetchUsual();
    this.resolveIfNeeded();
    this.settleIfNeeded();
  }

  componentWillUnmount () {
    if (this.registeredSurface) this.props.dispatch(unregisterAssignmentConsumer(this.assignmentConsumerId));
  }

  syncAssignmentConsumer () {
    const { portable, surfaceKind, surfaceKey, dispatch } = this.props;
    const key = portable && isAdministrator && surfaceKind && surfaceKey ? `${surfaceKind}:${surfaceKey}` : null;
    if (this.registeredSurface === key) return;
    this.registeredSurface = key;
    dispatch(key ? registerAssignmentConsumer(this.assignmentConsumerId, { kind: surfaceKind, key: surfaceKey }) : unregisterAssignmentConsumer(this.assignmentConsumerId));
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

  fetchUsual () {
    if (this.props.active && isAdministrator) {
      this.props.dispatch(fetchGlobalUsualStyle());
    }
  }

  markResolutionRequired () {
    const { active, composerId, resolutionRequired, dispatch } = this.props;

    if (!active || !isAdministrator || !composerId || resolutionRequired) {
      return;
    }

    dispatch(targetComposerAction({
      type: USER_POSTING_STYLE_RESOLUTION,
      resolutionRequired: true,
    }, composerId));
  }

  resolveIfNeeded () {
    if (!this.props.active || this.props.destinationLocked || this.props.destinationStatus !== 'needs_resolve') {
      return;
    }

    this.props.dispatch(resolveUserPostingStyleDestination(this.props.composerId));
  }

  settleIfNeeded () {
    const { active, composerId, dispatch } = this.props;

    if (!active || !isAdministrator || !composerId) {
      return;
    }

    dispatch(settleUsualSelection(composerId));
  }

  render () {
    return null;
  }

}

export default withComposerId(connect(mapStateToProps)(UserPostingStyleController));