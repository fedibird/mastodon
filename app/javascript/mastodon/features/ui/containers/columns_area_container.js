import { connect } from 'react-redux';
import ColumnsArea from '../components/columns_area';
import { getSwipeableLinks } from '../components/tabs_bar';

const mapStateToProps = state => ({
  columns: state.getIn(['settings', 'columns']),
  isModalOpen: !!state.get('modal').modalType,
  links: getSwipeableLinks(),
});

export default connect(mapStateToProps, null, null, { forwardRef: true })(ColumnsArea);
