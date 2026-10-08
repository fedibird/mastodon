import React from 'react';
import PropTypes from 'prop-types';
import { connect } from 'react-redux';
import { changeComposing, mountCompose, unmountCompose } from '../../actions/compose';
import { changeSetting } from '../../actions/settings';
import { applyComposerPostingContext, applyComposerSurface, createComposer, targetComposerAction } from '../../actions/composer';
import { surfacesEqual } from '../../posting_context/surface';
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
    surface: PropTypes.shape({
      kind: PropTypes.oneOf(['group', 'hashtag', 'list']).isRequired,
      key: PropTypes.string.isRequired,
    }),
    displayMode: PropTypes.oneOf(['full', 'simple']),
  };

  syncDestination () {
    const { composerId, dispatch, postingContext, postingContextAccountId, surface } = this.props;

    if (surface) {
      dispatch(applyComposerSurface(composerId, surface, postingContext, postingContextAccountId));
      return;
    }

    if (postingContext === undefined) {
      return;
    }

    dispatch(applyComposerPostingContext(composerId, postingContext, postingContextAccountId));
  }

  destinationChanged (prevProps) {
    if (!surfacesEqual(prevProps.surface, this.props.surface)) {
      return true;
    }

    if (!this.props.surface && this.props.postingContext === undefined) {
      return false;
    }

    const previousContext = JSON.stringify(prevProps.postingContext || null);
    const nextContext = JSON.stringify(this.props.postingContext || null);
    const previousAccountId = prevProps.postingContextAccountId || null;
    const nextAccountId = this.props.postingContextAccountId || null;

    return previousContext !== nextContext || previousAccountId !== nextAccountId;
  }

  componentDidMount () {
    const { composerId, dispatch, seed } = this.props;

    dispatch(createComposer(composerId, seed));
    dispatch(targetComposerAction(mountCompose(), composerId));
    this.syncDestination();
  }

  componentDidUpdate (prevProps) {
    if (this.destinationChanged(prevProps)) {
      this.syncDestination();
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
