// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Test that Null's noSuchMethod can be closurized and called directly.

main() {
  var x;
  // Non-existing method calls noSuchMethod.
  Expect.throws(() => x.foo(),
                (e) => e is NullPointerException);

  // Calling noSuchMethod directly.
  Expect.throws(() => x.noSuchMethod("foo", []),
                (e) => e is NullPointerException);

  // Closurizing noSuchMethod and calling it.
  var nsm = x.noSuchMethod;
  Expect.notEquals(null, nsm);
  Expect.throws(() => nsm("foo", []),
                (e) => e is NullPointerException);
}
