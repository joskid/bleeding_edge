// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// Example of spawning an isolate from a URI
// Note: the following comment is used by test.dart to additionally compile the
// other isolate's code.
// OtherScripts=spawn_uri_child_isolate.dart
#library('spawn_tests');
#import('../../pkg/unittest/unittest.dart');
#import('dart:isolate');

main() {
  test('isolate fromUri - send and reply', () {
    ReceivePort port = new ReceivePort();
    port.receive(expectAsync2((msg, _) {
      port.close();
      expect(msg, equals('re: hi'));
    }));

    SendPort s = spawnUri('spawn_uri_child_isolate.dart');
    s.send('hi', port.toSendPort());
  });
}
