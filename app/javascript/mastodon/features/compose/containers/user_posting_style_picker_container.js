import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { injectIntl, defineMessages } from 'react-intl';
import { List as ImmutableList } from 'immutable';
import { openModal } from '../../../actions/modal';
import { commitUserPostingStyle } from '../../../actions/user_posting_styles';
import { selectComposerPostingContextCompliance } from '../../../posting_context/compliance';
import { resolveUserPostingStyle } from '../../../posting_context/user_style_resolver';
import { selectComposer } from '../../../selectors/composer';
import { PRIMARY_COMPOSER_ID } from '../../../utils/composer';
import { withComposerId } from '../composer_id_context';
import UserPostingStylePicker from '../components/user_posting_style_picker';

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
  const catalogReady = state.getIn(['userPostingStyles', 'status']) === 'ready';
  const editing = Boolean(composer && (composer.get('id') || composer.get('scheduled_status_id')));
  const visible = composerId === PRIMARY_COMPOSER_ID && catalogReady && !editing && Boolean(composer);

  if (!composer || !visible) {
    return { visible: false, styles: ImmutableList() };
  }

  const compliance = selectComposerPostingContextCompliance(state, composerId);

  return {
    visible: true,
    styles: state.getIn(['userPostingStyles', 'styles'], ImmutableList()),
    selectedId: composer.getIn(['userPostingStyle', 'selectedId']),
    snapshot: composer.getIn(['userPostingStyle', 'snapshot']),
    unapplied: composer.getIn(['userPostingStyle', 'unapplied'], ImmutableList()),
    destinationStatus: composer.getIn(['userPostingStyle', 'destinationStatus']),
    visibilityConflict: Boolean(compliance.visibility && compliance.visibility.valid === false && compliance.visibility.allowed),
  };
};

const mapDispatchToProps = (dispatch, { intl, composerId }) => ({
  onSelect (styleId) {
    dispatch((_, getState) => {
      const composer = selectComposer(getState(), composerId);

      if (!composer) {
        return;
      }

      const style = styleId === null || styleId === undefined ? null : findStyle(getState(), styleId);
      const plan = resolveUserPostingStyle(style, composer);
      const apply = () => dispatch(commitUserPostingStyle(composerId, styleId));

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
  },
});

const VisiblePicker = ({ visible, ...props }) => (visible ? <UserPostingStylePicker {...props} /> : null);

VisiblePicker.propTypes = {
  visible: PropTypes.bool,
};

export default withComposerId(injectIntl(connect(mapStateToProps, mapDispatchToProps)(VisiblePicker)));
