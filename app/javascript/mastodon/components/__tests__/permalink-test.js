import { fireEvent, render } from '@testing-library/react';
import PropTypes from 'prop-types';
import React from 'react';

import Permalink from '../permalink';

class Router extends React.Component {

  static childContextTypes = {
    router: PropTypes.object,
  };

  static propTypes = {
    children: PropTypes.node,
    router: PropTypes.object,
  };

  getChildContext () {
    return { router: this.props.router };
  }

  render () {
    return this.props.children;
  }

}

describe('Permalink', () => {
  it('keeps the in-app route off the anchor and still navigates', () => {
    const push = jest.fn();
    const route = '/timelines/tag/party👍';
    const { container } = render(
      <Router router={{ history: { push } }}>
        <Permalink href='https://example.com/tags/party' to={route}>
          #party
        </Permalink>
      </Router>,
    );
    const link = container.querySelector('a');

    expect(link.hasAttribute('to')).toBe(false);
    expect(link.getAttribute('href')).toBe('https://example.com/tags/party');
    expect(link.outerHTML).not.toContain('👍');
    fireEvent.click(link);
    expect(push).toHaveBeenCalledWith(route);
  });
});
