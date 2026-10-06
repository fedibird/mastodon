import { connect } from 'react-redux';
import DateTimeDropdown from '../components/datetime_dropdown';
import { changeScheduled } from '../../../actions/compose';
import { targetComposerAction } from '../../../actions/composer';
import { getComposerStatePath, selectComposer } from '../../../selectors/composer';
import { addDays, addSeconds, set } from 'date-fns';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => {
  const valueKey = getComposerStatePath(composerId, 'scheduled');
  const value = selectComposer(state, composerId).get('scheduled') ?? '';

  return {
    value: value,
    valueKey: valueKey,
    minDate: addSeconds(new Date(), 300),
    openToDate: set(addDays(new Date(), 1), { minutes: 0, seconds: 0 }),
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({

  onChange (value) {
    dispatch(targetComposerAction(changeScheduled(value), composerId));
  },

});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(DateTimeDropdown));
