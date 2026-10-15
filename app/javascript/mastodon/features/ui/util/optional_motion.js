import React from 'react';
import PropTypes from 'prop-types';
import { reduceMotion } from '../../../initial_state';
import Motion from 'react-motion/lib/Motion';
import { reduceMotionNow, subscribeReduceMotion } from '../../../utils/appearance_preferences';

const stylesToKeep = ['opacity', 'backgroundOpacity'];

const extractValue = (value) => (
  (typeof value === 'object' && value && 'val' in value) ? value.val : value
);

// Same end state as ReducedMotion, without replacing the Motion element.
// Swapping the component type would remount the animated subtree.
export const stylesForMotion = (style, defaultStyle, reduced) => {
  if (!reduced || !style || typeof style !== 'object') {
    return { style, defaultStyle };
  }

  const nextStyle = { ...style };
  const nextDefault = { ...defaultStyle };

  Object.keys(style).forEach(key => {
    if (stylesToKeep.indexOf(key) !== -1) {
      return;
    }

    const end = extractValue(style[key]);
    nextStyle[key] = end;
    nextDefault[key] = end;
  });

  return { style: nextStyle, defaultStyle: nextDefault };
};

export default class OptionalMotion extends React.Component {

  static propTypes = {
    style: PropTypes.object,
    defaultStyle: PropTypes.object,
    children: PropTypes.func,
  };

  state = {
    reduceMotion: reduceMotionNow(reduceMotion),
  };

  componentDidMount () {
    this.mounted = true;
    this.unsubscribe = subscribeReduceMotion(() => {
      if (!this.mounted) {
        return;
      }

      this.setState({ reduceMotion: reduceMotionNow(reduceMotion) });
    });
  }

  componentWillUnmount () {
    this.mounted = false;

    if (this.unsubscribe) {
      this.unsubscribe();
    }
  }

  render () {
    const { style, defaultStyle, children } = this.props;
    const presentation = stylesForMotion(style, defaultStyle, this.state.reduceMotion);

    return (
      <Motion style={presentation.style} defaultStyle={presentation.defaultStyle}>
        {children}
      </Motion>
    );
  }

}
