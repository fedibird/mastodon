import { connect } from 'react-redux';
import DateTimeDropdown from '../components/datetime_dropdown';
import { changeExpires } from '../../../actions/compose';
import { getDateTimeFromText } from '../../../actions/compose';
import { targetComposerAction } from '../../../actions/composer';
import { getComposerStatePath, selectComposer } from '../../../selectors/composer';
import { addDays, addSeconds, set } from 'date-fns';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);
  const valueKey = getComposerStatePath(composerId, 'expires');
  const value = composer.get('expires') ?? '';
  const scheduledAt = getDateTimeFromText(composer.get('scheduled'), new Date()).at ?? new Date();

  return {
    value: value,
    valueKey: valueKey,
    origin: scheduledAt,
    minDate: addSeconds(scheduledAt, 60),
    maxDate: addSeconds(scheduledAt, 37152000),
    openToDate: set(addDays(scheduledAt, 1), { minutes: 0, seconds: 0 }),
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({

  onChange (value) {
    dispatch(targetComposerAction(changeExpires(value), composerId));
  },

});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(DateTimeDropdown));
