// Copyright (c) 2011, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
//

#library("Library5Test.dart");
#import("library5a.dart", prefix : "lib5a");
#import("library5b.dart", prefix : "lib5b");

int foo(lib5a.Fun f) {
  return f();
}

int bar(lib5b.Fun f) {
  return f(42);
}

main() {
  Expect.equals(41, foo(() => 41));
  Expect.equals(42, bar((x) => x));
}

