// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

#library('ShadowRootTest');
#import('../../pkg/unittest/unittest.dart');
#import('../../pkg/unittest/html_config.dart');
#import('dart:html');

main() {
  useHtmlConfiguration();

  test('ShadowRoot supported', () {
    var isSupported = ShadowRoot.supported;

    // If it's supported, then it should work. Otherwise should fail.
    if (isSupported) {
      var shadowRoot = new ShadowRoot(new DivElement());
      expect(shadowRoot is ShadowRoot);
    } else {
      expect(() => new ShadowRoot(new DivElement()), throws);
    }
  });
}
