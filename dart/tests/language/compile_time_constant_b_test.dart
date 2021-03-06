// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

const m1 = const { '__proto__': 400 + 99 };
const m2 = const { 'a': 499, 'b': 42 };
const m3 = const { '__proto__': 499 };

bool isIllegalAccessException(o) => o is IllegalAccessException;

main() {
  Expect.equals(499, m1['__proto__']);
  Expect.equals(null, m1['b']);
  Expect.listEquals(['__proto__'], m1.getKeys());
  Expect.listEquals([499], m1.getValues());
  Expect.isTrue(m1.containsKey('__proto__'));
  Expect.isFalse(m1.containsKey('toString'));
  Expect.isTrue(m1.containsValue(499));
  Expect.isFalse(m1.containsValue(null));
  var seenKeys = [];
  var seenValues = [];
  m1.forEach((key, value) {
    seenKeys.add(key);
    seenValues.add(value);
  });
  Expect.listEquals(['__proto__'], seenKeys);
  Expect.listEquals([499], seenValues);
  Expect.isFalse(m1.isEmpty());
  Expect.equals(1, m1.length);
  Expect.throws(() => m1.remove('__proto__'), isIllegalAccessException);
  Expect.throws(() => m1.remove('b'), isIllegalAccessException);
  Expect.throws(() => m1.clear(), isIllegalAccessException);
  Expect.throws(() => m1['b'] = 42, isIllegalAccessException);
  Expect.throws(() => m1['__proto__'] = 499, isIllegalAccessException);
  Expect.throws(() => m1.putIfAbsent('__proto__', () => 499),
                isIllegalAccessException);
  Expect.throws(() => m1.putIfAbsent('z', () => 499),
                isIllegalAccessException);

  Expect.equals(499, m2['a']);
  Expect.equals(42, m2['b']);
  Expect.equals(null, m2['c']);
  Expect.equals(null, m2['__proto__']);
  Expect.listEquals(['a', 'b'], m2.getKeys());
  Expect.listEquals([499, 42], m2.getValues());
  Expect.isTrue(m2.containsKey('a'));
  Expect.isTrue(m2.containsKey('b'));
  Expect.isFalse(m2.containsKey('toString'));
  Expect.isFalse(m2.containsKey('__proto__'));
  Expect.isTrue(m2.containsValue(499));
  Expect.isTrue(m2.containsValue(42));
  Expect.isFalse(m2.containsValue(null));
  seenKeys = [];
  seenValues = [];
  m2.forEach((key, value) {
    seenKeys.add(key);
    seenValues.add(value);
  });
  Expect.listEquals(['a', 'b'], seenKeys);
  Expect.listEquals([499, 42], seenValues);
  Expect.isFalse(m2.isEmpty());
  Expect.equals(2, m2.length);
  Expect.throws(() => m2.remove('a'), isIllegalAccessException);
  Expect.throws(() => m2.remove('b'), isIllegalAccessException);
  Expect.throws(() => m2.remove('__proto__'), isIllegalAccessException);
  Expect.throws(() => m2.clear(), isIllegalAccessException);
  Expect.throws(() => m2['a'] = 499, isIllegalAccessException);
  Expect.throws(() => m2['b'] = 42, isIllegalAccessException);
  Expect.throws(() => m2['__proto__'] = 499, isIllegalAccessException);
  Expect.throws(() => m2.putIfAbsent('a', () => 499),
                isIllegalAccessException);
  Expect.throws(() => m2.putIfAbsent('__proto__', () => 499),
                isIllegalAccessException);
  Expect.throws(() => m2['a'] = 499, isIllegalAccessException);

  Expect.isTrue(m1 === m3);
}
