import { fireEvent, render, screen } from '@testing-library/react';
import React from 'react';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  FormattedMessage: ({ defaultMessage }) => defaultMessage,
  injectIntl: Component => props => <Component {...props} intl={{ formatMessage: ({ defaultMessage }) => defaultMessage }} />,
}));

jest.mock('../../containers/scheduled_dropdown_container', () => () => <div data-testid='scheduled' />);
jest.mock('../../containers/expires_dropdown_container', () => () => <div data-testid='expires' />);
jest.mock('../../containers/expires_action_container', () => () => <div data-testid='expires-action' />);

import DateTimeForm from '../datetime_form';

describe('DateTimeForm', () => {
  it('closes the whole schedule form from one button', () => {
    const onClose = jest.fn();
    const view = render(<DateTimeForm form_enable onClose={onClose} />);

    fireEvent.click(screen.getByRole('button', { name: 'Remove schedule' }));

    expect(onClose).toHaveBeenCalledTimes(1);
    expect(screen.getByTestId('scheduled')).toBeTruthy();
    expect(screen.getByTestId('expires')).toBeTruthy();

    view.rerender(<DateTimeForm form_enable={false} onClose={onClose} />);

    expect(screen.queryByRole('button', { name: 'Remove schedule' })).toBeNull();
  });
});
