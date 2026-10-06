import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { changeComposing, mountCompose, unmountCompose } from '../../actions/compose';
import { applyComposerPostingContext, createComposer, targetComposerAction } from '../../actions/composer';
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
    postingContext: PropTypes.object,
  };

  applyPostingContext () {
    const { composerId, dispatch, postingContext } = this.props;

    if (postingContext === undefined) {
      return;
    }

    dispatch(applyComposerPostingContext(composerId, postingContext));
  }

  componentDidMount () {
    const { composerId, dispatch, seed } = this.props;

    dispatch(createComposer(composerId, seed));
    dispatch(targetComposerAction(mountCompose(), composerId));
    this.applyPostingContext();
  }

  componentDidUpdate (prevProps) {
    const previousKey = prevProps.postingContext && prevProps.postingContext.key;
    const nextKey = this.props.postingContext && this.props.postingContext.key;

    if (this.props.postingContext !== undefined && previousKey !== nextKey) {
      this.applyPostingContext();
    }
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
          <ComposeFormContainer autoFocus={false} />
        </ComposerProvider>
      </div>
    );
  }

}

export default connect(mapStateToProps)(PortableComposer);
