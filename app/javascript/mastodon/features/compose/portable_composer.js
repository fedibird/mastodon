import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { changeComposing, mountCompose, unmountCompose } from '../../actions/compose';
import { changeSetting } from '../../actions/settings';
import { applyComposerPostingContext, createComposer, targetComposerAction } from '../../actions/composer';
import { selectComposer, selectPortableComposerDisplayMode, selectPortableComposerSeed } from '../../selectors/composer';
import ComposeFormContainer from './containers/compose_form_container';
import { ComposerProvider } from './composer_id_context';

const mapStateToProps = (state, { composerId }) => ({
  exists: selectComposer(state, composerId) !== null,
  seed: selectPortableComposerSeed(state),
  displayMode: selectPortableComposerDisplayMode(state, composerId),
});

class PortableComposer extends React.PureComponent {

  static propTypes = {
    composerId: PropTypes.string.isRequired,
    dispatch: PropTypes.func.isRequired,
    exists: PropTypes.bool,
    seed: PropTypes.object,
    postingContext: PropTypes.object,
    postingContextAccountId: PropTypes.string,
    displayMode: PropTypes.oneOf(['full', 'simple']),
  };

  applyPostingContext () {
    const { composerId, dispatch, postingContext, postingContextAccountId } = this.props;

    if (postingContext === undefined) {
      return;
    }

    dispatch(applyComposerPostingContext(composerId, postingContext, postingContextAccountId));
  }

  componentDidMount () {
    const { composerId, dispatch, seed } = this.props;

    dispatch(createComposer(composerId, seed));
    dispatch(targetComposerAction(mountCompose(), composerId));
    this.applyPostingContext();
  }

  componentDidUpdate (prevProps) {
    if (this.props.postingContext === undefined) {
      return;
    }

    const previousContext = JSON.stringify(prevProps.postingContext || null);
    const nextContext = JSON.stringify(this.props.postingContext || null);
    const previousAccountId = prevProps.postingContextAccountId || null;
    const nextAccountId = this.props.postingContextAccountId || null;

    if (previousContext !== nextContext || previousAccountId !== nextAccountId) {
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

  handleDisplayModeChange = (mode) => {
    const { composerId, dispatch } = this.props;

    dispatch(changeSetting(
      ['portableComposerDisplayMode', composerId],
      mode,
    ));
  }

  render () {
    const { composerId, displayMode, exists } = this.props;

    if (!exists) {
      return null;
    }

    return (
      <div className='portable-composer' onFocus={this.handleFocus} onBlur={this.handleBlur}>
        <ComposerProvider composerId={composerId}>
          <ComposeFormContainer
            autoFocus={false}
            displayMode={displayMode}
            onDisplayModeChange={this.handleDisplayModeChange}
          />
        </ComposerProvider>
      </div>
    );
  }

}

export default connect(mapStateToProps)(PortableComposer);
