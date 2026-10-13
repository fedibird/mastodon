import { fireEvent, render, screen } from '@testing-library/react';
import React from 'react';

jest.mock('react-intl', () => ({
  defineMessages: messages => messages,
  FormattedMessage: ({ defaultMessage }) => defaultMessage,
  injectIntl: Component => props => <Component {...props} intl={{ formatMessage: ({ defaultMessage }) => defaultMessage }} />,
}));

import SearchabilityIndicator from '../searchability_indicator';

describe('SearchabilityIndicator', () => {
  it('stays hidden while search visibility matches the default', () => {
    render(<SearchabilityIndicator changed={false} value='public' onReset={jest.fn()} />);

    expect(screen.queryByTestId('searchability-indicator')).toBeNull();
  });

  it('shows the selected visibility and resets it to the default', () => {
    const onReset = jest.fn();

    render(<SearchabilityIndicator changed value='private' onReset={onReset} />);

    expect(screen.getByTestId('searchability-indicator').textContent).toContain('Search visibility');
    expect(screen.getByTestId('searchability-indicator').textContent).toContain('Followers-only');
    expect(screen.getByTestId('searchability-indicator').querySelector('.fa-search')).toBeTruthy();

    fireEvent.click(screen.getByRole('button', { name: 'Reset search visibility' }));

    expect(onReset).toHaveBeenCalledTimes(1);
  });
});
