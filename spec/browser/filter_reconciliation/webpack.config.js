const path = require('path');
const webpack = require('webpack');

const root = path.resolve(__dirname, '../../..');
const replacements = new Map([
  [path.join(root, 'app/javascript/mastodon/containers/status_container'), path.join(__dirname, 'status.js')],
  [path.join(root, 'app/javascript/mastodon/api'), path.join(__dirname, 'api.js')],
]);
module.exports = {
  mode: 'development',
  entry: path.join(__dirname, 'fixture.js'),
  output: { path: path.join(root, 'tmp/filter-reconciliation-browser'), filename: 'fixture.js' },
  devtool: false,
  resolve: { modules: [path.join(root, 'app/javascript'), 'node_modules'], extensions: ['.js', '.jsx'] },
  module: { rules: [
    { test: /\.jsx?$/, exclude: /node_modules/, use: { loader: 'babel-loader', options: { configFile: false, babelrc: false, presets: ['@babel/preset-react', ['@babel/preset-env', { targets: { chrome: '60' } }]], plugins: [['@babel/plugin-proposal-decorators', { legacy: true }]] } } },
    { test: /\.(svg|png)$/, use: 'file-loader' },
  ] },
  plugins: [new webpack.NormalModuleReplacementPlugin(/./, resource => {
    const resolved = path.resolve(resource.context, resource.request).replace(/\.js$/, '');
    if (replacements.has(resolved)) resource.request = replacements.get(resolved);
  })],
};
