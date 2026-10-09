import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { injectIntl, defineMessages } from 'react-intl';
import { List as ImmutableList } from 'immutable';
import { openModal } from '../../../actions/modal';
import { fetchUserPostingContextAssignment, resetGuardedPlaceDefault, saveGuardedPlaceDefault } from '../../../actions/user_posting_context_assignments';
import { commitUserPostingStyle, fetchUserPostingStyles, retryUserPostingStyleDestination } from '../../../actions/user_posting_styles';
import { selectComposerPostingContextCompliance } from '../../../posting_context/compliance';
import { placeDefaultWriteSurface, selectPortablePostingStyleCandidates, styleMatchesSurface, surfaceCacheKey } from '../../../posting_context/surface';
import { resolveUserPostingStyle } from '../../../posting_context/user_style_resolver';
import { PORTABLE_COMPOSER_MODE_SIMPLE, selectComposer, selectPortableComposerDisplayMode } from '../../../selectors/composer';
import { PRIMARY_COMPOSER_ID } from '../../../utils/composer';
import { withComposerId } from '../composer_id_context';
import UserPostingStylePicker, { IntlUserPostingStyleCatalogNotice } from '../components/user_posting_style_picker';

const messages = defineMessages({
  confirmMessage: { id: 'compose_form.posting_style.confirm_message', defaultMessage: 'The destination or visibility of this draft may change. Apply this posting style?' },
  confirm: { id: 'compose_form.posting_style.confirm', defaultMessage: 'Apply' },
});

const findStyle = (state, styleId) => {
  const styles = state.getIn(['userPostingStyles', 'styles']);

  if (!styles || !styles.find) {
    return null;
  }

  return styles.find(style => style.get('id') === String(styleId)) || null;
};

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);
  const catalogStatus = state.getIn(['userPostingStyles', 'status']);
  const editing = Boolean(composer && (composer.get('id') || composer.get('scheduled_status_id')));
  const surface = composer && composer.get('surface');
  const portable = Boolean(surface);
  const eligible = !editing && Boolean(composer) && (composerId === PRIMARY_COMPOSER_ID || portable);
  const visible = eligible && catalogStatus === 'ready';
  const catalogFailed = eligible && catalogStatus === 'failed';

  if (!composer || (!visible && !catalogFailed)) {
    return { visible: false, catalogFailed: false, styles: ImmutableList() };
  }

  const compliance = selectComposerPostingContextCompliance(state, composerId);
  const styles = state.getIn(['userPostingStyles', 'styles'], ImmutableList());
  const kind = surface && surface.get('kind');
  const cacheKey = surfaceCacheKey(surface);
  const assignment = cacheKey && state.getIn(['userPostingContextAssignments', 'bySurface', cacheKey]);

  return {
    visible,
    catalogFailed,
    styles: portable ? selectPortablePostingStyleCandidates(styles, surface) : styles,
    emptyLabel: kind === 'group' || kind === 'hashtag' ? 'place' : 'usual',
    compact: portable && selectPortableComposerDisplayMode(state, composerId) === PORTABLE_COMPOSER_MODE_SIMPLE,
    selectedId: composer.getIn(['userPostingStyle', 'selectedId']),
    snapshot: composer.getIn(['userPostingStyle', 'snapshot']),
    unapplied: composer.getIn(['userPostingStyle', 'unapplied'], ImmutableList()),
    destinationStatus: composer.getIn(['userPostingStyle', 'destinationStatus']),
    destinationFailure: composer.getIn(['userPostingStyle', 'destinationFailure']),
    visibilityConflict: Boolean(compliance.visibility && compliance.visibility.valid === false && compliance.visibility.allowed),
    showDefaults: portable,
    surfaceKind: surface ? surface.get('kind') : null,
    surfaceKey: surface ? String(surface.get('key')) : null,
    assignmentFetchStatus: assignment ? assignment.get('status') : 'idle',
    assignmentStatus: assignment ? assignment.get('assignmentStatus') : null,
    assignmentStyleId: assignment ? assignment.get('styleId') : null,
    assignmentFailure: assignment ? assignment.get('failure') : null,
    defaultsBlocked: portable && !placeDefaultWriteSurface(composer),
  };
};

const mapDispatchToProps = (dispatch, { intl, composerId }) => {
  const applyStyle = styleId => {
    dispatch((_, getState) => {
      const composer = selectComposer(getState(), composerId);

      if (!composer) {
        return;
      }

      const style = styleId === null || styleId === undefined ? null : findStyle(getState(), styleId);
      const surface = composer.get('surface');
      const destinationPolicy = surface ? 'locked' : 'change';

      if (destinationPolicy === 'locked' && (composer.get('surfaceMismatch') || (style && !styleMatchesSurface(style, surface)))) {
        return;
      }

      const plan = resolveUserPostingStyle(style, composer, { destinationPolicy });
      const expectedSurface = surface ? { kind: surface.get('kind'), key: surface.get('key') } : null;
      const apply = () => dispatch(commitUserPostingStyle(composerId, styleId, { expectedSurface }));

      if (plan.needsConfirmation) {
        dispatch(openModal('CONFIRM', {
          message: intl.formatMessage(messages.confirmMessage),
          confirm: intl.formatMessage(messages.confirm),
          onConfirm: apply,
        }));
        return;
      }

      apply();
    });
  };

  return {
    onSelect: applyStyle,
    onRetry () {
      dispatch(retryUserPostingStyleDestination(composerId));
    },
    onRetryCatalog () {
      dispatch(fetchUserPostingStyles({ force: true }));
    },
    onSaveDefault (styleId) {
      dispatch(saveGuardedPlaceDefault(composerId, styleId));
    },
    onUseNoStyle () {
      dispatch(saveGuardedPlaceDefault(composerId, null));
    },
    onResetDefault () {
      dispatch(resetGuardedPlaceDefault(composerId));
    },
    onRetryAssignment () {
      dispatch((_, getState) => {
        const composer = selectComposer(getState(), composerId);
        const surface = composer && composer.get('surface');

        if (!surface) {
          return;
        }

        dispatch(fetchUserPostingContextAssignment({ kind: surface.get('kind'), key: surface.get('key') }, { force: true }));
      });
    },
  };
};

const VisiblePicker = ({ visible, catalogFailed, onRetryCatalog, ...props }) => {
  if (catalogFailed) {
    return <IntlUserPostingStyleCatalogNotice onRetry={onRetryCatalog} />;
  }

  return visible ? <UserPostingStylePicker {...props} /> : null;
};

VisiblePicker.propTypes = {
  visible: PropTypes.bool,
  catalogFailed: PropTypes.bool,
  onRetryCatalog: PropTypes.func,
};

export default withComposerId(injectIntl(connect(mapStateToProps, mapDispatchToProps)(VisiblePicker)));
