// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Simulates a use of test_progress during a failing run of test.dart.

#import("../../../tools/testing/dart/test_progress.dart");
#import("../../../tools/testing/dart/test_runner.dart");
#import("../../../tools/testing/dart/test_options.dart");

main() {
  var progressType = new Options().arguments[0];
  // Build a progress indicator.
  var startTime = new Date.now();
  var progress =
    new ProgressIndicator.fromName(progressType, startTime, false);
  // Build a dummy test case.
  var configuration = new TestOptionsParser().parse(['--timeout', '2'])[0];
  var testCase = new TestCase('failing_test.dart',
                              [],
                              configuration,
                              (_) => null,
                              new Set<String>.from(['PASS']));
  // Simulate the test.dart use of the progress indicator.
  progress.testAdded();
  progress.allTestsKnown();
  progress.start(testCase);
  new TestOutput.fromCase(testCase, 1, false, false, [], [],
                          new Date.now().difference(startTime));
  progress.done(testCase);
  progress.allDone();
}
