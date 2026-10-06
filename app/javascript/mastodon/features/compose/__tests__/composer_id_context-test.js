import { render, screen } from '@testing-library/react';
import React from 'react';
import PropTypes from 'prop-types';

import { PRIMARY_COMPOSER_ID } from '../../../utils/composer';
import { ComposerProvider, withComposerId } from '../composer_id_context';

const IdLabel = ({ composerId }) => <span>{composerId}</span>;

IdLabel.propTypes = {
  composerId: PropTypes.string,
};

const Wrapped = withComposerId(IdLabel);

describe('ComposerIdContext', () => {
  it('defaults to the primary composer without a provider', () => {
    render(<Wrapped />);

    expect(screen.getByText(PRIMARY_COMPOSER_ID).textContent).toBe('primary');
  });

  it('supplies the provider composer id', () => {
    render(
      <ComposerProvider composerId='composer-a'>
        <Wrapped />
      </ComposerProvider>,
    );

    expect(screen.getByText('composer-a').textContent).toBe('composer-a');
  });

  it('lets a nested provider override the composer id', () => {
    render(
      <ComposerProvider composerId='composer-a'>
        <ComposerProvider composerId='composer-b'>
          <Wrapped />
        </ComposerProvider>
      </ComposerProvider>,
    );

    expect(screen.getByText('composer-b').textContent).toBe('composer-b');
  });
});
