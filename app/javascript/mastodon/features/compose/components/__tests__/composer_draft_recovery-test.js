import { fireEvent, render, screen } from '@testing-library/react';
import React from 'react';

jest.mock('react-intl', () => {
  const ReactLib = require('react');

  return {
    defineMessages: messages => messages,
    injectIntl: (Component) => {
      const Wrapped = props => ReactLib.createElement(Component, {
        ...props,
        intl: {
          formatMessage: (descriptor, values = {}) => String(descriptor.defaultMessage).replace(/\{(\w+)\}/g, (_match, key) => values[key]),
        },
      });

      return Wrapped;
    },
  };
});

import ComposerDraftRecovery from '../composer_draft_recovery';

describe('ComposerDraftRecovery', () => {
  it('offers restore without describing an unfinished upload as fully saved', () => {
    const onRestore = jest.fn();

    render(
      <ComposerDraftRecovery
        intl={{ formatMessage: (descriptor, values = {}) => String(descriptor.defaultMessage).replace(/\{(\w+)\}/g, (_match, key) => values[key]) }}
        offerId='draft-1'
        offerCount={2}
        status='saved'
        mediaIncomplete
        onRestore={onRestore}
      />,
    );

    expect(screen.getByText('Attachments that are still uploading were not saved.')).toBeTruthy();
    fireEvent.click(screen.getByRole('button', { name: 'Restore local draft (2)' }));
    expect(onRestore).toHaveBeenCalledWith('draft-1');
  });

  it('shows a storage failure instead of a saved state', () => {
    render(
      <ComposerDraftRecovery
        intl={{ formatMessage: descriptor => descriptor.defaultMessage }}
        status='failed'
        reason='quota'
      />,
    );

    expect(screen.getByText('This draft could not be saved on this device. Reloading may lose the latest changes.')).toBeTruthy();
    expect(screen.queryByRole('button')).toBeNull();
  });
});
