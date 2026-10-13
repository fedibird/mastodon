import { fireEvent, render, screen } from '@testing-library/react';
import React from 'react';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  injectIntl: Component => props => <Component {...props} intl={{ formatMessage: message => message.defaultMessage }} />,
}));

import ComposerHeightGrip from '../composer_height_grip';

const renderGrip = () => {
  const onChange = jest.fn();
  const measured = { height: 80, chromeHeight: 40, lineHeight: 22 };

  function onMeasure () {
    return measured;
  }

  function handleChange (next) {
    measured.height = next;
    onChange(next);
  }

  render(
    <ComposerHeightGrip
      onChange={handleChange}
      onMeasure={onMeasure}
    />,
  );

  return { onChange };
};

const point = (node, type, clientY) => {
  const event = new MouseEvent(type, { bubbles: true, cancelable: true, clientY, button: 0 });

  Object.defineProperty(event, 'pointerId', { value: 3 });
  fireEvent(node, event);
};

describe('ComposerHeightGrip', () => {
  it('changes the text height from the pointer and restores it on cancel', () => {
    const { onChange } = renderGrip();
    const grip = screen.getByRole('separator', { name: 'Resize the text field' });

    expect(grip).toHaveAttribute('aria-orientation', 'horizontal');

    point(grip, 'pointerdown', 100);
    point(document, 'pointermove', 140);

    expect(onChange).toHaveBeenLastCalledWith(120);

    point(document, 'pointercancel', 140);

    expect(onChange).toHaveBeenLastCalledWith(80);
  });

  it('changes the text height from the keyboard', () => {
    const { onChange } = renderGrip();
    const grip = screen.getByRole('separator', { name: 'Resize the text field' });

    fireEvent.keyDown(grip, { key: 'ArrowDown' });
    fireEvent.keyDown(grip, { key: 'ArrowUp' });

    expect(onChange).toHaveBeenNthCalledWith(1, 102);
    expect(onChange).toHaveBeenNthCalledWith(2, 80);
  });
});
