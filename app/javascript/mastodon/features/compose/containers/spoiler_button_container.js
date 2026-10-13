import { connect } from 'react-redux';
import TextIconButton from '../components/text_icon_button';
import { changeComposeSpoilerness } from '../../../actions/compose';
import { targetComposerAction } from '../../../actions/composer';
import { scheduleComposerInteractionCheck } from '../../../actions/posting_identities';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';
import { injectIntl, defineMessages } from 'react-intl';

const messages = defineMessages({
  marked: { id: 'compose_form.spoiler.marked', defaultMessage: 'Text is hidden behind warning' },
  unmarked: { id: 'compose_form.spoiler.unmarked', defaultMessage: 'Text is not hidden' },
});

const mapStateToProps = (state, { intl, composerId }) => {
  const composer = selectComposer(state, composerId);

  return {
    label: 'CW',
    title: intl.formatMessage(composer.get('spoiler') ? messages.marked : messages.unmarked),
    active: composer.get('spoiler'),
    ariaControls: 'cw-spoiler-input',
  };
};

const mapDispatchToProps = (dispatch, { composerId, onExpandComposer }) => ({

  onClick () {
    dispatch((_, getState) => {
      const composer = selectComposer(getState(), composerId);

      if (!composer) {
        return;
      }

      if (composer.get('spoiler') && onExpandComposer) {
        onExpandComposer();
        return;
      }

      dispatch(targetComposerAction(changeComposeSpoilerness(), composerId));
      dispatch(scheduleComposerInteractionCheck(composerId));

      if (!composer.get('spoiler') && onExpandComposer) {
        onExpandComposer();
      }
    });
  },

});

export default withComposerId(injectIntl(connect(mapStateToProps, mapDispatchToProps)(TextIconButton)));
