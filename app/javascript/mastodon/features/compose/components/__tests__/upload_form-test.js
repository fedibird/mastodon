import { render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import React from 'react';

jest.mock('../../containers/upload_progress_container', () => () => null);
jest.mock('../../containers/sensitive_button_container', () => () => <div data-testid='sensitive-button' />);
jest.mock('../composer_media_gallery', () => () => <div data-testid='media-gallery' />);

import UploadForm from '../upload_form';

const media = ImmutableList([ImmutableMap({ id: 'a', type: 'image' })]);
const handlers = {
  onEdit: jest.fn(),
  onRemove: jest.fn(),
  onMoveTo: jest.fn(),
  onMoveBy: jest.fn(),
};

describe('UploadForm sensitive row', () => {
  it('places the character count beside the sensitive checkbox', () => {
    render(
      <UploadForm
        media={media}
        endAccessory={<div data-testid='character-count'>500</div>}
        {...handlers}
      />,
    );

    const row = document.querySelector('.compose-form__sensitive-row');
    const sensitive = screen.getByTestId('sensitive-button');
    const counter = screen.getByTestId('character-count');

    expect(row).toContainElement(sensitive);
    expect(row).toContainElement(counter);
    expect(sensitive.compareDocumentPosition(counter) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  });

  it('does not render the shared row without media', () => {
    render(
      <UploadForm
        media={ImmutableList()}
        endAccessory={<div data-testid='character-count'>500</div>}
        {...handlers}
      />,
    );

    expect(document.querySelector('.compose-form__sensitive-row')).toBeNull();
    expect(screen.queryByTestId('character-count')).toBeNull();
  });
});
