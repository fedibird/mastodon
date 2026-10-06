import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { changeComposing, mountCompose, unmountCompose } from '../../actions/compose';
import { createComposer, targetComposerAction } from '../../actions/composer';
import { selectComposer, selectPortableComposerSeed } from '../../selectors/composer';
import ComposeFormContainer from './containers/compose_form_container';
import { ComposerProvider } from './composer_id_context';

const mapStateToProps = (state, { composerId }) => ({
  exists: selectComposer(state, composerId) !== null,
  seed: selectPortableComposerSeed(state),
});

class PortableComposer extends React.PureComponent {

  static propTypes = {
    composerId: PropTypes.string.isRequired,
    dispatch: PropTypes.func.isRequired,
    exists: PropTypes.bool,
    seed: PropTypes.object,
  };

  componentDidMount () {
    const { composerId, dispatch, seed } = this.props;

    dispatch(createComposer(composerId, seed));
    dispatch(targetComposerAction(mountCompose(), composerId));
  }

  componentWillUnmount () {
    const { composerId, dispatch } = this.props;

    dispatch(targetComposerAction(unmountCompose(), composerId));
  }

  handleFocus = () => {
    const { composerId, dispatch } = this.props;

    dispatch(targetComposerAction(changeComposing(true), composerId));
  }

  handleBlur = event => {
    if (event.relatedTarget && event.currentTarget.contains(event.relatedTarget)) {
      return;
    }

    const { composerId, dispatch } = this.props;

    dispatch(targetComposerAction(changeComposing(false), composerId));
  }

  render () {
    const { composerId, exists } = this.props;

    if (!exists) {
      return null;
    }

    return (
      <div className='portable-composer' onFocus={this.handleFocus} onBlur={this.handleBlur}>
        <ComposerProvider composerId={composerId}>
          <ComposeFormContainer />
        </ComposerProvider>
      </div>
    );
  }

}

export default connect(mapStateToProps)(PortableComposer);
