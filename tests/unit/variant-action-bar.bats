#!/usr/bin/env bats

setup() {
    ORIG_DIR="$PWD"
}

@test "variant action bar keeps unconfirmed selectors selectable but renders no command for them" {
    run node - "$ORIG_DIR/docs/site/assets/js/components/variant-action-bar.js" <<'NODE'
const source = process.argv[2];
global.HTMLElement = class {};
global.customElements = {
  get: function () { return undefined; },
  define: function (_, value) { global.VariantActionBar = value; }
};
require(source);
const bar = new global.VariantActionBar();
bar.dataset = {
  imageBase: 'ghcr.io/example/demo',
  defaultTag: '1.0-unconfirmed',
  defaultVersion: '1.0',
  defaultFlavor: 'base',
  versions: JSON.stringify([
    { tag: '1.0', label: '1.0' },
    { tag: '2.0', label: '2.0' }
  ]),
  flavors: JSON.stringify([{ name: 'base', label: 'base' }]),
  variants: JSON.stringify([
    { tag: '1.0-unconfirmed', version: '1.0', flavor: 'base', reference_confirmed: false },
    { tag: '2.0-confirmed', version: '2.0', flavor: 'base', reference_confirmed: true }
  ])
};
bar._parseData();
if (bar._versions.length !== 2 || bar._versions[0].tag !== '1.0') {
  throw new Error('unconfirmed version was filtered from selectors');
}
if (!bar._currentVariant || bar._currentVariant.tag !== '1.0-unconfirmed') {
  throw new Error('selector did not retain its declared default');
}
const pull = { textContent: '' };
const verify = { textContent: '' };
bar.querySelector = function (selector) {
  if (selector === '[data-vab-cmd="pull"]') return pull;
  if (selector === '[data-vab-cmd="verify"]') return verify;
  return null;
};
bar.querySelectorAll = function () { return []; };
bar._updateCollapsedActionsState = function () {};
bar._updateStickyCommand = function () {};
bar._updateCommands();
if (pull.textContent !== 'No published image was observed for this reference.' ||
    verify.textContent !== 'No published image was observed for this reference.') {
  throw new Error('unconfirmed reference rendered a command');
}
bar._currentVariant = bar._variants[1];
bar._updateCommands();
if (pull.textContent !== 'docker pull ghcr.io/example/demo:2.0-confirmed') {
  throw new Error('confirmed reference did not render its command');
}
NODE
    [ "$status" -eq 0 ]
}
