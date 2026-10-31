import { fireEvent, render, screen } from '@testing-library/react';
import { List as ImmutableList, Map as ImmutableMap } from 'immutable';
import React from 'react';

jest.mock('react-intl', () => {
  const intl = {
    formatMessage: ({ defaultMessage }) => defaultMessage,
  };

  return {
    injectIntl: Component => props => <Component {...props} intl={intl} />,
    defineMessages: messages => messages,
  };
});

jest.mock('react-overlays/Overlay', () => {
  return ({ show, children }) => (show ? children({ props: { style: {}, ref: jest.fn() }, placement: 'bottom' }) : null);
});

jest.mock('mastodon/initial_state', () => ({
  languages: [['en', 'English', 'English'], ['ja', 'Japanese', '日本語']],
  domain: 'example.com',
}));

import DateTimeButton from '../datetime_button';
import LanguageDropdown from '../language_dropdown';
import PollButton from '../poll_button';
import SearchabilityDropdown from '../searchability_dropdown';
import SenderIdentity from '../sender_identity';
import TextIconButton from '../text_icon_button';
import UploadButton from '../upload_button';

describe('composer toolbar actions', () => {
  it('opens the file picker from the footer icon', () => {
    const click = jest.spyOn(HTMLInputElement.prototype, 'click').mockImplementation(() => {});

    render(
      <UploadButton
        onSelectFile={jest.fn()}
        acceptContentTypes={ImmutableList(['image/png'])}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Add images, a video or an audio file' }));
    expect(click).toHaveBeenCalled();
    click.mockRestore();
  });

  it('delivers a file chosen after the menu row has closed', () => {
    const onSelectFile = jest.fn();
    const click = jest.spyOn(HTMLInputElement.prototype, 'click').mockImplementation(() => {});

    class Harness extends React.Component {

      state = { open: true };

      input = null;

      bindInput = (node) => {
        this.input = node;
      };

      closeMenu = () => {
        this.input.click();
        this.setState({ open: false });
      };

      render () {
        return (
          <div>
            {this.state.open ? (
              <button type='button' onClick={this.closeMenu}>
                Add images, a video or an audio file
              </button>
            ) : null}
            <UploadButton
              presentation='file'
              onFileInput={this.bindInput}
              onSelectFile={onSelectFile}
              acceptContentTypes={ImmutableList(['image/png'])}
            />
          </div>
        );
      }

    }

    render(<Harness />);
    fireEvent.click(screen.getByRole('button', { name: 'Add images, a video or an audio file' }));

    expect(screen.queryByRole('button', { name: 'Add images, a video or an audio file' })).toBeNull();
    const file = document.querySelector('input[type="file"]');
    const chosen = [{ name: 'a.png', type: 'image/png' }];

    expect(file).toBeTruthy();
    Object.defineProperty(file, 'files', { configurable: true, value: chosen });
    fireEvent.change(file);

    expect(onSelectFile).toHaveBeenCalledWith(chosen);
    click.mockRestore();
  });

  it('toggles the content warning from the menu', () => {
    const onClick = jest.fn();
    const onMenuClose = jest.fn();

    render(
      <TextIconButton presentation='menu' label='CW' title='Text is not hidden' onClick={onClick} onMenuClose={onMenuClose} />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Text is not hidden' }));

    expect(onClick).toHaveBeenCalled();
    expect(onMenuClose).toHaveBeenCalled();
  });

  it('adds a poll from the footer and removes it from the menu', () => {
    const onClick = jest.fn();
    const { rerender } = render(<PollButton onClick={onClick} />);

    fireEvent.click(screen.getByRole('button', { name: 'Add a poll' }));
    expect(onClick).toHaveBeenCalledTimes(1);

    rerender(<PollButton presentation='menu' active onClick={onClick} onMenuClose={jest.fn()} />);
    fireEvent.click(screen.getByRole('button', { name: 'Poll' }));
    expect(onClick).toHaveBeenCalledTimes(2);
  });

  it('opens the publish time form from the footer', () => {
    const onClick = jest.fn();

    render(<DateTimeButton onClick={onClick} />);
    fireEvent.click(screen.getByRole('button', { name: 'Add datetime' }));
    expect(onClick).toHaveBeenCalledTimes(1);
  });

  it('changes search visibility from the footer icon', () => {
    const onChange = jest.fn();

    render(
      <SearchabilityDropdown
        value='public'
        onChange={onChange}
        prohibitedVisibilities={ImmutableList()}
      />,
    );

    fireEvent.click(screen.getByRole('button', { name: 'Adjust status searchability' }));
    fireEvent.click(screen.getByRole('option', { name: /Followers-only/ }));

    expect(onChange).toHaveBeenCalledWith('private');
  });

  it('changes language from the detached menu', () => {
    const onChange = jest.fn();
    const onDismiss = jest.fn();

    render(
      <LanguageDropdown
        presentation='detached'
        open
        value='en'
        frequentlyUsedLanguages={[]}
        languages={[['en', 'English', 'English'], ['ja', 'Japanese', '日本語']]}
        onChange={onChange}
        onClose={jest.fn()}
        onDismiss={onDismiss}
      />,
    );

    fireEvent.click(screen.getByRole('option', { name: /日本語/ }));

    expect(onChange).toHaveBeenCalledWith('ja');
    expect(onDismiss).toHaveBeenCalled();
  });

  it('selects a linked account from the detached menu', () => {
    const onSelect = jest.fn();
    const choices = ImmutableList([
      ImmutableMap({
        id: 'local:1',
        kind: 'local',
        authorization: 'ready',
        account: ImmutableMap({ acct: 'admin', display_name: 'Admin' }),
      }),
      ImmutableMap({
        id: 'delegated:2',
        kind: 'delegated',
        authorization: 'ready',
        account: ImmutableMap({ acct: 'other@example.com', display_name: 'Other' }),
        capabilities: ImmutableMap({ post: 'supported' }),
      }),
    ]);

    render(
      <SenderIdentity
        presentation='detached'
        open
        current={choices.get(0)}
        choices={choices}
        catalog={choices}
        selectedId='local:1'
        sessionIdentityId='local:1'
        selectable
        onSelect={onSelect}
      />,
    );

    fireEvent.click(screen.getByRole('menuitemradio', { name: /Other/ }));

    expect(onSelect).toHaveBeenCalledWith('delegated:2', { confirmed: true });
  });
});
