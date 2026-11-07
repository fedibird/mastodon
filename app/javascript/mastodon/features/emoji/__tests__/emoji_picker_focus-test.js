import React from 'react';
import PropTypes from 'prop-types';
import { act, render, screen } from '@testing-library/react';
import ModalRoot from 'mastodon/components/modal_root';
import {
  beginComposeFieldNote,
  focusNotedComposeFieldAfterModalClose,
  noteComposeInsertionField,
  resetEmojiPickerFocusForTests,
} from '../emoji_picker_focus';

jest.mock('history', () => ({
  createBrowserHistory: () => ({
    location: { pathname: '/', state: null },
    listen: () => () => {},
    push: () => {},
    goBack: () => {},
  }),
}));

class Harness extends React.Component {

  static propTypes = {
    open: PropTypes.bool,
    onClose: PropTypes.func.isRequired,
  };

  render() {
    const { open, onClose } = this.props;

    return (
      <div>
        <textarea className='autosuggest-textarea__textarea' defaultValue='hello' />
        <button type='button'>Emoji</button>
        <ModalRoot onClose={onClose}>
          {open ? <div>picker</div> : null}
        </ModalRoot>
      </div>
    );
  }

}

const noop = () => {};

describe('modal focus after an emoji pick', () => {
  beforeEach(() => {
    resetEmojiPickerFocusForTests();
  });

  const flush = async () => {
    await act(async () => {
      await Promise.resolve();
    });
  };

  it('focuses the compose field after inert is cleared', async () => {
    const view = render(<Harness open={false} onClose={noop} />);
    const field = view.container.querySelector('textarea');
    const trigger = screen.getByRole('button', { name: 'Emoji' });

    trigger.focus();
    view.rerender(<Harness open onClose={noop} />);
    noteComposeInsertionField(field);
    focusNotedComposeFieldAfterModalClose();
    view.rerender(<Harness open={false} onClose={noop} />);
    await flush();

    expect(document.activeElement).toBe(field);
  });

  it('returns to the trigger when a modifier pick did not schedule field focus', async () => {
    const view = render(<Harness open={false} onClose={noop} />);
    const field = view.container.querySelector('textarea');
    const trigger = screen.getByRole('button', { name: 'Emoji' });

    trigger.focus();
    view.rerender(<Harness open onClose={noop} />);
    noteComposeInsertionField(field);
    view.rerender(<Harness open={false} onClose={noop} />);
    await flush();

    expect(document.activeElement).toBe(trigger);
  });

  it('does not restore a compose field noted by an earlier pick', async () => {
    const view = render(<Harness open={false} onClose={noop} />);
    const field = view.container.querySelector('textarea');
    const trigger = screen.getByRole('button', { name: 'Emoji' });

    noteComposeInsertionField(field);
    trigger.focus();
    view.rerender(<Harness open onClose={noop} />);
    beginComposeFieldNote();
    focusNotedComposeFieldAfterModalClose();
    view.rerender(<Harness open={false} onClose={noop} />);
    await flush();

    expect(document.activeElement).toBe(trigger);
  });
});
