import React from 'react';
import PropTypes from 'prop-types';
import classNames from 'classnames';
import { LoadingBar } from 'react-redux-loading-bar';
import ZoomableImage from './zoomable_image';
import { FormattedMessage } from 'react-intl';

export default class ImageLoader extends React.PureComponent {

  static propTypes = {
    alt: PropTypes.string,
    lang: PropTypes.string,
    src: PropTypes.string.isRequired,
    previewSrc: PropTypes.string,
    width: PropTypes.number,
    height: PropTypes.number,
    onClick: PropTypes.func,
    zoomButtonHidden: PropTypes.bool,
  }

  static defaultProps = {
    alt: '',
    width: null,
    height: null,
  };

  state = {
    loading: true,
    error: false,
    width: null,
  }

  removers = [];
  canvas = null;

  get canvasContext() {
    if (!this.canvas) {
      return null;
    }
    this._canvasContext = this._canvasContext || this.canvas.getContext('2d');
    return this._canvasContext;
  }

  componentDidMount () {
    this.loadImage(this.props);
  }

  componentWillReceiveProps (nextProps) {
    if (this.props.src !== nextProps.src || this.props.previewSrc !== nextProps.previewSrc) {
      this.loadImage(nextProps);
    }
  }

  componentWillUnmount () {
    this.loadToken = (this.loadToken || 0) + 1;
    this.removeEventListeners();
  }

  handleDisplayError = () => {
    this.setState({ loading: false, error: true });
  }

  loadImage (props) {
    this.removeEventListeners();
    const token = this.loadToken = (this.loadToken || 0) + 1;
    this.setState({ loading: true, error: false });

    // Always verify the actual image, even if the remote attachment does not
    // specify original width and height. A broken preview must not fail the
    // view when the original still loads successfully.
    const hasSize = typeof props.width === 'number' && props.width > 0 &&
      typeof props.height === 'number' && props.height > 0;
    const preview = props.previewSrc && hasSize
      ? this.loadPreviewCanvas(props).catch(() => undefined) : null;

    Promise.all([this.loadOriginalImage(props), preview].filter(Boolean))
      .then(() => {
        if (token !== this.loadToken) return;
        this.setState({ loading: false, error: false });
        this.clearPreviewCanvas();
      })
      .catch(() => {
        if (token !== this.loadToken) return;
        this.setState({ loading: false, error: true });
      });
  }

  loadPreviewCanvas = ({ previewSrc, width, height }) => new Promise((resolve, reject) => {
    const image = new Image();
    const removeEventListeners = () => {
      image.removeEventListener('error', handleError);
      image.removeEventListener('load', handleLoad);
    };
    const handleError = () => {
      removeEventListeners();
      reject();
    };
    const handleLoad = () => {
      removeEventListeners();
      try {
        const ctx = this.canvasContext;
        if (ctx) ctx.drawImage(image, 0, 0, width, height);
        resolve();
      } catch (error) {
        reject(error);
      }
    };
    image.addEventListener('error', handleError);
    image.addEventListener('load', handleLoad);
    image.src = previewSrc;
    this.removers.push(removeEventListeners);
  })

  clearPreviewCanvas () {
    const canvas = this.canvas;
    const ctx = this.canvasContext;
    if (canvas && ctx) ctx.clearRect(0, 0, canvas.width, canvas.height);
  }

  loadOriginalImage = ({ src }) => new Promise((resolve, reject) => {
    if (!src) {
      reject(new Error('Missing image URL'));
      return;
    }

    const image = new Image();
    const removeEventListeners = () => {
      image.removeEventListener('error', handleError);
      image.removeEventListener('load', handleLoad);
    };
    const handleError = () => {
      removeEventListeners();
      reject();
    };
    const handleLoad = () => {
      removeEventListeners();
      resolve();
    };
    image.addEventListener('error', handleError);
    image.addEventListener('load', handleLoad);
    image.src = src;
    this.removers.push(removeEventListeners);
  });

  removeEventListeners () {
    this.removers.forEach(listeners => listeners());
    this.removers = [];
  }

  hasSize () {
    const { width, height } = this.props;
    return typeof width === 'number' && typeof height === 'number';
  }

  setCanvasRef = c => {
    if (this.canvas !== c) this._canvasContext = null;
    this.canvas = c;
    if (c && this.state.width !== c.offsetWidth) this.setState({ width: c.offsetWidth });
  }

  render () {
    const { alt, src, width, height, onClick, lang } = this.props;
    const { loading, error } = this.state;

    const className = classNames('image-loader', {
      'image-loader--loading': loading,
      'image-loader--amorphous': !this.hasSize(),
    });

    return (
      <div className={className}>
        <LoadingBar loading={loading ? 1 : 0} className='loading-bar' style={{ width: this.state.width || width }} />
        {error ? (
          <div className='image-loader__error' role='status'>
            <strong className='image-loader__error-title'>
              <FormattedMessage id='lightbox.image_unavailable' defaultMessage='Could not load image' />
            </strong>
            {alt && (
              <div className='image-loader__error-alt'>
                <span>ALT</span>
                <p lang={lang || undefined} dir='auto'>{alt}</p>
              </div>
            )}
          </div>
        ) : loading ? (
          <canvas
            className='image-loader__preview-canvas'
            ref={this.setCanvasRef}
            width={width}
            height={height}
          />
        ) : (
          <ZoomableImage
            alt={alt}
            lang={lang}
            src={src}
            onClick={onClick}
            onError={this.handleDisplayError}
            width={width}
            height={height}
            zoomButtonHidden={this.props.zoomButtonHidden}
          />
        )}
      </div>
    );
  }

}
