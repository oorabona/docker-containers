#!/usr/bin/env bats

setup() {
    ORIG_DIR="$PWD"
}

@test "variant action bar only selects versions that have confirmed records" {
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
if (bar._versions.length !== 1 || bar._versions[0].tag !== '2.0') {
  throw new Error('unconfirmed-only version stayed selectable');
}
if (!bar._currentVariant || bar._currentVariant.tag !== '2.0-confirmed') {
  throw new Error('selector fell through to a different record');
}
NODE
    [ "$status" -eq 0 ]
}
