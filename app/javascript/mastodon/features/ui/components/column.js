import React from 'react';
import ColumnHeader from './column_header';
import PropTypes from 'prop-types';
import { debounce } from 'lodash';
import { isProgrammaticTopScroll, scrollTop } from '../../../scroll';
import { isMobile } from '../../../is_mobile';
import classNames from 'classnames';

export default class Column extends React.PureComponent {

  static propTypes = {
    heading: PropTypes.string,
    icon: PropTypes.string,
    children: PropTypes.node,
    active: PropTypes.bool,
    hideHeadingOnMobile: PropTypes.bool,
    columnWidth: PropTypes.string,
  };

  handleHeaderClick = () => {
    const scrollable = this.node.querySelector('.scrollable');

    if (!scrollable) {
      return;
    }

    this._interruptScrollAnimation = scrollTop(scrollable);
  }

  scrollTop () {
    const scrollable = this.node.querySelector('.scrollable');

    if (!scrollable) {
      return;
    }

    this._interruptScrollAnimation = scrollTop(scrollable);
  }


  handleScroll = debounce(() => {
    const scrollable = this.node && this.node.querySelector('.scrollable');

    // The inner list's smooth scroll does not bubble. If this column still
    // hears a scroll while that animation is running, it is not a new gesture.
    if (scrollable && isProgrammaticTopScroll(scrollable)) {
      return;
    }

    if (typeof this._interruptScrollAnimation === 'function') {
      this._interruptScrollAnimation();
    }
  }, 200)

  setRef = (c) => {
    this.node = c;
  }

  componentWillUnmount () {
    if (typeof this._interruptScrollAnimation === 'function') {
      this._interruptScrollAnimation();
    }
  }

  render () {
    const { heading, icon, children, active, hideHeadingOnMobile, columnWidth } = this.props;

    const showHeading = heading && (!hideHeadingOnMobile || (hideHeadingOnMobile && !isMobile(window.innerWidth)));

    const columnHeaderId = showHeading && heading.replace(/ /g, '-');
    const header = showHeading && (
      <ColumnHeader icon={icon} active={active} type={heading} onClick={this.handleHeaderClick} columnHeaderId={columnHeaderId} />
    );
    return (
      <div
        ref={this.setRef}
        role='region'
        aria-labelledby={columnHeaderId}
        className={classNames('column', columnWidth)}
        onScroll={this.handleScroll}
      >
        {header}
        {children}
      </div>
    );
  }

}
