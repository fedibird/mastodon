import { connect } from 'react-redux';
import CircleDropdown from '../components/circle_dropdown';
import { changeComposeCircle } from '../../../actions/compose';
import { targetComposerAction } from '../../../actions/composer';
import { selectComposer } from '../../../selectors/composer';
import { withComposerId } from '../composer_id_context';

const mapStateToProps = (state, { composerId }) => {
  const composer = selectComposer(state, composerId);
  const privacy = composer.get('privacy');

  return {
    value: composer.get('circle_id') ?? '',
    visible: privacy === 'limited',
    limitedReply: privacy === 'limited' && composer.getIn(['reply_status', 'visibility']) === 'limited',
  };
};

const mapDispatchToProps = (dispatch, { composerId }) => ({

  onChange (value) {
    dispatch(targetComposerAction(changeComposeCircle(value), composerId));
  },

  onOpenCircleColumn (router) {
    if(router && router.location.pathname !== '/circles') {
      router.push('/circles');
    }
  },

});

export default withComposerId(connect(mapStateToProps, mapDispatchToProps)(CircleDropdown));
